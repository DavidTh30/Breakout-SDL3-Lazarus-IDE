unit GameAudio;

{ Tiny chiptune synthesizer on top of plain SDL3 audio streams.
  - No sound files and no SDL3_mixer needed: everything is generated in code.
  - Music: an 8-bar loop (lead square, bass triangle, kick, snare, hi-hat).
  - Sound effects: up to 32 simultaneous "voices" with a pitch slide.
  Call AudioUpdate once per frame; it keeps ~50 ms of audio queued. }

{$mode objfpc}{$H+}
{$Q-}{$R-}   { the noise generator relies on integer wrap-around }

interface

procedure AudioInit;
procedure AudioUpdate;
procedure AudioShutdown;

procedure SetMusicDucked(Ducked: Boolean);   { quieter music on pause / game over }

procedure SfxPaddle;
procedure SfxWall;
procedure SfxBrick(Row: Integer);
procedure SfxLaunch;
procedure SfxLoseLife;
procedure SfxGameOver;
procedure SfxWin;
procedure SfxPause;
procedure SfxMenuMove;
procedure SfxMenuSelect;
procedure SfxMenuBack;
procedure SfxPowerUp;
procedure SfxPowerDown;
procedure SfxHighScore;
procedure SfxExplosion;
procedure SfxSteel;
procedure SfxZap;
procedure SfxCrack;
procedure SfxGold;
procedure SfxLevelStart;
procedure SfxLevelClear;
procedure SfxBotPaddle;
procedure SfxGoal;        { you got the ball past the bot }
procedure SfxBotGoal;     { the bot got the ball past you }

{ each level plays the loop in its own key, tempo and lead tone }
procedure MusicSetLevel(Level: Integer);

var
  MusicOn: Boolean = True;      { M key: quick mute }
  SfxOn: Boolean = True;        { N key: quick mute }
  MusicVolume: Integer = 7;     { 0..10, from the Sound menu }
  SfxVolume: Integer = 8;       { 0..10 }

implementation

uses
  Math, SDL3;

const
  SampleRate  = 44100;
  BlockFrames = 512;            { samples generated per chunk }
  LeadFrames  = 2048;           { keep ~46 ms queued ahead }
  MaxVoices   = 32;

  BPM       = 150;
  StepSecDefault = 60.0 / BPM / 2;   { one eighth note }
  StepCount = 64;               { 8 bars x 8 eighths }

  { lead melody in A minor, MIDI note numbers, 0 = rest }
  Melody: array[0..StepCount - 1] of Byte = (
    69, 0,72,76, 74,72,71,72,    { Am }
    69, 0,65,69, 72, 0,69,67,    { F  }
    67, 0,72,76, 79,76,74,72,    { C  }
    71, 0,74,71, 67, 0,71,74,    { G  }
    76, 0,74,72, 69,72,76,81,    { Am }
    77,76,74,72, 69, 0,72, 0,    { F  }
    74, 0,71,67, 71,74,79,74,    { G  }
    76, 0,71,68, 64,68,71, 0);   { E  }

  { bass root for each bar }
  BassRoots: array[0..7] of Byte = (45, 41, 48, 43, 45, 41, 43, 40);

type
  TWave = (wvSquare, wvTriangle, wvSine, wvNoise);

  TVoice = record
    Active: Boolean;
    Wave: TWave;
    F0, F1: Single;       { start / end frequency (Hz) }
    Dur, T: Single;       { length and elapsed time (s) }
    Delay: Single;        { wait before starting (s) }
    Vol, Duty: Single;
    Phase: Single;
  end;

var
  Stream: PSDL_AudioStream = nil;
  Buf: array[0..BlockFrames - 1] of Single;
  Voices: array[0..MaxVoices - 1] of TVoice;
  NextVoice: Integer = 0;
  NoiseState: Cardinal = $1234567;

  { music sequencer state }
  StepSamples: Integer = 0;
  StepIndex: Integer = -1;
  LeadFreq, LeadPhase, LeadT: Single;
  BassFreq, BassPhase, BassT: Single;
  KickT, KickPhase, SnareT, HatT: Single;
  MusicGain: Single = 0;
  MusicTarget: Single = 1;
  StepSec: Single = StepSecDefault;
  Transpose: Integer = 0;
  LeadDuty: Single = 0.25;

{ ---------- building blocks ---------- }

function MinF(A, B: Single): Single;
begin
  if A < B then Result := A else Result := B;
end;

function MidiFreq(Note: Integer): Single;
begin
  Result := 440.0 * Power(2.0, (Note - 69) / 12.0);
end;

function Noise: Single;
begin
  NoiseState := NoiseState xor (NoiseState shl 13);
  NoiseState := NoiseState xor (NoiseState shr 17);
  NoiseState := NoiseState xor (NoiseState shl 5);
  Result := (NoiseState and $FFFF) / 32768.0 - 1.0;
end;

function Osc(Wave: TWave; Phase, Duty: Single): Single;
begin
  case Wave of
    wvSquare:   if Phase < Duty then Result := 1.0 else Result := -1.0;
    wvTriangle: Result := 4.0 * Abs(Phase - 0.5) - 1.0;
    wvSine:     Result := Sin(2.0 * Pi * Phase);
  else
    Result := Noise;
  end;
end;

procedure Advance(var Phase: Single; Freq: Single); inline;
begin
  Phase := Phase + Freq / SampleRate;
  if Phase >= 1.0 then Phase := Phase - Trunc(Phase);
end;

procedure AddVoice(AWave: TWave; AF0, AF1, ADur, AVol: Single;
                   ADelay: Single = 0; ADuty: Single = 0.5);
var
  V: ^TVoice;
begin
  if (not SfxOn) or (SfxVolume <= 0) then Exit;
  V := @Voices[NextVoice];
  V^.Wave := AWave;
  V^.F0 := AF0;
  V^.F1 := AF1;
  V^.Dur := ADur;
  V^.T := 0;
  V^.Delay := ADelay;
  V^.Vol := AVol * SfxVolume / 10;
  V^.Duty := ADuty;
  V^.Phase := 0;
  V^.Active := True;
  NextVoice := (NextVoice + 1) mod MaxVoices;
end;

{ ---------- music ---------- }

procedure NextStep;
var
  Bar, InBar, Note: Integer;
begin
  StepIndex := (StepIndex + 1) mod StepCount;
  Bar := StepIndex div 8;
  InBar := StepIndex mod 8;

  Note := Melody[StepIndex];
  if Note > 0 then begin LeadFreq := MidiFreq(Note + Transpose); LeadT := 0; end;

  { bass: root on even eighths, octave up on odd ones }
  if Odd(InBar) then BassFreq := MidiFreq(BassRoots[Bar] + 12 + Transpose)
  else BassFreq := MidiFreq(BassRoots[Bar] + Transpose);
  BassT := 0;

  case InBar of
    0, 4: begin KickT := 0; KickPhase := 0; end;
    2, 6: SnareT := 0;
  end;
  if Odd(InBar) then HatT := 0;
end;

function MusicSample: Single;
const
  Dt = 1.0 / SampleRate;
var
  Env, F: Single;
begin
  if StepSamples <= 0 then
  begin
    NextStep;
    StepSamples := Round(StepSec * SampleRate);
  end;
  Dec(StepSamples);

  Result := 0;

  { lead: 25% square with a short pluck envelope }
  if LeadT < 0.19 then
  begin
    Env := (1.0 - LeadT / 0.19) * MinF(1.0, LeadT * 400);
    Result := Result + Osc(wvSquare, LeadPhase, LeadDuty) * Env * 0.16;
    Advance(LeadPhase, LeadFreq);
    LeadT := LeadT + Dt;
  end;

  { bass: triangle }
  Env := (1.0 - 0.6 * MinF(1.0, BassT / StepSec)) * MinF(1.0, BassT * 400);
  Result := Result + Osc(wvTriangle, BassPhase, 0.5) * Env * 0.30;
  Advance(BassPhase, BassFreq);
  BassT := BassT + Dt;

  { kick: sine with a fast pitch drop }
  if KickT < 0.15 then
  begin
    F := 45 + 110 * Sqr(1.0 - KickT / 0.15);
    Result := Result + Sin(2 * Pi * KickPhase) * (1.0 - KickT / 0.15) * 0.45;
    Advance(KickPhase, F);
    KickT := KickT + Dt;
  end;

  { snare and hi-hat: noise bursts }
  if SnareT < 0.12 then
  begin
    Result := Result + Noise * (1.0 - SnareT / 0.12) * 0.16;
    SnareT := SnareT + Dt;
  end;
  if HatT < 0.03 then
  begin
    Result := Result + Noise * (1.0 - HatT / 0.03) * 0.06;
    HatT := HatT + Dt;
  end;
end;

{ ---------- mixing ---------- }

procedure GenerateBlock;
const
  Dt = 1.0 / SampleRate;
var
  I, V: Integer;
  S, X, Env, F, Target: Single;
begin
  if MusicOn then Target := MusicTarget * MusicVolume / 10 else Target := 0;

  for I := 0 to BlockFrames - 1 do
  begin
    { music fades smoothly when muted or ducked }
    MusicGain := MusicGain + (Target - MusicGain) * 0.0005;
    S := MusicSample * MusicGain * 0.55;

    for V := 0 to MaxVoices - 1 do
      with Voices[V] do
        if Active then
        begin
          if Delay > 0 then begin Delay := Delay - Dt; Continue; end;
          X := T / Dur;
          F := F0 + (F1 - F0) * X;
          Env := Sqr(1.0 - X) * MinF(1.0, T * 500);
          S := S + Osc(Wave, Phase, Duty) * Env * Vol * 0.6;
          Advance(Phase, F);
          T := T + Dt;
          if T >= Dur then Active := False;
        end;

    Buf[I] := EnsureRange(S, -1.0, 1.0);
  end;
end;

{ ---------- public ---------- }

procedure AudioInit;
var
  Spec: TSDL_AudioSpec;
begin
  { audio is optional: if anything fails, the game simply runs silent }
  if not SDL_InitSubSystem(SDL_INIT_AUDIO) then Exit;

  Spec.format := SDL_AUDIO_F32;
  Spec.channels := 1;
  Spec.freq := SampleRate;
  Stream := SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, @Spec, nil, nil);
  if Stream = nil then Exit;

  SDL_ResumeAudioStreamDevice(Stream);
  AudioUpdate;
end;

procedure AudioUpdate;
var
  Queued, Guard: Integer;
begin
  if Stream = nil then Exit;
  Guard := 0;
  repeat
    Queued := SDL_GetAudioStreamQueued(Stream);
    if (Queued < 0) or (Queued >= LeadFrames * SizeOf(Single)) then Break;
    GenerateBlock;
    SDL_PutAudioStreamData(Stream, @Buf[0], BlockFrames * SizeOf(Single));
    Inc(Guard);
  until Guard >= 16;
end;

procedure AudioShutdown;
begin
  if Stream <> nil then SDL_DestroyAudioStream(Stream);
  Stream := nil;
end;

procedure SetMusicDucked(Ducked: Boolean);
begin
  if Ducked then MusicTarget := 0.35 else MusicTarget := 1.0;
end;

{ ---------- sound effects ---------- }

procedure SfxPaddle;
begin
  AddVoice(wvSquare, 330, 520, 0.09, 0.35);
end;

procedure SfxWall;
begin
  AddVoice(wvTriangle, 760, 700, 0.05, 0.45);
end;

procedure SfxBrick(Row: Integer);
var
  F: Single;
begin
  F := MidiFreq(84 - Row * 2);          { top rows ring higher }
  AddVoice(wvSquare, F, F * 1.5, 0.09, 0.28, 0, 0.25);
  AddVoice(wvSquare, F * 2, F * 2, 0.07, 0.18, 0.045, 0.25);
  AddVoice(wvNoise, 0, 0, 0.05, 0.18);
end;

procedure SfxLaunch;
begin
  AddVoice(wvSquare, 300, 900, 0.15, 0.30, 0, 0.25);
end;

procedure SfxLoseLife;
begin
  AddVoice(wvSquare, 440, 90, 0.55, 0.35);
  AddVoice(wvNoise, 0, 0, 0.35, 0.22);
end;

procedure SfxGameOver;
const
  Notes: array[0..3] of Byte = (67, 63, 60, 55);
var
  I: Integer;
begin
  for I := 0 to 3 do
  begin
    AddVoice(wvTriangle, MidiFreq(Notes[I]), MidiFreq(Notes[I]), 0.35, 0.45, I * 0.2);
    AddVoice(wvSquare, MidiFreq(Notes[I] - 12), MidiFreq(Notes[I] - 12), 0.35, 0.15, I * 0.2);
  end;
end;

procedure SfxWin;
const
  Notes: array[0..4] of Byte = (72, 76, 79, 84, 88);
var
  I: Integer;
  F: Single;
begin
  for I := 0 to 4 do
  begin
    F := MidiFreq(Notes[I]);
    if I < 4 then AddVoice(wvSquare, F, F, 0.22, 0.25, I * 0.1, 0.25)
    else AddVoice(wvSquare, F, F, 0.8, 0.30, 0.45, 0.25);
  end;
end;

procedure SfxPause;
begin
  AddVoice(wvTriangle, 880, 880, 0.07, 0.35);
end;

procedure SfxMenuMove;
begin
  AddVoice(wvSquare, 620, 700, 0.05, 0.22, 0, 0.25);
end;

procedure SfxMenuSelect;
begin
  AddVoice(wvSquare, MidiFreq(76), MidiFreq(76), 0.07, 0.28, 0, 0.25);
  AddVoice(wvSquare, MidiFreq(83), MidiFreq(83), 0.12, 0.28, 0.06, 0.25);
  AddVoice(wvTriangle, MidiFreq(64), MidiFreq(64), 0.18, 0.35, 0.06);
end;

procedure SfxMenuBack;
begin
  AddVoice(wvSquare, MidiFreq(79), MidiFreq(72), 0.12, 0.25, 0, 0.25);
end;

procedure SfxPowerUp;
const
  Notes: array[0..3] of Byte = (72, 76, 79, 84);
var
  I: Integer;
begin
  for I := 0 to 3 do
    AddVoice(wvSquare, MidiFreq(Notes[I]), MidiFreq(Notes[I]) * 1.02, 0.08, 0.26, I * 0.05, 0.25);
  AddVoice(wvTriangle, 200, 800, 0.25, 0.30);
end;

procedure SfxPowerDown;
begin
  AddVoice(wvTriangle, 600, 300, 0.2, 0.30);
end;

procedure SfxHighScore;
const
  Notes: array[0..7] of Byte = (72, 76, 79, 84, 79, 84, 88, 91);
var
  I: Integer;
  F: Single;
begin
  for I := 0 to 7 do
  begin
    F := MidiFreq(Notes[I]);
    AddVoice(wvSquare, F, F, 0.14, 0.24, 0.3 + I * 0.11, 0.25);
    AddVoice(wvTriangle, F / 2, F / 2, 0.14, 0.30, 0.3 + I * 0.11);
  end;
end;

procedure MusicSetLevel(Level: Integer);
const
  Keys:  array[0..9] of Integer = (0, 3, -2, 5, -4, 2, 7, -5, -3, 0);
  Tempo: array[0..9] of Integer = (150, 156, 144, 140, 162, 136, 148, 168, 158, 172);
  Duty:  array[0..9] of Single  = (0.25, 0.5, 0.125, 0.5, 0.25, 0.125, 0.5, 0.25, 0.125, 0.25);
var
  I: Integer;
begin
  I := (Level - 1) mod 10;
  if I < 0 then I := 0;
  Transpose := Keys[I];
  StepSec := 60.0 / Tempo[I] / 2;
  LeadDuty := Duty[I];
  StepIndex := -1;          { restart the loop from bar 1 }
  StepSamples := 0;
end;

procedure SfxExplosion;
begin
  AddVoice(wvNoise, 0, 0, 0.6, 0.55);
  AddVoice(wvSine, 120, 30, 0.5, 0.7);
  AddVoice(wvSquare, 200, 50, 0.25, 0.2);
end;

procedure SfxSteel;
begin
  AddVoice(wvSquare, 1250, 1180, 0.12, 0.18, 0, 0.125);
  AddVoice(wvTriangle, 1870, 1800, 0.2, 0.25);
end;

procedure SfxZap;
begin
  AddVoice(wvSquare, 1800, 300, 0.18, 0.22, 0, 0.125);
  AddVoice(wvNoise, 0, 0, 0.15, 0.2);
  AddVoice(wvSquare, 900, 2400, 0.08, 0.15, 0.06, 0.25);
end;

procedure SfxCrack;
begin
  AddVoice(wvNoise, 0, 0, 0.05, 0.3);
  AddVoice(wvTriangle, 330, 220, 0.08, 0.35);
end;

procedure SfxGold;
begin
  AddVoice(wvSquare, MidiFreq(88), MidiFreq(88), 0.07, 0.25, 0, 0.25);
  AddVoice(wvSquare, MidiFreq(95), MidiFreq(95), 0.18, 0.25, 0.07, 0.25);
end;

procedure SfxLevelStart;
const
  Notes: array[0..2] of Byte = (67, 72, 79);
var
  I: Integer;
begin
  for I := 0 to 2 do
    AddVoice(wvTriangle, MidiFreq(Notes[I]), MidiFreq(Notes[I]), 0.15, 0.4, I * 0.12);
  AddVoice(wvSquare, MidiFreq(84), MidiFreq(84), 0.35, 0.22, 0.36, 0.25);
end;

procedure SfxLevelClear;
const
  Notes: array[0..5] of Byte = (72, 74, 76, 79, 84, 88);
var
  I: Integer;
begin
  for I := 0 to 5 do
  begin
    AddVoice(wvSquare, MidiFreq(Notes[I]), MidiFreq(Notes[I]), 0.12, 0.24, I * 0.08, 0.25);
    AddVoice(wvTriangle, MidiFreq(Notes[I] - 12), MidiFreq(Notes[I] - 12), 0.12, 0.3, I * 0.08);
  end;
  AddVoice(wvSquare, MidiFreq(91), MidiFreq(91), 0.6, 0.25, 0.5, 0.5);
end;

procedure SfxBotPaddle;
begin
  AddVoice(wvSquare, 240, 180, 0.09, 0.32, 0, 0.125);
end;

procedure SfxGoal;
const
  Notes: array[0..3] of Byte = (79, 84, 88, 91);
var
  I: Integer;
begin
  for I := 0 to 3 do
    AddVoice(wvSquare, MidiFreq(Notes[I]), MidiFreq(Notes[I]), 0.1, 0.25, I * 0.06, 0.25);
  AddVoice(wvNoise, 0, 0, 0.3, 0.18, 0.05);
end;

procedure SfxBotGoal;
const
  Notes: array[0..2] of Byte = (64, 60, 55);
var
  I: Integer;
begin
  for I := 0 to 2 do
    AddVoice(wvSquare, MidiFreq(Notes[I]), MidiFreq(Notes[I]) * 0.97, 0.14, 0.25, I * 0.1, 0.5);
end;

end.
