program SDLBreakout;

{ Breakout with 10 levels, using SDL3 + Free Pascal / Lazarus.
  Bindings: sdl3_package from https://github.com/sechshelme/Lazarus-SDL-3.0-Packages-and-Examples

  Units:
    GameLevels      level layouts, brick sizes, styles, colors
    GameBricks      brick record + drawing of the 10 brick styles and 9 brick types
    GameBackground  10 animated backgrounds
    GameDraw        shapes (gradients, ellipses, rings, polygons) via SDL_RenderGeometry
    GameText        TrueType text (SDL3_ttf)
    GameAudio       synthesized music + sound effects
    GameSave        settings, high scores, unlocked levels
    GameCheat       level codes (KQ7M-XP3RT) that store next level + score + lives

  Menu:  Up/Down or mouse = choose, Enter/click = select, Left/Right = change option, Esc = back
  Game:  Left/Right, A/D or mouse = move paddle, Space/click = launch,
         P = pause, Esc = menu, M = music on/off, N = sound on/off, F11 = fullscreen }

{$mode objfpc}{$H+}

uses
  SysUtils, Math, SDL3, GameLevels, GameDraw, GameBricks, GameBackground,
  GameAudio, GameText, GameSave, GameCheat;

const
  ScreenW = 800;
  ScreenH = 600;

  BasePaddleW = 110;
  WidePaddleW = 170;
  PaddleH     = 14;
  PaddleY     = ScreenH - 40;
  PaddleSpeed = 620.0;

  BallSize       = 10;
  BallStartSpeed = 360.0;
  BallMaxSpeed   = 760.0;
  MaxBalls       = 8;
  TrailLen       = 10;

  StartLives = 3;
  MaxLives   = 9;
  PhysStep   = 1.0 / 240.0;   { fixed physics step (seconds) }

  MaxBricks  = 260;

  { versus mode: a bot paddle guards the top, bricks move down to make room }
  VersusShift = 100;
  BotY        = 64;
  BotW        = 110;
  { bot difficulty 1 = easy, 2 = normal, 3 = hard
    (tuned with a simulation: misses about 47% / 25% / 4% of returns) }
  BotSpeed:  array[1..3] of Single = (320, 440, 720);   { px per second }
  BotReact:  array[1..3] of Single = (0.28, 0.14, 0.04); { seconds between decisions }
  BotErr:    array[1..3] of Single = (45, 22, 6);        { aiming error, px }
  BotShadow: array[1..3] of Single = (0, 90, 30);        { 0 = drift to centre, else follow the ball }
  BotAim:    array[1..3] of Single = (0, 0.5, 1.0);      { chance to aim at bricks }

  { power-up drops }
  MaxDrops   = 12;
  DropW      = 44;
  DropH      = 18;
  DropSpeed  = 150.0;
  DropChance = 0.16;
  WideTime   = 12.0;
  SlowTime   = 9.0;
  SlowFactor = 0.6;

  MaxParticles = 1200;
  MaxFlashes   = 48;
  MaxPopups    = 32;
  MaxShocks    = 16;
  MaxBolts     = 24;

  MaxMenuItems = 12;
  MenuCX       = ScreenW / 2;
  MenuHalfW    = 210;

  TitleColors: array[0..5, 0..2] of Byte = (
    (235,  75,  85),
    (245, 145,  60),
    (240, 210,  70),
    ( 90, 200, 110),
    ( 70, 160, 235),
    (150, 110, 230));

type
  TGameState = (gsMenu, gsLevelIntro, gsServe, gsPlaying, gsPaused,
                gsLevelClear, gsGameOver, gsWon);
  TMenuScreen = (msMain, msNewGame, msLevels, msGraphics, msSound, msHighScores, msCheat);
  TPowerKind = (pkWide, pkMulti, pkSlow, pkLife);
  TPShape = (psSquare, psCircle, psDiamond, psStar);

  TParticle = record
    X, Y, VX, VY: Single;
    Life, MaxLife, Size, Grav: Single;
    R, G, B: Byte;
    Shape: TPShape;
  end;

  TFlash = record          { ghost of a broken brick that swells and fades }
    Rect: TSDL_FRect;
    T: Single;
    R, G, B: Byte;
  end;

  TPopup = record          { floating text: "+60", "MULTI-BALL!", "POW!" ... }
    X, Y, T, MaxT: Single;
    Text: string;
    Size: TFontSize;
    R, G, B: Byte;
  end;

  TShock = record          { expanding ring from explosions and pops }
    X, Y, R, MaxR, T, MaxT, Flat: Single;
    C: TCol;
  end;

  TBolt = record           { lightning between electric bricks }
    X1, Y1, X2, Y2, T: Single;
    Seed: Integer;
  end;

  TBall = record
    Active: Boolean;
    Owner: Integer;          { 0 = you hit it last, 1 = the bot }
    X, Y, VX, VY: Single;
    TrailX, TrailY: array[0..TrailLen - 1] of Single;
    TrailCount: Integer;
  end;

  TDrop = record
    Active: Boolean;
    X, Y, T: Single;
    Kind: TPowerKind;
  end;

const
  PowerColor: array[TPowerKind, 0..2] of Byte = (
    ( 70, 170, 255),
    (235,  90, 210),
    ( 90, 220, 140),
    (255,  80,  95));
  PowerLetter: array[TPowerKind] of string = ('W', 'M', 'S', '+1');
  PowerName: array[TPowerKind] of string =
    ('WIDE PADDLE!', 'MULTI-BALL!', 'SLOW BALL!', 'EXTRA LIFE!');

  KindPoints: array[TBrickKind] of Integer = (10, 20, 30, 0, 25, 100, 30, 40, 30);
  KindHint: array[TBrickKind] of string = (
    '', 'TOUGH BRICKS take 2 hits', 'ARMORED BRICKS take 3 hits',
    'STEEL cannot break - you do not need it to clear',
    'EXPLOSIVE bricks blow up their neighbours',
    'GOLD bricks always drop a power-up',
    'MOVING bricks slide from side to side',
    'GHOST bricks fade - the ball passes through when faded',
    'ELECTRIC bricks zap 3 nearby bricks');

  StyleNames: array[TBrickStyle] of string = ('Classic', 'Cartoon', 'Saturn', 'Oval',
    'Cyberpunk', 'Crystal', 'Honeycomb', 'Pixel', 'Glossy lava', 'Mixed');
  BgNames: array[TBgKind] of string = ('Starfield', 'Nebula', 'Warp speed', 'Ocean',
    'Synth city', 'Crystal cave', 'Aurora', 'Digital rain', 'Lava lamp', 'Black hole');

  ComicWords: array[0..4] of string = ('POW!', 'BAM!', 'BOP!', 'ZAP!', 'WHAM!');

  ModeNames: array[0..3] of string = ('SOLO', 'VS BOT - EASY', 'VS BOT - NORMAL', 'VS BOT - HARD');
  ModeShort: array[0..3] of string = ('SOLO', 'EASY', 'NORM', 'HARD');
  BotWinTaunts: array[0..4] of string = ('Too easy!', 'Got you!', 'Beep boop!', 'Calculated.', 'Try harder!');
  BotLoseTaunts: array[0..4] of string = ('Lucky shot...', 'Not fair!', 'Recalculating...', 'Error 404!', 'Hmph.');

var
  Window: PSDL_Window = nil;
  Renderer: PSDL_Renderer = nil;
  Running: Boolean;

  { game }
  State: TGameState = gsMenu;
  ResumeState: TGameState = gsServe;
  GameInProgress: Boolean = False;
  Level: Integer = 1;
  LevelT: Single = 0;            { time in the intro / clear stage }
  IntroLen: Single = 2;
  IntroHint: string = '';
  ClearBonus: Integer = 0;
  Bricks: array[0..MaxBricks - 1] of TBrick;
  BrickCount: Integer = 0;
  BricksLeft: Integer = 0;       { breakable bricks still alive }
  PaddleX, PaddleW: Single;
  Balls: array[0..MaxBalls - 1] of TBall;
  Drops: array[0..MaxDrops - 1] of TDrop;
  WideTimer, SlowTimer: Single;
  SpeedMul: Single = 1.0;
  Lives: Integer;
  LeftDown, RightDown: Boolean;

  { game mode: 0 = solo, 1..3 = against a bot (easy / normal / hard) }
  Mode: Integer = 0;
  StartLevelChoice: Integer = 1;     { set by the LEVELS menu }
  NewGameFrom: TMenuScreen = msMain;
  LastModeSel: Integer = 0;

  { the bot }
  BotX: Single = 400;                { centre of the bot paddle }
  BotTarget: Single = 400;
  BotReactT: Single = 0;
  BotGlow: Single = 0;
  BotScore: Integer = 0;
  BotDisplay: Single = 0;
  BotPulse: Single = 0;
  LevelYou, LevelBot: Integer;       { points scored in this level (round) }
  RoundYou, RoundBot: Integer;       { rounds won }
  RoundMsg: string = '';
  BottomLost: Boolean = False;       { a ball got past you since the last serve }

  { score }
  Score: Integer;
  DisplayScore: Single;
  ScorePulse: Single;
  BestAtStart: Integer;
  BeatBest: Boolean;
  NewRank: Integer = -1;
  EndT: Single;

  { effects }
  Particles: array[0..MaxParticles - 1] of TParticle;
  NextParticle: Integer = 0;
  Flashes: array[0..MaxFlashes - 1] of TFlash;
  NextFlash: Integer = 0;
  Popups: array[0..MaxPopups - 1] of TPopup;
  NextPopup: Integer = 0;
  Shocks: array[0..MaxShocks - 1] of TShock;
  NextShock: Integer = 0;
  Bolts: array[0..MaxBolts - 1] of TBolt;
  NextBolt: Integer = 0;
  Clock: Single = 0;
  ShakeT: Single = 0;
  ShakeAmp: Single = 0;
  ShakeX, ShakeY: Single;
  CamX, CamY: Single;
  BgFlash: Single = 0;
  PaddleGlow: Single = 0;

  { menu }
  MenuScreen: TMenuScreen = msMain;
  MenuSel: Integer = 0;
  MenuCount: Integer = 0;
  MenuLabel, MenuValue: array[0..MaxMenuItems - 1] of string;
  MenuEnabled, MenuIsSlider: array[0..MaxMenuItems - 1] of Boolean;
  MenuSlider: array[0..MaxMenuItems - 1] of Integer;
  MenuHi, MenuPunch: array[0..MaxMenuItems - 1] of Single;
  MenuOpenT: Single = 0;
  SelBarY: Single = 0;
  SelFlash: Single = 0;
  PendingItem: Integer = -1;
  PendingT: Single = 0;
  SelBarX: Single = 400;         { the selection bar glides between items }
  SelBarHW: Single = 210;
  SelBarHH: Single = 22;

  { cheat codes }
  LevelCode: string = '';        { code shown on the level-clear screen }
  CodeCopiedT: Single = 0;
  CheatInput: string = '';       { typed so far, without the dash }
  CheatMsg: string = '';
  CheatMsg2: string = '';
  CheatMsgOK: Boolean = False;
  CheatShake: Single = 0;
  CheatFlash: Single = 0;
  CheatTypedT: Single = 0;       { pop animation of the last typed character }
  CheatStartT: Single = -1;      { countdown before a valid code starts the game }
  CheatLevel, CheatScore, CheatLives, CheatMode, CheatBot: Integer;

{ ================= helpers ================= }

function MakeRect(X, Y, W, H: Single): TSDL_FRect;
begin
  Result.x := X; Result.y := Y; Result.w := W; Result.h := H;
end;

function Overlaps(const A, B: TSDL_FRect): Boolean;
begin
  Result := (A.x < B.x + B.w) and (A.x + A.w > B.x) and
            (A.y < B.y + B.h) and (A.y + A.h > B.y);
end;

function RandRange(A, B: Single): Single;
begin
  Result := A + Random * (B - A);
end;

function MinF(A, B: Single): Single;
begin
  if A < B then Result := A else Result := B;
end;

function MaxF(A, B: Single): Single;
begin
  if A > B then Result := A else Result := B;
end;

function Clamp01(V: Single): Single;
begin
  Result := MinF(1, MaxF(0, V));
end;

function ClampByte(V: Single): Byte;
begin
  Result := Round(EnsureRange(V, 0.0, 255.0));
end;

function LerpB(A, B: Byte; T: Single): Byte;
begin
  Result := ClampByte(A + (B - A) * T);
end;

function EaseOutCubic(T: Single): Single;
begin
  T := Clamp01(T);
  Result := 1 - (1 - T) * (1 - T) * (1 - T);
end;

function EaseOutBack(T: Single): Single;
const
  C1 = 1.70158;
  C3 = C1 + 1;
begin
  T := Clamp01(T) - 1;
  Result := 1 + C3 * T * T * T + C1 * T * T;
end;

procedure Rainbow(H: Single; out R, G, B: Byte);
begin
  R := ClampByte(170 + 85 * Sin(H));
  G := ClampByte(170 + 85 * Sin(H + 2.094));
  B := ClampByte(170 + 85 * Sin(H + 4.189));
end;

procedure Fatal(const Msg: string);
var
  Full: AnsiString;
begin
  Full := Msg + LineEnding + AnsiString(SDL_GetError);
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, 'SDL Breakout', PAnsiChar(Full), nil);
  SDL_Quit;
  Halt(1);
end;

{ every rectangle goes through GameDraw, so DrawOffX/Y (shake) applies }
procedure FillRect(const R: TSDL_FRect; Red, Green, Blue: Byte; Alpha: Byte = 255);
begin
  Rect(R.x, R.y, R.w, R.h, Col(Red, Green, Blue, Alpha));
end;

function Versus: Boolean;
begin
  Result := Mode > 0;
end;

function BallSpeedForLevel: Single;
begin
  Result := BallStartSpeed * (1 + 0.05 * (Level - 1));
end;

function BallMaxForLevel: Single;
begin
  Result := BallMaxSpeed * (1 + 0.03 * (Level - 1));
end;

{ ================= settings ================= }

procedure ApplySettings;
begin
  SDL_SetWindowFullscreen(Window, Settings.Fullscreen);
  SDL_SetRenderVSync(Renderer, Ord(Settings.VSync));
  MusicVolume := Settings.MusicVolume;
  SfxVolume := Settings.SfxVolume;
  BgAnimated := Settings.AnimatedBg;
end;

{ ================= effects ================= }

procedure SpawnParticle(X, Y, VX, VY, Life, Size: Single; R, G, B: Byte;
                        Shape: TPShape = psSquare; Grav: Single = 1.0);
begin
  case Settings.Particles of
    0: Exit;
    1: if Random(2) = 0 then Exit;
  end;
  Particles[NextParticle].X := X;
  Particles[NextParticle].Y := Y;
  Particles[NextParticle].VX := VX;
  Particles[NextParticle].VY := VY;
  Particles[NextParticle].Life := Life;
  Particles[NextParticle].MaxLife := Life;
  Particles[NextParticle].Size := Size;
  Particles[NextParticle].Grav := Grav;
  Particles[NextParticle].R := R;
  Particles[NextParticle].G := G;
  Particles[NextParticle].B := B;
  Particles[NextParticle].Shape := Shape;
  NextParticle := (NextParticle + 1) mod MaxParticles;
end;

procedure Sparks(X, Y: Single; Count: Integer; R, G, B: Byte; Speed: Single);
var
  I: Integer;
  A, S: Single;
begin
  for I := 1 to Count do
  begin
    A := Random * 2 * Pi;
    S := RandRange(0.3, 1.0) * Speed;
    SpawnParticle(X, Y, Cos(A) * S, Sin(A) * S, RandRange(0.2, 0.45),
                  RandRange(2, 3.5), R, G, B);
  end;
end;

procedure Shake(Amp, Time: Single);
begin
  if not Settings.ScreenShake then Exit;
  ShakeAmp := MaxF(ShakeAmp, Amp);
  ShakeT := MaxF(ShakeT, Time);
end;

procedure AddPopup(X, Y: Single; const Text: string; Size: TFontSize;
                   R, G, B: Byte; Time: Single = 0.8);
begin
  Popups[NextPopup].X := X;
  Popups[NextPopup].Y := Y;
  Popups[NextPopup].T := Time;
  Popups[NextPopup].MaxT := Time;
  Popups[NextPopup].Text := Text;
  Popups[NextPopup].Size := Size;
  Popups[NextPopup].R := R;
  Popups[NextPopup].G := G;
  Popups[NextPopup].B := B;
  NextPopup := (NextPopup + 1) mod MaxPopups;
end;

procedure AddShock(X, Y, MaxR, Time, Flat: Single; const C: TCol);
begin
  Shocks[NextShock].X := X;
  Shocks[NextShock].Y := Y;
  Shocks[NextShock].R := 4;
  Shocks[NextShock].MaxR := MaxR;
  Shocks[NextShock].T := Time;
  Shocks[NextShock].MaxT := Time;
  Shocks[NextShock].Flat := Flat;
  Shocks[NextShock].C := C;
  NextShock := (NextShock + 1) mod MaxShocks;
end;

procedure AddBolt(X1, Y1, X2, Y2: Single);
begin
  Bolts[NextBolt].X1 := X1;
  Bolts[NextBolt].Y1 := Y1;
  Bolts[NextBolt].X2 := X2;
  Bolts[NextBolt].Y2 := Y2;
  Bolts[NextBolt].T := 0.35;
  Bolts[NextBolt].Seed := Random(100000);
  NextBolt := (NextBolt + 1) mod MaxBolts;
end;

procedure UpdateEffects(DT: Single);
var
  I: Integer;
begin
  for I := 0 to MaxParticles - 1 do
    if Particles[I].Life > 0 then
    begin
      Particles[I].VY := Particles[I].VY + 700 * Particles[I].Grav * DT;
      Particles[I].VX := Particles[I].VX * (1 - 1.5 * DT);
      Particles[I].X := Particles[I].X + Particles[I].VX * DT;
      Particles[I].Y := Particles[I].Y + Particles[I].VY * DT;
      Particles[I].Life := Particles[I].Life - DT;
    end;

  for I := 0 to MaxFlashes - 1 do
    if Flashes[I].T > 0 then Flashes[I].T := Flashes[I].T - DT;

  for I := 0 to MaxPopups - 1 do
    if Popups[I].T > 0 then
    begin
      Popups[I].T := Popups[I].T - DT;
      Popups[I].Y := Popups[I].Y - 40 * DT;
    end;

  for I := 0 to MaxShocks - 1 do
    if Shocks[I].T > 0 then
    begin
      Shocks[I].T := Shocks[I].T - DT;
      Shocks[I].R := Shocks[I].MaxR * EaseOutCubic(1 - Shocks[I].T / Shocks[I].MaxT);
    end;

  for I := 0 to MaxBolts - 1 do
    if Bolts[I].T > 0 then
    begin
      Bolts[I].T := Bolts[I].T - DT;
      if Random < 0.5 then Bolts[I].Seed := Random(100000);   { flicker }
    end;

  PaddleGlow := MaxF(0, PaddleGlow - DT * 5);
  BgFlash := MaxF(0, BgFlash - DT * 2.5);

  if ShakeT > 0 then
  begin
    ShakeT := ShakeT - DT;
    ShakeX := RandRange(-ShakeAmp, ShakeAmp);
    ShakeY := RandRange(-ShakeAmp, ShakeAmp);
    if ShakeT <= 0 then ShakeAmp := 0;
  end
  else
  begin
    ShakeX := 0;
    ShakeY := 0;
  end;
end;

procedure ClearEffects;
var
  I: Integer;
begin
  for I := 0 to MaxParticles - 1 do Particles[I].Life := 0;
  for I := 0 to MaxFlashes - 1 do Flashes[I].T := 0;
  for I := 0 to MaxPopups - 1 do Popups[I].T := 0;
  for I := 0 to MaxShocks - 1 do Shocks[I].T := 0;
  for I := 0 to MaxBolts - 1 do Bolts[I].T := 0;
end;

{ ================= score ================= }

procedure AddBotScore(Points: Integer);
begin
  if Points <= 0 then Exit;
  Inc(BotScore, Points);
  Inc(LevelBot, Points);
  BotPulse := 1.0;
end;

procedure AddScore(Points: Integer);
var
  I: Integer;
begin
  if Points <= 0 then Exit;
  Inc(Score, Points);
  Inc(LevelYou, Points);
  ScorePulse := 1.0;
  for I := 1 to 4 do
    SpawnParticle(RandRange(20, 90), 40, RandRange(-80, 80), RandRange(-160, -60),
                  RandRange(0.3, 0.6), 2.5, 255, 215, 90);

  if (not BeatBest) and (BestAtStart > 0) and (Score > BestAtStart) then
  begin
    BeatBest := True;
    AddPopup(ScreenW / 2, ScreenH / 2 - 20, 'NEW BEST!', fsLarge, 255, 215, 90, 1.6);
    SfxMenuSelect;
  end;
end;

{ ================= balls ================= }

function ActiveBalls: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to MaxBalls - 1 do
    if Balls[I].Active then Inc(Result);
end;

procedure ResetBalls;
var
  I: Integer;
begin
  for I := 0 to MaxBalls - 1 do
  begin
    Balls[I].Active := False;
    Balls[I].TrailCount := 0;
  end;
  Balls[0].Active := True;
  Balls[0].Owner := 0;
  Balls[0].VX := 0;
  Balls[0].VY := 0;
  Balls[0].X := PaddleX + (PaddleW - BallSize) / 2;
  Balls[0].Y := PaddleY - BallSize - 1;
end;

function FreeBallSlot: Integer;
var
  I: Integer;
begin
  for I := 0 to MaxBalls - 1 do
    if not Balls[I].Active then Exit(I);
  Result := -1;
end;

procedure SpawnMultiBall;
var
  Snapshot: array[0..MaxBalls - 1] of Boolean;
  I, K, Slot: Integer;
  Speed, Angle, NewA: Single;
begin
  for I := 0 to MaxBalls - 1 do Snapshot[I] := Balls[I].Active;
  for I := 0 to MaxBalls - 1 do
    if Snapshot[I] then
      for K := 0 to 1 do
      begin
        Slot := FreeBallSlot;
        if Slot < 0 then Exit;
        Speed := Hypot(Balls[I].VX, Balls[I].VY);
        if Speed < 1 then Speed := BallSpeedForLevel;
        Angle := ArcTan2(Balls[I].VY, Balls[I].VX);
        if K = 0 then NewA := Angle - 0.45 else NewA := Angle + 0.45;
        Balls[Slot] := Balls[I];
        Balls[Slot].TrailCount := 0;
        Balls[Slot].VX := Speed * Cos(NewA);
        Balls[Slot].VY := Speed * Sin(NewA);
        if Abs(Balls[Slot].VY) < Speed * 0.3 then
          Balls[Slot].VY := -Speed * 0.5;
      end;
end;

{ ================= power-ups ================= }

procedure MaybeDrop(X, Y: Single; Force: Boolean);
var
  I, R: Integer;
begin
  if (not Force) and (Random >= DropChance) then Exit;
  for I := 0 to MaxDrops - 1 do
    if not Drops[I].Active then
    begin
      Drops[I].Active := True;
      Drops[I].X := X;
      Drops[I].Y := Y;
      Drops[I].T := 0;
      R := Random(100);
      if R < 35 then Drops[I].Kind := pkWide
      else if R < 65 then Drops[I].Kind := pkMulti
      else if R < 93 then Drops[I].Kind := pkSlow
      else Drops[I].Kind := pkLife;
      Exit;
    end;
end;

procedure ApplyPower(Kind: TPowerKind);
var
  C: Integer;
begin
  case Kind of
    pkWide:  WideTimer := WideTime;
    pkSlow:  SlowTimer := SlowTime;
    pkMulti: SpawnMultiBall;
    pkLife:  if Lives < MaxLives then Inc(Lives);
  end;
  AddPopup(PaddleX + PaddleW / 2, PaddleY - 30, PowerName[Kind], fsMedium,
           PowerColor[Kind, 0], PowerColor[Kind, 1], PowerColor[Kind, 2], 1.2);
  for C := 0 to 2 do
    Sparks(PaddleX + PaddleW * (C + 0.5) / 3, PaddleY, 10,
           PowerColor[Kind, 0], PowerColor[Kind, 1], PowerColor[Kind, 2], 260);
  PaddleGlow := 1.0;
  SfxPowerUp;
end;

procedure UpdateDrops(DT: Single);
var
  I: Integer;
  Paddle: TSDL_FRect;
begin
  Paddle := MakeRect(PaddleX, PaddleY, PaddleW, PaddleH);
  for I := 0 to MaxDrops - 1 do
    if Drops[I].Active then
    begin
      Drops[I].Y := Drops[I].Y + DropSpeed * DT;
      Drops[I].T := Drops[I].T + DT;
      if Overlaps(MakeRect(Drops[I].X - DropW / 2, Drops[I].Y - DropH / 2, DropW, DropH), Paddle) then
      begin
        Drops[I].Active := False;
        ApplyPower(Drops[I].Kind);
      end
      else if Drops[I].Y - DropH > ScreenH then
        Drops[I].Active := False;
    end;
end;

procedure ClearPowerUps;
var
  I: Integer;
begin
  for I := 0 to MaxDrops - 1 do Drops[I].Active := False;
  WideTimer := 0;
  SlowTimer := 0;
end;

{ balls burst, capsules vanish (used when a level or the game ends) }
procedure BurstBallsAndDrops;
var
  I: Integer;
begin
  for I := 0 to MaxBalls - 1 do
    if Balls[I].Active then
    begin
      Sparks(Balls[I].X + BallSize / 2, Balls[I].Y + BallSize / 2, 24, 255, 255, 255, 300);
      Balls[I].Active := False;
    end;
  for I := 0 to MaxDrops - 1 do
    if Drops[I].Active then
    begin
      Sparks(Drops[I].X, Drops[I].Y, 12, PowerColor[Drops[I].Kind, 0],
             PowerColor[Drops[I].Kind, 1], PowerColor[Drops[I].Kind, 2], 200);
      Drops[I].Active := False;
    end;
end;

{ ================= levels ================= }

procedure LoadLevel(N: Integer);
var
  L: TLevelDef;
  Rows, Cols, R, C, K, LeftFree, RightFree: Integer;
  X0, TotalW, CellW, MaxDelay: Single;
  Kind: TBrickKind;
  SeenBefore: set of TBrickKind;
  B: ^TBrick;
begin
  Level := EnsureRange(N, 1, LevelCount);
  L := Levels[Level];
  Rows := LevelRows(L);
  Cols := LevelCols(L);
  CellW := L.BrickW + L.Gap;
  TotalW := Cols * L.BrickW + (Cols - 1) * L.Gap;
  if L.OffsetOdd then TotalW := TotalW + CellW / 2;
  X0 := (ScreenW - TotalW) / 2;

  BrickCount := 0;
  BricksLeft := 0;
  MaxDelay := 0;
  for R := 0 to Rows - 1 do
    for C := 0 to Cols - 1 do
    begin
      if not CharToKind(L.Map[R][C + 1], Kind) then Continue;
      if BrickCount >= MaxBricks then Break;
      B := @Bricks[BrickCount];
      Inc(BrickCount);

      B^.Alive := True;
      B^.Kind := Kind;
      if L.Style = lsMixed then B^.Style := TBrickStyle((R + C) mod 9)
      else B^.Style := L.Style;
      case Kind of
        bkTough:   B^.MaxHP := 2;
        bkArmored: B^.MaxHP := 3;
      else
        B^.MaxHP := 1;
      end;
      B^.HP := B^.MaxHP;
      B^.X := X0 + C * CellW;
      if L.OffsetOdd and Odd(R) then B^.X := B^.X + CellW / 2;
      B^.Y := L.Top + R * (L.BrickH + L.Gap);
      if Versus then B^.Y := B^.Y + VersusShift;
      B^.W := L.BrickW;
      B^.H := L.BrickH;
      B^.OffX := 0;
      B^.Row := R;
      B^.Col := C;
      LevelColor(L, R, C, B^.R, B^.G, B^.B);
      B^.Flash := 0;
      B^.Squash := 0;
      B^.Phase := Random;
      B^.Spawn := 0;
      B^.SpawnDelay := R * 0.06 + C * 0.025;
      MaxDelay := MaxF(MaxDelay, B^.SpawnDelay);
      B^.PendingT := 0;
      B^.PendingDmg := 0;
      B^.PendingOwner := 0;

      { moving bricks slide into the empty cells beside them
        (map strings are 1-based: cell C is Map[R][C + 1]) }
      B^.MoveAmp := 0;
      B^.MoveSpeed := RandRange(1.2, 1.8);
      if Kind = bkMoving then
      begin
        LeftFree := 0;
        while (C - LeftFree - 1 >= 0) and (L.Map[R][C - LeftFree] = '.') do Inc(LeftFree);
        RightFree := 0;
        while (C + RightFree + 1 < Cols) and (L.Map[R][C + RightFree + 2] = '.') do Inc(RightFree);
        B^.MoveAmp := Min(LeftFree, RightFree) * CellW * 0.95;
      end;

      if Kind <> bkSteel then Inc(BricksLeft);
    end;

  { the first time a level contains a new kind of brick, explain it }
  SeenBefore := [];
  for K := 1 to Level - 1 do
    for R := 0 to LevelRows(Levels[K]) - 1 do
      for C := 1 to Length(Levels[K].Map[R]) do
        if CharToKind(Levels[K].Map[R][C], Kind) then Include(SeenBefore, Kind);
  IntroHint := '';
  for R := 0 to Rows - 1 do
    for C := 1 to Cols do
      if CharToKind(L.Map[R][C], Kind) and not (Kind in SeenBefore) and (KindHint[Kind] <> '') then
      begin
        if IntroHint = '' then IntroHint := 'NEW: ' + KindHint[Kind];
        Include(SeenBefore, Kind);
      end;

  BgSet(L.Bg);
  MusicSetLevel(Level);
  ClearPowerUps;
  PaddleW := BasePaddleW;
  PaddleX := (ScreenW - PaddleW) / 2;
  SpeedMul := 1.0;
  ResetBalls;
  BottomLost := False;
  UnlockLevel(Level);
  LevelYou := 0;
  LevelBot := 0;
  BotX := ScreenW / 2;
  BotTarget := BotX;

  IntroLen := MaxDelay + 1.7;
  LevelT := 0;
  State := gsLevelIntro;
  SfxLevelStart;
end;

procedure FinishIntro;
var
  I: Integer;
begin
  for I := 0 to BrickCount - 1 do Bricks[I].Spawn := 1;
  State := gsServe;
end;

procedure NewGame(StartLevel, AMode: Integer);
begin
  Mode := EnsureRange(AMode, 0, 3);
  BotScore := 0;
  BotDisplay := 0;
  BotPulse := 0;
  RoundYou := 0;
  RoundBot := 0;
  Score := 0;
  DisplayScore := 0;
  ScorePulse := 0;
  BestAtStart := BestScore;
  BeatBest := False;
  NewRank := -1;
  Lives := StartLives;
  ClearEffects;
  GameInProgress := True;
  LoadLevel(StartLevel);
end;

procedure EndGame(Won: Boolean);
begin
  BurstBallsAndDrops;
  if Won then State := gsWon else State := gsGameOver;
  GameInProgress := False;
  EndT := 0;
  NewRank := AddHighScore(Score, Level, Mode);
  if Won then SfxWin else SfxGameOver;
  if NewRank >= 0 then SfxHighScore;
end;

procedure LevelComplete;
var
  I: Integer;
begin
  BurstBallsAndDrops;
  for I := 0 to BrickCount - 1 do Bricks[I].PendingDmg := 0;
  ClearBonus := 250 * Level + 100 * Lives;
  if not Versus then
    AddScore(ClearBonus)
  else if LevelYou >= LevelBot then
  begin   { round won: you get the bonus }
    Inc(RoundYou);
    RoundMsg := 'YOU WIN THE ROUND!';
    AddScore(ClearBonus);
  end
  else
  begin   { round lost: the bot gets a bonus }
    Inc(RoundBot);
    RoundMsg := 'BOT WINS THE ROUND';
    ClearBonus := 250 * Level;
    AddBotScore(ClearBonus);
  end;
  if Level < LevelCount then
  begin
    UnlockLevel(Level + 1);
    { the code starts the NEXT level with the score and lives you have now }
    LevelCode := MakeCheatCode(Level + 1, Score, Lives, Mode, BotScore);
    SaveLastCode(Level + 1, LevelCode);
  end
  else
    LevelCode := '';
  CodeCopiedT := 0;
  State := gsLevelClear;
  LevelT := 0;
  WideTimer := 0;
  SlowTimer := 0;
  SfxLevelClear;
end;

procedure NextLevel;
begin
  if Level >= LevelCount then EndGame(True)
  else LoadLevel(Level + 1);
end;

procedure LaunchBall;
var
  Angle: Single;
begin
  Angle := (Random - 0.5) * 1.0;
  Balls[0].VX := BallSpeedForLevel * Sin(Angle);
  Balls[0].VY := -BallSpeedForLevel * Cos(Angle);
  State := gsPlaying;
  SfxLaunch;
end;

procedure ServeBall;
begin
  State := gsServe;
  ResetBalls;
  BottomLost := False;
end;

procedure LoseLife;
begin
  Dec(Lives);
  Shake(10, 0.35);
  ClearPowerUps;
  if Lives <= 0 then
    EndGame(False)
  else
  begin
    SfxLoseLife;
    ServeBall;
  end;
end;

{ ================= bricks: hits, destruction, chain reactions ================= }

function BrickCenterX(I: Integer): Single;
begin
  Result := Bricks[I].X + Bricks[I].OffX + Bricks[I].W / 2;
end;

function BrickCenterY(I: Integer): Single;
begin
  Result := Bricks[I].Y + Bricks[I].H / 2;
end;

{ queue damage on a brick after a short delay (makes chains ripple outward) }
procedure QueueDamage(I, Dmg: Integer; Delay: Single; Owner: Integer);
begin
  if (not Bricks[I].Alive) or (Bricks[I].Kind = bkSteel) then Exit;
  Bricks[I].PendingOwner := Owner;
  if Bricks[I].PendingDmg = 0 then Bricks[I].PendingT := Delay
  else Bricks[I].PendingT := MinF(Bricks[I].PendingT, Delay);
  Bricks[I].PendingDmg := Max(Bricks[I].PendingDmg, Dmg);
end;

{ debris that matches the brick's look }
procedure StyleDebris(I: Integer);
var
  B: TBrick;
  CX, CY, A, S: Single;
  K, N: Integer;
  C: TCol;
  ComicWord: string;
begin
  B := Bricks[I];
  CX := BrickCenterX(I);
  CY := BrickCenterY(I);
  C := BrickColor(B);

  case B.Style of
    lsCartoon:
      begin
        for K := 1 to 14 do
        begin
          A := Random * 2 * Pi; S := RandRange(80, 300);
          SpawnParticle(CX, CY, Cos(A) * S, Sin(A) * S - 120, RandRange(0.4, 0.8), RandRange(4, 7),
                        C.R, C.G, C.B, psCircle);
        end;
        for K := 1 to 5 do
        begin
          A := Random * 2 * Pi; S := RandRange(100, 260);
          SpawnParticle(CX, CY, Cos(A) * S, Sin(A) * S - 100, RandRange(0.4, 0.7), 9,
                        255, 240, 120, psStar, 0.5);
        end;
        if Random < 0.45 then
        begin
          ComicWord := ComicWords[Random(Length(ComicWords))];
          AddPopup(CX, CY - 12, ComicWord, fsMedium, 255, 235, 80, 0.7);
        end;
      end;

    lsSaturn, lsOval, lsGlossy:
      begin
        if B.Style = lsSaturn then N := 16 else N := 14;
        for K := 1 to N do
        begin
          A := Random * 2 * Pi; S := RandRange(60, 300);
          SpawnParticle(CX, CY, Cos(A) * S, Sin(A) * S - 100, RandRange(0.4, 0.9), RandRange(3, 6),
                        C.R, C.G, C.B, psCircle);
        end;
        if B.Style = lsSaturn then
          AddShock(CX, CY, B.W * 1.1, 0.35, 0.3, ColMix(C, Col(255, 255, 255), 0.5))
        else if B.Style = lsOval then
          AddShock(CX, CY, B.W * 0.7, 0.25, 0.6, Col(255, 255, 255, 200))
        else
          for K := 1 to 10 do   { lava embers float up }
            SpawnParticle(CX + RandRange(-B.W / 2, B.W / 2), CY, RandRange(-40, 40), RandRange(-120, -40),
                          RandRange(0.6, 1.2), 2.5, 255, ClampByte(RandRange(120, 220)), 40, psCircle, -0.15);
      end;

    lsCyber:
      for K := 1 to 26 do
      begin
        A := Random * 2 * Pi; S := RandRange(80, 360);
        if Odd(K) then
          SpawnParticle(CX, CY, Cos(A) * S, Sin(A) * S * 0.5, RandRange(0.3, 0.7), RandRange(2, 5),
                        0, 240, 255, psSquare, 0.3)
        else
          SpawnParticle(CX, CY, Cos(A) * S, Sin(A) * S * 0.5, RandRange(0.3, 0.7), RandRange(2, 5),
                        255, 40, 210, psSquare, 0.3);
      end;

    lsCrystal, lsHex:
      begin
        for K := 1 to 20 do
        begin
          A := Random * 2 * Pi; S := RandRange(80, 320);
          SpawnParticle(CX + RandRange(-B.W / 3, B.W / 3), CY, Cos(A) * S, Sin(A) * S - 100,
                        RandRange(0.5, 1.0), RandRange(4, 8),
                        ClampByte(C.R + 40), ClampByte(C.G + 40), ClampByte(C.B + 40), psDiamond);
        end;
        for K := 1 to 5 do
          SpawnParticle(CX + RandRange(-B.W / 2, B.W / 2), CY + RandRange(-B.H / 2, B.H / 2),
                        0, -20, RandRange(0.3, 0.6), 10, 255, 255, 255, psStar, 0);
      end;

    lsPixel:
      for K := 1 to 14 do
        SpawnParticle(CX + RandRange(-B.W / 2, B.W / 2), CY + RandRange(-B.H / 2, B.H / 2),
                      RandRange(-120, 120), RandRange(-220, -40), RandRange(0.5, 0.9), 4,
                      C.R, C.G, C.B, psSquare, 1.4);

  else { classic and anything else: chunky rectangles + sparks }
    for K := 1 to 26 do
    begin
      A := Random * 2 * Pi; S := RandRange(60, 330);
      if K mod 5 = 0 then
        SpawnParticle(CX + RandRange(-B.W / 2, B.W / 2), CY, Cos(A) * S * 1.3, Sin(A) * S * 1.3 - 120,
                      RandRange(0.25, 0.5), 2, 255, 255, 255)
      else
        SpawnParticle(CX + RandRange(-B.W / 2, B.W / 2), CY + RandRange(-B.H / 2, B.H / 2),
                      Cos(A) * S, Sin(A) * S - 120, RandRange(0.5, 1.0), RandRange(3, 6),
                      ClampByte(C.R + RandRange(-25, 25)), ClampByte(C.G + RandRange(-25, 25)),
                      ClampByte(C.B + RandRange(-25, 25)));
    end;
  end;

  { the swelling "ghost" of the brick }
  Flashes[NextFlash].Rect := BrickCurRect(B);
  Flashes[NextFlash].T := 0.3;
  Flashes[NextFlash].R := C.R;
  Flashes[NextFlash].G := C.G;
  Flashes[NextFlash].B := C.B;
  NextFlash := (NextFlash + 1) mod MaxFlashes;
end;

procedure DestroyBrick(I, Owner: Integer);
var
  J, K, Best, Found, Pts: Integer;
  CX, CY, D, BestD, Radius: Single;
  Used: array[0..MaxBricks - 1] of Boolean;
begin
  if not Bricks[I].Alive then Exit;
  Bricks[I].Alive := False;
  Bricks[I].PendingDmg := 0;
  Dec(BricksLeft);
  CX := BrickCenterX(I);
  CY := BrickCenterY(I);

  Pts := KindPoints[Bricks[I].Kind] + 5 * (Level - 1);
  StyleDebris(I);
  if Owner = 1 then
  begin   { the bot's ball broke it: orange popup, points to the bot }
    AddBotScore(Pts);
    AddPopup(CX, CY, '+' + IntToStr(Pts), fsSmall, 255, 150, 60);
  end
  else
  begin
    AddScore(Pts);
    if Bricks[I].Kind = bkGold then
      AddPopup(CX, CY, '+' + IntToStr(Pts), fsMedium, 255, 215, 90, 1.0)
    else
      AddPopup(CX, CY, '+' + IntToStr(Pts), fsSmall, 255, 245, 200);
  end;
  Shake(3, 0.12);
  BgFlash := MinF(BgFlash + 0.35, 1.0);

  case Bricks[I].Kind of
    bkExplosive:
      begin
        Radius := (Bricks[I].W + Bricks[I].H) * 1.15;
        AddShock(CX, CY, Radius * 1.3, 0.45, 1.0, Col(255, 180, 80, 230));
        AddShock(CX, CY, Radius * 0.8, 0.3, 1.0, Col(255, 255, 220, 255));
        for K := 1 to 34 do
          SpawnParticle(CX, CY, RandRange(-260, 260), RandRange(-300, 120), RandRange(0.4, 0.9),
                        RandRange(3, 7), 255, ClampByte(RandRange(90, 230)), 30, psCircle, -0.25);
        for K := 1 to 10 do
          SpawnParticle(CX + RandRange(-20, 20), CY, RandRange(-40, 40), RandRange(-90, -30),
                        RandRange(0.8, 1.4), RandRange(6, 10), 90, 80, 90, psCircle, -0.05);
        Shake(9, 0.3);
        BgFlash := 1;
        SfxExplosion;
        { neighbours take heavy damage a moment later; other X bricks chain }
        for J := 0 to BrickCount - 1 do
          if (J <> I) and Bricks[J].Alive then
          begin
            D := Hypot(BrickCenterX(J) - CX, BrickCenterY(J) - CY);
            if D < Radius then QueueDamage(J, 9, 0.08 + D / 1400, Owner);
          end;
      end;

    bkElectric:
      begin
        { lightning to the 3 nearest breakable bricks }
        for J := 0 to BrickCount - 1 do Used[J] := False;
        Found := 0;
        for K := 1 to 3 do
        begin
          Best := -1;
          BestD := 240;
          for J := 0 to BrickCount - 1 do
            if (J <> I) and Bricks[J].Alive and (Bricks[J].Kind <> bkSteel) and not Used[J] then
            begin
              D := Hypot(BrickCenterX(J) - CX, BrickCenterY(J) - CY);
              if D < BestD then begin BestD := D; Best := J; end;
            end;
          if Best < 0 then Break;
          Used[Best] := True;
          Inc(Found);
          AddBolt(CX, CY, BrickCenterX(Best), BrickCenterY(Best));
          QueueDamage(Best, 1, 0.12 + K * 0.05, Owner);
        end;
        Sparks(CX, CY, 20, 140, 240, 255, 300);
        BgFlash := 1;
        Shake(4, 0.15);
        if Found > 0 then SfxZap;
      end;

    bkGold:
      begin
        for K := 1 to 18 do
          SpawnParticle(CX, CY, RandRange(-220, 220), RandRange(-360, -120), RandRange(0.6, 1.1),
                        RandRange(4, 6), 255, ClampByte(RandRange(190, 230)), 60, psCircle);
        SfxGold;
      end;

    bkGhost:
      for K := 1 to 12 do
        SpawnParticle(CX + RandRange(-20, 20), CY, RandRange(-30, 30), RandRange(-80, -20),
                      RandRange(0.6, 1.2), RandRange(5, 9), 190, 150, 255, psCircle, -0.1);
  end;

  MaybeDrop(CX, CY, Bricks[I].Kind = bkGold);

  if (BricksLeft <= 0) and (State in [gsPlaying, gsServe]) then LevelComplete;
end;

{ FromBall = hit by a ball (steel clangs); otherwise chain damage }
procedure HitBrick(I, Dmg: Integer; FromBall: Boolean; Owner: Integer);
var
  CX, CY: Single;
  C: TCol;
begin
  if not Bricks[I].Alive then Exit;
  CX := BrickCenterX(I);
  CY := BrickCenterY(I);

  if Bricks[I].Kind = bkSteel then
  begin
    if FromBall then
    begin
      Bricks[I].Flash := 1;
      Bricks[I].Squash := 0.5;
      Sparks(CX, CY, 8, 255, 255, 255, 260);
      SfxSteel;
    end;
    Exit;
  end;

  Bricks[I].HP := Bricks[I].HP - Dmg;
  if Bricks[I].HP > 0 then
  begin
    { survived: crack, chips, wobble }
    Bricks[I].Flash := 1;
    Bricks[I].Squash := 1;
    C := BrickColor(Bricks[I]);
    Sparks(CX, CY, 8, ClampByte(C.R * 0.7), ClampByte(C.G * 0.7), ClampByte(C.B * 0.7), 200);
    if Owner = 1 then AddBotScore(5) else AddScore(5);
    SfxCrack;
    Exit;
  end;

  SfxBrick(Bricks[I].Row mod 6);
  DestroyBrick(I, Owner);
end;

procedure UpdateBricks(DT: Single);
var
  I, Dmg: Integer;
begin
  for I := 0 to BrickCount - 1 do
    if Bricks[I].Alive then
    begin
      if State = gsLevelIntro then
        Bricks[I].Spawn := Clamp01((LevelT - Bricks[I].SpawnDelay) / 0.5);
      Bricks[I].Flash := MaxF(0, Bricks[I].Flash - DT * 4);
      Bricks[I].Squash := MaxF(0, Bricks[I].Squash - DT * 5);
      if Bricks[I].MoveAmp > 0 then
        Bricks[I].OffX := Sin(Clock * Bricks[I].MoveSpeed + Bricks[I].Phase * 6) * Bricks[I].MoveAmp;

      { chain damage arriving from explosions / lightning }
      if (Bricks[I].PendingDmg > 0) and (State in [gsPlaying, gsServe]) then
      begin
        Bricks[I].PendingT := Bricks[I].PendingT - DT;
        if Bricks[I].PendingT <= 0 then
        begin
          Dmg := Bricks[I].PendingDmg;
          Bricks[I].PendingDmg := 0;
          HitBrick(I, Dmg, False, Bricks[I].PendingOwner);
        end;
      end;
    end;
end;

{ ================= the bot ================= }

procedure BotTaunt(Won: Boolean);
begin
  if Random < 0.45 then
  begin
    if Won then
      AddPopup(BotX, BotY + 42, BotWinTaunts[Random(Length(BotWinTaunts))], fsSmall, 255, 150, 60, 1.3)
    else
      AddPopup(BotX, BotY + 42, BotLoseTaunts[Random(Length(BotLoseTaunts))], fsSmall, 255, 150, 60, 1.3);
  end;
end;

{ your ball flew past the bot }
procedure PlayerGoal(X: Single);
var
  Pts: Integer;
begin
  Pts := 100 + 25 * Level;
  AddScore(Pts);
  AddPopup(EnsureRange(X, 60.0, ScreenW - 60.0), 96, 'GOAL!  +' + IntToStr(Pts), fsMedium, 255, 215, 90, 1.1);
  Sparks(X, 4, 30, 255, 215, 90, 360);
  Shake(5, 0.2);
  BgFlash := 1;
  SfxGoal;
  BotTaunt(False);
end;

{ a ball got past you }
procedure BotGoal(X: Single);
var
  Pts: Integer;
begin
  Pts := 100 + 25 * Level;
  AddBotScore(Pts);
  AddPopup(EnsureRange(X, 60.0, ScreenW - 60.0), PaddleY - 40, 'BOT  +' + IntToStr(Pts), fsMedium, 255, 150, 60, 1.1);
  SfxBotGoal;
  BotTaunt(True);
end;

{ where a ball centre will be when it reaches height TY, bouncing off the side walls }
function PredictX(X, VX, T: Single): Single;
var
  Lo, Span: Single;
begin
  Lo := BallSize / 2;
  Span := ScreenW - BallSize;
  X := X + VX * T - Lo;
  X := X - Floor(X / (2 * Span)) * (2 * Span);
  if X > Span then X := 2 * Span - X;
  Result := X + Lo;
end;

{ pick a brick worth aiming at: explosives and gold count extra }
function BotAimBrick: Integer;
var
  I: Integer;
  W, Best: Single;
begin
  Result := -1;
  Best := 0;
  for I := 0 to BrickCount - 1 do
    if Bricks[I].Alive and (Bricks[I].Kind <> bkSteel) then
    begin
      case Bricks[I].Kind of
        bkExplosive: W := 4;
        bkGold, bkElectric: W := 3;
      else
        W := 1;
      end;
      W := W * Random;
      if W > Best then
      begin
        Best := W;
        Result := I;
      end;
    end;
end;

procedure ChooseBotTarget;
var
  I, Best, Aim: Integer;
  T, BestT, X, Hit, Angle, Err: Single;
begin
  Err := BotErr[Mode];
  Best := -1;
  BestT := 1e9;
  for I := 0 to MaxBalls - 1 do
    if Balls[I].Active and (Balls[I].VY < 0) then
    begin
      T := (Balls[I].Y - (BotY + PaddleH)) / (-Balls[I].VY * SpeedMul);
      if (T >= 0) and (T < BestT) then
      begin
        BestT := T;
        Best := I;
      end;
    end;

  if Best >= 0 then
  begin
    { a ball is coming: be where it will arrive }
    X := PredictX(Balls[Best].X + BallSize / 2, Balls[Best].VX * SpeedMul, BestT);
    Hit := RandRange(-0.3, 0.3);
    if Random < BotAim[Mode] then
    begin
      { choose where on the paddle to meet the ball so it flies at a brick }
      Aim := BotAimBrick;
      if Aim >= 0 then
      begin
        Angle := ArcTan2(BrickCenterX(Aim) - X, BrickCenterY(Aim) - (BotY + PaddleH));
        Hit := EnsureRange(Angle / 1.05, -0.85, 0.85);
      end;
    end;
    BotTarget := X - Hit * BotW / 2 + RandRange(-Err, Err);
  end
  else if BotShadow[Mode] = 0 then
    BotTarget := ScreenW / 2 + Sin(Clock * 0.7) * 80        { easy: drift around the middle }
  else
  begin
    { normal / hard: shadow the nearest ball (or your paddle before a serve) }
    X := PaddleX + PaddleW / 2;
    for I := 0 to MaxBalls - 1 do
      if Balls[I].Active and ((Balls[I].VX <> 0) or (Balls[I].VY <> 0)) then
      begin
        X := Balls[I].X + BallSize / 2;
        Break;
      end;
    BotTarget := X + RandRange(-BotShadow[Mode], BotShadow[Mode]);
  end;
end;

procedure UpdateBot(DT: Single);
var
  Step: Single;
begin
  if not Versus then Exit;
  BotGlow := MaxF(0, BotGlow - DT * 5);
  BotPulse := MaxF(0, BotPulse - DT * 2.5);
  BotDisplay := BotDisplay + (BotScore - BotDisplay) * MinF(1, DT * 6);
  if Abs(BotScore - BotDisplay) < 0.5 then BotDisplay := BotScore;

  if State in [gsServe, gsPlaying, gsLevelIntro] then
  begin
    BotReactT := BotReactT - DT;
    if BotReactT <= 0 then
    begin
      BotReactT := BotReact[Mode] * RandRange(0.7, 1.3);
      ChooseBotTarget;
    end;
  end;

  Step := BotSpeed[Mode] * DT;
  if Abs(BotTarget - BotX) <= Step then BotX := BotTarget
  else if BotTarget > BotX then BotX := BotX + Step
  else BotX := BotX - Step;
  BotX := EnsureRange(BotX, BotW / 2, ScreenW - BotW / 2);
end;

{ ================= ball physics ================= }

procedure StepBall(var B: TBall; DT: Single);
var
  BR, Paddle, Bk: TSDL_FRect;
  I: Integer;
  Hit, Speed, Angle: Single;
  OvL, OvR, OvT, OvB: Single;
begin
  B.X := B.X + B.VX * DT * SpeedMul;
  B.Y := B.Y + B.VY * DT * SpeedMul;

  { walls }
  if B.X < 0 then
  begin
    B.X := 0; B.VX := Abs(B.VX);
    SfxWall; Sparks(B.X, B.Y + BallSize / 2, 6, 200, 220, 255, 160);
  end;
  if B.X + BallSize > ScreenW then
  begin
    B.X := ScreenW - BallSize; B.VX := -Abs(B.VX);
    SfxWall; Sparks(B.X + BallSize, B.Y + BallSize / 2, 6, 200, 220, 255, 160);
  end;
  if Versus then
  begin
    if B.Y + BallSize < 0 then
    begin   { past the bot: goal for you }
      B.Active := False;
      PlayerGoal(B.X + BallSize / 2);
      Exit;
    end;
  end
  else if B.Y < 0 then
  begin
    B.Y := 0; B.VY := Abs(B.VY);
    SfxWall; Sparks(B.X + BallSize / 2, B.Y, 6, 200, 220, 255, 160);
  end;

  if B.Y > ScreenH then
  begin
    B.Active := False;
    BottomLost := True;
    Sparks(B.X, ScreenH - 4, 20, 255, 90, 90, 320);
    if Versus then BotGoal(B.X + BallSize / 2);
    Exit;
  end;

  BR := MakeRect(B.X, B.Y, BallSize, BallSize);

  Paddle := MakeRect(PaddleX, PaddleY, PaddleW, PaddleH);
  if (B.VY > 0) and Overlaps(BR, Paddle) then
  begin
    B.Y := PaddleY - BallSize;
    Hit := ((B.X + BallSize / 2) - (PaddleX + PaddleW / 2)) / (PaddleW / 2);
    Hit := EnsureRange(Hit, -1.0, 1.0);
    Speed := MinF(Hypot(B.VX, B.VY) * 1.03, BallMaxForLevel);
    Angle := Hit * 1.05;
    B.VX := Speed * Sin(Angle);
    B.VY := -Speed * Cos(Angle);
    B.Owner := 0;
    SfxPaddle;
    PaddleGlow := 1.0;
    Sparks(B.X + BallSize / 2, PaddleY, 10, 230, 235, 255, 220);
    Exit;
  end;

  { the bot's paddle: same bounce rule, sends the ball down }
  if Versus and (B.VY < 0) then
  begin
    Paddle := MakeRect(BotX - BotW / 2, BotY, BotW, PaddleH);
    if Overlaps(BR, Paddle) then
    begin
      B.Y := BotY + PaddleH;
      Hit := ((B.X + BallSize / 2) - BotX) / (BotW / 2);
      Hit := EnsureRange(Hit, -1.0, 1.0);
      Speed := MinF(Hypot(B.VX, B.VY) * 1.03, BallMaxForLevel);
      Angle := Hit * 1.05;
      B.VX := Speed * Sin(Angle);
      B.VY := Speed * Cos(Angle);
      B.Owner := 1;
      SfxBotPaddle;
      BotGlow := 1.0;
      Sparks(B.X + BallSize / 2, BotY + PaddleH, 10, 255, 160, 70, 220);
      Exit;
    end;
  end;

  { bricks: at most one hit per step; faded ghosts are skipped }
  for I := 0 to BrickCount - 1 do
    if Bricks[I].Alive and GhostSolid(Bricks[I], Clock) then
    begin
      Bk := BrickCurRect(Bricks[I]);
      if Overlaps(BR, Bk) then
      begin
        OvL := (BR.x + BR.w) - Bk.x;
        OvR := (Bk.x + Bk.w) - BR.x;
        OvT := (BR.y + BR.h) - Bk.y;
        OvB := (Bk.y + Bk.h) - BR.y;
        if MinF(OvL, OvR) < MinF(OvT, OvB) then
        begin
          if OvL < OvR then begin B.VX := -Abs(B.VX); B.X := Bk.x - BallSize; end
          else begin B.VX := Abs(B.VX); B.X := Bk.x + Bk.w; end;
        end
        else
        begin
          if OvT < OvB then begin B.VY := -Abs(B.VY); B.Y := Bk.y - BallSize; end
          else begin B.VY := Abs(B.VY); B.Y := Bk.y + Bk.h; end;
        end;
        HitBrick(I, 1, True, B.Owner);
        Exit;
      end;
    end;
end;

procedure RecordTrail(var B: TBall);
var
  I: Integer;
begin
  for I := TrailLen - 1 downto 1 do
  begin
    B.TrailX[I] := B.TrailX[I - 1];
    B.TrailY[I] := B.TrailY[I - 1];
  end;
  B.TrailX[0] := B.X;
  B.TrailY[0] := B.Y;
  if B.TrailCount < TrailLen then Inc(B.TrailCount);
end;

procedure UpdateScoreDisplay(DT: Single);
begin
  DisplayScore := DisplayScore + (Score - DisplayScore) * MinF(1, DT * 6);
  if Abs(Score - DisplayScore) < 0.5 then DisplayScore := Score;
  ScorePulse := MaxF(0, ScorePulse - DT * 2.5);
end;

procedure UpdatePaddle(DT: Single);
var
  Center, Target: Single;
begin
  if LeftDown then PaddleX := PaddleX - PaddleSpeed * DT;
  if RightDown then PaddleX := PaddleX + PaddleSpeed * DT;

  if WideTimer > 0 then
  begin
    WideTimer := WideTimer - DT;
    if WideTimer <= 0 then begin WideTimer := 0; SfxPowerDown; end;
  end;
  if SlowTimer > 0 then
  begin
    SlowTimer := SlowTimer - DT;
    if SlowTimer <= 0 then begin SlowTimer := 0; SfxPowerDown; end;
  end;

  if WideTimer > 0 then Target := WidePaddleW else Target := BasePaddleW;
  Center := PaddleX + PaddleW / 2;
  PaddleW := PaddleW + (Target - PaddleW) * MinF(1, DT * 10);
  PaddleX := EnsureRange(Center - PaddleW / 2, 0.0, ScreenW - PaddleW);

  if SlowTimer > 0 then Target := SlowFactor else Target := 1.0;
  SpeedMul := SpeedMul + (Target - SpeedMul) * MinF(1, DT * 4);
end;

procedure UpdateGame(DT: Single);
var
  I: Integer;
  H, FrameDT: Single;
begin
  FrameDT := DT;
  UpdatePaddle(DT);
  UpdateBot(DT);

  if State in [gsServe, gsLevelIntro] then
  begin
    Balls[0].X := PaddleX + (PaddleW - BallSize) / 2;
    Balls[0].Y := PaddleY - BallSize - 1;
    Exit;
  end;

  while (DT > 0) and (State = gsPlaying) do
  begin
    H := MinF(DT, PhysStep);
    for I := 0 to MaxBalls - 1 do
      if Balls[I].Active and (State = gsPlaying) then
        StepBall(Balls[I], H);
    if (State = gsPlaying) and (ActiveBalls = 0) then
    begin
      if BottomLost then LoseLife
      else ServeBall;         { every ball went past the bot: serve again }
    end;
    DT := DT - PhysStep;
  end;

  if State = gsPlaying then
  begin
    UpdateDrops(FrameDT);
    for I := 0 to MaxBalls - 1 do
      if Balls[I].Active then RecordTrail(Balls[I]);
  end;
end;

{ ================= menu ================= }

function OnOff(B: Boolean): string;
begin
  if B then Result := 'ON' else Result := 'OFF';
end;

procedure SetItem(I: Integer; const ALabel, AValue: string; AEnabled: Boolean = True);
begin
  MenuLabel[I] := ALabel;
  MenuValue[I] := AValue;
  MenuEnabled[I] := AEnabled;
  MenuIsSlider[I] := False;
  MenuSlider[I] := 0;
end;

procedure SetSlider(I: Integer; const ALabel: string; AValue: Integer);
begin
  SetItem(I, ALabel, '');
  MenuIsSlider[I] := True;
  MenuSlider[I] := AValue;
end;

function Unlocked: Integer;
begin
  Result := EnsureRange(UnlockedLevel, 1, LevelCount);
end;

procedure BuildMenu;
const
  ParticleNames: array[0..2] of string = ('OFF', 'LOW', 'HIGH');
var
  I: Integer;
begin
  case MenuScreen of
    msMain:
      begin
        MenuCount := 8;
        SetItem(0, 'NEW GAME', '');
        SetItem(1, 'CONTINUE', '', GameInProgress);
        SetItem(2, 'LEVELS', '');
        SetItem(3, 'HIGH SCORES', '');
        SetItem(4, 'GRAPHICS', '');
        SetItem(5, 'SOUND', '');
        SetItem(6, 'EXIT', '');
        SetItem(7, 'Cheat-code', '');     { small button in the corner }
      end;
    msNewGame:
      begin
        MenuCount := 5;
        SetItem(0, 'SOLO', '');
        SetItem(1, 'EASY', '');
        SetItem(2, 'NORMAL', '');
        SetItem(3, 'HARD', '');
        SetItem(4, 'BACK', '');
      end;
    msCheat:
      begin
        MenuCount := 2;
        SetItem(0, 'APPLY CODE', '');
        SetItem(1, 'BACK', '');
      end;
    msLevels:
      begin
        MenuCount := LevelCount + 1;
        for I := 1 to LevelCount do
          if I <= Unlocked then
            SetItem(I - 1, IntToStr(I) + '   ' + Levels[I].Name, '')
          else
            SetItem(I - 1, IntToStr(I) + '   LOCKED', '', False);
        SetItem(LevelCount, 'BACK', '');
      end;
    msGraphics:
      begin
        MenuCount := 6;
        SetItem(0, 'Fullscreen', OnOff(Settings.Fullscreen));
        SetItem(1, 'VSync', OnOff(Settings.VSync));
        SetItem(2, 'Particles', ParticleNames[Settings.Particles]);
        SetItem(3, 'Screen shake', OnOff(Settings.ScreenShake));
        if Settings.AnimatedBg then SetItem(4, 'Background', 'ANIMATED')
        else SetItem(4, 'Background', 'STATIC');
        SetItem(5, 'BACK', '');
      end;
    msSound:
      begin
        MenuCount := 3;
        SetSlider(0, 'Music volume', Settings.MusicVolume);
        SetSlider(1, 'Effects volume', Settings.SfxVolume);
        SetItem(2, 'BACK', '');
      end;
    msHighScores:
      begin
        MenuCount := 1;
        SetItem(0, 'BACK', '');
      end;
  end;
end;

function IsCornerItem(I: Integer): Boolean;
begin
  Result := (MenuScreen = msMain) and (I = 7);
end;

function ItemY(I: Integer): Single;
begin
  case MenuScreen of
    msMain:
      if IsCornerItem(I) then Result := ScreenH - 52 else Result := 250 + I * 44;
    msCheat:      Result := 370 + I * 58;
    msNewGame:
      case I of
        0: Result := 190;
        4: Result := 520;
      else
        Result := 300 + (I - 1) * 50;     { the three bot difficulties }
      end;
    msHighScores: Result := 548;
    msLevels:
      if I < LevelCount then Result := 150 + I * 34 else Result := 520;
  else
    Result := 205 + I * 52;
  end;
end;

function ItemCX(I: Integer): Single;
begin
  if IsCornerItem(I) then Result := ScreenW - 92 else Result := MenuCX;
end;

function ItemHalfW(I: Integer): Single;
begin
  if IsCornerItem(I) then Result := 76 else Result := MenuHalfW;
end;

function ItemHalfH(I: Integer): Single;
begin
  if IsCornerItem(I) or (MenuScreen = msLevels) then Result := 16 else Result := 22;
end;

procedure OpenMenu(Screen: TMenuScreen; Sel: Integer);
var
  I: Integer;
begin
  State := gsMenu;
  MenuScreen := Screen;
  BuildMenu;
  if (Sel < 0) or (Sel >= MenuCount) or not MenuEnabled[Sel] then Sel := 0;
  MenuSel := Sel;
  for I := 0 to MaxMenuItems - 1 do
  begin
    MenuHi[I] := 0;
    MenuPunch[I] := 0;
  end;
  MenuOpenT := 0;
  SelBarY := ItemY(Sel);
  SelBarX := ItemCX(Sel);
  SelBarHW := ItemHalfW(Sel);
  SelBarHH := ItemHalfH(Sel);
  PendingItem := -1;
  if Screen = msCheat then
  begin
    CheatMsg := '';
    CheatMsg2 := '';
    CheatShake := 0;
    CheatFlash := 0;
    CheatStartT := -1;
  end;
end;

procedure OpenMenuFromGame;
begin
  if State in [gsLevelIntro, gsServe, gsPlaying, gsPaused, gsLevelClear] then
  begin
    if State = gsPaused then ResumeState := gsPlaying else ResumeState := State;
    LeftDown := False;
    RightDown := False;
    OpenMenu(msMain, 1);
  end
  else
    OpenMenu(msMain, 0);
  SfxMenuBack;
end;

procedure MenuBurst(I: Integer; Count: Integer; R, G, B: Byte);
var
  K: Integer;
  Y: Single;
begin
  Y := ItemY(I);
  for K := 1 to Count do
  begin
    SpawnParticle(ItemCX(I) - ItemHalfW(I) + RandRange(-6, 6), Y + RandRange(-14, 14),
                  RandRange(-260, -60), RandRange(-200, 40), RandRange(0.3, 0.6), RandRange(2, 4), R, G, B);
    SpawnParticle(ItemCX(I) + ItemHalfW(I) + RandRange(-6, 6), Y + RandRange(-14, 14),
                  RandRange(60, 260), RandRange(-200, 40), RandRange(0.3, 0.6), RandRange(2, 4), R, G, B);
  end;
end;

procedure MoveSel(Dir: Integer);
var
  I, Guard: Integer;
begin
  if MenuCount <= 1 then Exit;
  I := MenuSel;
  Guard := 0;
  repeat
    I := (I + Dir + MenuCount) mod MenuCount;
    Inc(Guard);
  until MenuEnabled[I] or (Guard > MenuCount);
  if I <> MenuSel then
  begin
    MenuSel := I;
    MenuPunch[I] := 0.5;
    MenuBurst(I, 3, 150, 170, 255);
    SfxMenuMove;
  end;
end;

procedure AdjustOption(I, Dir: Integer; Wrap: Boolean);
  function Step(V, Lo, Hi: Integer): Integer;
  begin
    Result := V + Dir;
    if Wrap then
    begin
      if Result > Hi then Result := Lo;
      if Result < Lo then Result := Hi;
    end
    else
      Result := EnsureRange(Result, Lo, Hi);
  end;
begin
  case MenuScreen of
    msGraphics:
      case I of
        0: Settings.Fullscreen := not Settings.Fullscreen;
        1: Settings.VSync := not Settings.VSync;
        2: Settings.Particles := Step(Settings.Particles, 0, 2);
        3: Settings.ScreenShake := not Settings.ScreenShake;
        4: Settings.AnimatedBg := not Settings.AnimatedBg;
      else
        Exit;
      end;
    msSound:
      case I of
        0: Settings.MusicVolume := Step(Settings.MusicVolume, 0, 10);
        1: Settings.SfxVolume := Step(Settings.SfxVolume, 0, 10);
      else
        Exit;
      end;
  else
    Exit;
  end;
  ApplySettings;
  SaveSettings;
  BuildMenu;
  MenuPunch[I] := 0.8;
  MenuBurst(I, 4, 255, 215, 90);
  SfxMenuMove;
end;

{ ---------- cheat-code screen ---------- }

procedure StartFromCode;
begin
  CheatStartT := -1;
  NewGame(CheatLevel, CheatMode);
  Score := CheatScore;
  DisplayScore := CheatScore;
  Lives := CheatLives;
  BotScore := CheatBot;
  BotDisplay := CheatBot;
end;

procedure TryCheatCode;
var
  L, S, V, K, M, Bt: Integer;
begin
  if CheatStartT >= 0 then Exit;
  if (Length(CheatInput) <> CodeLen) and (Length(CheatInput) <> LegacyCodeLen) then
  begin
    CheatMsg := 'A code has ' + IntToStr(CodeLen) + ' characters';
    CheatMsg2 := '';
    CheatMsgOK := False;
    CheatShake := 1;
    SfxMenuBack;
    Exit;
  end;

  if ReadCheatCode(CheatInput, L, S, V, M, Bt) and (L >= 2) and (L <= LevelCount) and
     (V >= 1) and (V <= MaxLives) then
  begin
    CheatLevel := L;
    CheatScore := S;
    CheatLives := V;
    CheatMode := M;
    CheatBot := Bt;
    CheatMsg := 'LEVEL ' + IntToStr(L) + '  -  ' + Levels[L].Name;
    if M = 0 then
      CheatMsg2 := 'SOLO     Score ' + IntToStr(S) + '     Lives ' + IntToStr(V)
    else
      CheatMsg2 := ModeNames[M] + '     You ' + IntToStr(S) + '  Bot ' + IntToStr(Bt) +
                   '     Lives ' + IntToStr(V);
    CheatMsgOK := True;
    CheatFlash := 1;
    CheatStartT := 1.3;
    for K := 1 to 40 do
      SpawnParticle(MenuCX + RandRange(-170, 170), 270 + RandRange(-20, 20),
                    RandRange(-200, 200), RandRange(-380, -120), RandRange(0.6, 1.2),
                    RandRange(3, 6), 120, 255, ClampByte(RandRange(140, 220)), psStar, 0.6);
    SfxPowerUp;
    SfxLevelStart;
  end
  else
  begin
    CheatMsg := 'Invalid code - check for typos';
    CheatMsg2 := '';
    CheatMsgOK := False;
    CheatShake := 1;
    SfxCrack;
    SfxMenuBack;
  end;
end;

function IsBackItem(I: Integer): Boolean;
begin
  Result := (MenuScreen <> msMain) and (MenuLabel[I] = 'BACK');
end;

procedure ActivateItem(I: Integer);
begin
  if (I < 0) or (I >= MenuCount) or (PendingItem >= 0) then Exit;
  if not MenuEnabled[I] then
  begin
    SfxMenuBack;
    Exit;
  end;
  if CheatStartT >= 0 then Exit;

  if (MenuScreen = msCheat) and (I = 0) then
  begin
    MenuPunch[I] := 1.0;
    SelFlash := 1.0;
    TryCheatCode;
    Exit;
  end;

  if (MenuValue[I] <> '') or MenuIsSlider[I] then
  begin
    AdjustOption(I, 1, True);
    Exit;
  end;

  MenuPunch[I] := 1.0;
  SelFlash := 1.0;
  MenuBurst(I, 10, 255, 225, 120);
  if IsBackItem(I) then SfxMenuBack else SfxMenuSelect;
  PendingItem := I;
  PendingT := 0.28;
end;

procedure MenuBack;
begin
  case MenuScreen of
    msLevels:     OpenMenu(msMain, 2);
    msHighScores: OpenMenu(msMain, 3);
    msGraphics:   OpenMenu(msMain, 4);
    msSound:      OpenMenu(msMain, 5);
    msCheat:      OpenMenu(msMain, 7);
    msNewGame:
      if NewGameFrom = msLevels then OpenMenu(msLevels, StartLevelChoice - 1)
      else OpenMenu(msMain, 0);
    msMain:
      if GameInProgress then State := ResumeState
      else Exit;
  end;
  SfxMenuBack;
end;

procedure DoMenuAction(I: Integer);
begin
  case MenuScreen of
    msMain:
      case I of
        0: begin
             StartLevelChoice := 1;
             NewGameFrom := msMain;
             OpenMenu(msNewGame, LastModeSel);
           end;
        1: State := ResumeState;
        2: OpenMenu(msLevels, Unlocked - 1);
        3: OpenMenu(msHighScores, 0);
        4: OpenMenu(msGraphics, 0);
        5: OpenMenu(msSound, 0);
        6: Running := False;
        7: OpenMenu(msCheat, 0);
      end;
    msCheat: OpenMenu(msMain, 7);    { BACK }
    msLevels:
      if I < LevelCount then
      begin
        StartLevelChoice := I + 1;
        NewGameFrom := msLevels;
        OpenMenu(msNewGame, LastModeSel);
      end
      else OpenMenu(msMain, 2);
    msNewGame:
      if I <= 3 then
      begin
        LastModeSel := I;
        NewGame(StartLevelChoice, I);    { 0 = solo, 1..3 = bot difficulty }
      end
      else if NewGameFrom = msLevels then OpenMenu(msLevels, StartLevelChoice - 1)
      else OpenMenu(msMain, 0);
    msHighScores: OpenMenu(msMain, 3);
    msGraphics:   OpenMenu(msMain, 4);
    msSound:      OpenMenu(msMain, 5);
  end;
end;

procedure CheatKey(Key: TSDL_Keycode; Mods: Integer);
var
  Ch: Char;
  Clip: PAnsiChar;
begin
  if CheatStartT >= 0 then Exit;     { already starting }

  { Ctrl+V pastes }
  if ((Mods and SDL_KMOD_CTRL) <> 0) and (Key = SDLK_V) then
  begin
    Clip := SDL_GetClipboardText;
    if Clip <> nil then
    begin
      CheatInput := Copy(NormalizeCode(string(Clip)), 1, CodeLen);
      SDL_free(Clip);
      CheatTypedT := 1;
      CheatMsg := '';
      SfxMenuMove;
    end;
    Exit;
  end;

  case Key of
    SDLK_UP:    MoveSel(-1);
    SDLK_DOWN:  MoveSel(1);
    SDLK_ESCAPE: MenuBack;
    SDLK_BACKSPACE, SDLK_DELETE:
      if CheatInput <> '' then
      begin
        Delete(CheatInput, Length(CheatInput), 1);
        CheatMsg := '';
        SfxMenuMove;
      end;
    SDLK_TAB:     { reuse the last code you earned }
      if LastCode <> '' then
      begin
        CheatInput := Copy(NormalizeCode(LastCode), 1, CodeLen);
        CheatTypedT := 1;
        CheatMsg := '';
        SfxMenuMove;
      end;
    SDLK_RETURN, SDLK_KP_ENTER:
      if MenuSel = 1 then ActivateItem(1) else TryCheatCode;
  else
    begin
      { letters arrive as lowercase ASCII keycodes, digits as '0'..'9' }
      if (Key >= Ord('a')) and (Key <= Ord('z')) then Ch := Chr(Key - 32)
      else if (Key >= Ord('0')) and (Key <= Ord('9')) then Ch := Chr(Key)
      else Exit;

      if Pos(Ch, CodeChars) = 0 then
      begin
        CheatMsg := 'Codes never use I, O, 0 or 1';
        CheatMsg2 := '';
        CheatMsgOK := False;
        CheatShake := 0.5;
        SfxMenuBack;
      end
      else if Length(CheatInput) < CodeLen then
      begin
        CheatInput := CheatInput + Ch;
        CheatTypedT := 1;
        CheatMsg := '';
        SfxMenuMove;
      end;
    end;
  end;
end;

procedure UpdateMenu(DT: Single);
var
  I: Integer;
begin
  MenuOpenT := MenuOpenT + DT;
  SelBarY := SelBarY + (ItemY(MenuSel) - SelBarY) * MinF(1, DT * 14);
  SelBarX := SelBarX + (ItemCX(MenuSel) - SelBarX) * MinF(1, DT * 14);
  SelBarHW := SelBarHW + (ItemHalfW(MenuSel) - SelBarHW) * MinF(1, DT * 14);
  SelBarHH := SelBarHH + (ItemHalfH(MenuSel) - SelBarHH) * MinF(1, DT * 14);
  CheatShake := MaxF(0, CheatShake - DT * 2.5);
  CheatFlash := MaxF(0, CheatFlash - DT * 1.5);
  CheatTypedT := MaxF(0, CheatTypedT - DT * 6);
  SelFlash := MaxF(0, SelFlash - DT * 3.5);
  for I := 0 to MenuCount - 1 do
  begin
    if I = MenuSel then MenuHi[I] := MenuHi[I] + (1 - MenuHi[I]) * MinF(1, DT * 12)
    else MenuHi[I] := MenuHi[I] + (0 - MenuHi[I]) * MinF(1, DT * 10);
    MenuPunch[I] := MaxF(0, MenuPunch[I] - DT * 3.5);
  end;

  if PendingItem >= 0 then
  begin
    PendingT := PendingT - DT;
    if PendingT <= 0 then
    begin
      I := PendingItem;
      PendingItem := -1;
      DoMenuAction(I);
    end;
  end;

  if CheatStartT >= 0 then
  begin
    CheatStartT := CheatStartT - DT;
    if CheatStartT < 0 then StartFromCode;
  end;
end;

function MenuItemAt(X, Y: Single): Integer;
var
  I: Integer;
begin
  for I := 0 to MenuCount - 1 do
    if (Abs(X - ItemCX(I)) < ItemHalfW(I)) and (Abs(Y - ItemY(I)) < ItemHalfH(I)) then Exit(I);
  Result := -1;
end;

{ ================= update ================= }

procedure Fireworks(DT: Single; Rate: Single);
var
  I: Integer;
begin
  if Random < DT * Rate then
  begin
    I := Random(6);
    Sparks(RandRange(100, ScreenW - 100), RandRange(80, 260), 24,
           TitleColors[I, 0], TitleColors[I, 1], TitleColors[I, 2], 300);
  end;
end;

procedure Update(DT: Single);
var
  I: Integer;
begin
  Clock := Clock + DT;
  BgUpdate(DT);
  SetMusicDucked(State in [gsPaused, gsGameOver, gsWon]);

  { cartoon eyes follow the first ball }
  for I := 0 to MaxBalls - 1 do
    if Balls[I].Active then
    begin
      LookX := Balls[I].X;
      LookY := Balls[I].Y;
      Break;
    end;

  case State of
    gsMenu:
      begin
        UpdateMenu(DT);
        UpdateEffects(DT);
      end;

    gsPaused: ;

    gsLevelIntro:
      begin
        LevelT := LevelT + DT;
        UpdateEffects(DT);
        UpdateScoreDisplay(DT);
        UpdateBricks(DT);
        UpdateGame(DT);
        if LevelT >= IntroLen then FinishIntro;
      end;

    gsLevelClear:
      begin
        LevelT := LevelT + DT;
        UpdateEffects(DT);
        UpdateScoreDisplay(DT);
        UpdateBricks(DT);
        Fireworks(DT, 4);
        UpdateBot(DT);
        CodeCopiedT := MaxF(0, CodeCopiedT - DT);
        { waits for Space / click so there is time to note the code }
      end;

    gsGameOver, gsWon:
      begin
        EndT := EndT + DT;
        UpdateEffects(DT);
        UpdateScoreDisplay(DT);
        UpdateBricks(DT);
        UpdateBot(DT);
        if (NewRank >= 0) or (State = gsWon) then Fireworks(DT, 3);
      end;
  else { gsServe, gsPlaying }
    UpdateEffects(DT);
    UpdateScoreDisplay(DT);
    UpdateBricks(DT);
    UpdateGame(DT);
  end;
end;

{ ================= input ================= }

procedure ToggleFullscreen;
begin
  Settings.Fullscreen := not Settings.Fullscreen;
  ApplySettings;
  SaveSettings;
  if State = gsMenu then BuildMenu;
end;

procedure TogglePause;
begin
  if State = gsPlaying then State := gsPaused
  else if State = gsPaused then State := gsPlaying
  else Exit;
  SfxPause;
end;

procedure ContinueAction;     { Space / Enter / click during play }
begin
  case State of
    gsLevelIntro: FinishIntro;
    gsServe: LaunchBall;
    gsLevelClear: if LevelT > 0.8 then NextLevel;
    gsGameOver, gsWon: if EndT > 0.6 then NewGame(1, Mode);
  end;
end;

procedure MenuKey(Key: TSDL_Keycode);
begin
  if PendingItem >= 0 then Exit;
  case Key of
    SDLK_UP, SDLK_W:     MoveSel(-1);
    SDLK_DOWN, SDLK_S:   MoveSel(1);
    SDLK_LEFT, SDLK_A:   AdjustOption(MenuSel, -1, False);
    SDLK_RIGHT, SDLK_D:  AdjustOption(MenuSel, 1, False);
    SDLK_RETURN, SDLK_SPACE, SDLK_KP_ENTER: ActivateItem(MenuSel);
    SDLK_ESCAPE, SDLK_BACKSPACE: MenuBack;
  end;
end;

procedure GameKey(Key: TSDL_Keycode);
begin
  case Key of
    SDLK_ESCAPE: OpenMenuFromGame;
    SDLK_SPACE, SDLK_RETURN: ContinueAction;
    SDLK_P: TogglePause;
    SDLK_M: MusicOn := not MusicOn;
    SDLK_N: SfxOn := not SfxOn;
    SDLK_C:
      if (State = gsLevelClear) and (LevelCode <> '') then
      begin
        SDL_SetClipboardText(PAnsiChar(AnsiString(LevelCode)));
        CodeCopiedT := 1.5;
        SfxMenuSelect;
      end;
  end;
end;

procedure HandleEvents;
var
  Ev: TSDL_Event;
  I: Integer;
begin
  while SDL_PollEvent(@Ev) do
  begin
    SDL_ConvertEventToRenderCoordinates(Renderer, @Ev);
    case Ev._type of
      SDL_EVENT_QUIT:
        Running := False;

      SDL_EVENT_KEY_DOWN:
        begin
          case Ev.key.key of
            SDLK_LEFT, SDLK_A:  LeftDown := True;
            SDLK_RIGHT, SDLK_D: RightDown := True;
          end;
          if Ev.key.key = SDLK_F11 then
          begin
            if not Ev.key._repeat then ToggleFullscreen;
          end
          else if (State = gsMenu) and (MenuScreen = msCheat) then
            CheatKey(Ev.key.key, Ev.key.mod_)
          else if State = gsMenu then
            MenuKey(Ev.key.key)
          else if not Ev.key._repeat then
            GameKey(Ev.key.key);
        end;

      SDL_EVENT_KEY_UP:
        case Ev.key.key of
          SDLK_LEFT, SDLK_A:  LeftDown := False;
          SDLK_RIGHT, SDLK_D: RightDown := False;
        end;

      SDL_EVENT_MOUSE_MOTION:
        if State = gsMenu then
        begin
          I := MenuItemAt(Ev.motion.x, Ev.motion.y);
          if (I >= 0) and (I <> MenuSel) and MenuEnabled[I] and (PendingItem < 0) then
          begin
            MenuSel := I;
            MenuPunch[I] := 0.5;
            SfxMenuMove;
          end;
        end
        else if State in [gsLevelIntro, gsServe, gsPlaying] then
          PaddleX := EnsureRange(Ev.motion.x - PaddleW / 2, 0.0, ScreenW - PaddleW);

      SDL_EVENT_MOUSE_BUTTON_DOWN:
        if State = gsMenu then
        begin
          I := MenuItemAt(Ev.button.x, Ev.button.y);
          if (I >= 0) and (PendingItem < 0) then
          begin
            if MenuEnabled[I] then MenuSel := I;
            ActivateItem(I);
          end;
        end
        else
          ContinueAction;

      SDL_EVENT_WINDOW_FOCUS_LOST:
        if State = gsPlaying then TogglePause;
    end;
  end;
end;

{ ================= drawing ================= }

procedure DrawParticles;
var
  I: Integer;
  K, S: Single;
  C: TCol;
  Pts: array[0..3] of TSDL_FPoint;
begin
  for I := 0 to MaxParticles - 1 do
    if Particles[I].Life > 0 then
    begin
      K := Particles[I].Life / Particles[I].MaxLife;
      S := Particles[I].Size * (0.4 + 0.6 * K);
      C := Col(Particles[I].R, Particles[I].G, Particles[I].B, ClampByte(K * 255));
      case Particles[I].Shape of
        psCircle: Ellipse(Particles[I].X, Particles[I].Y, S / 2, S / 2, C, 8);
        psStar:   Star(Particles[I].X, Particles[I].Y, S, C);
        psDiamond:
          begin
            Pts[0] := FPt(Particles[I].X, Particles[I].Y - S * 0.7);
            Pts[1] := FPt(Particles[I].X + S * 0.4, Particles[I].Y);
            Pts[2] := FPt(Particles[I].X, Particles[I].Y + S * 0.7);
            Pts[3] := FPt(Particles[I].X - S * 0.4, Particles[I].Y);
            Poly(Pts, C);
          end;
      else
        Rect(Particles[I].X - S / 2, Particles[I].Y - S / 2, S, S, C);
      end;
    end;
end;

procedure DrawPopups;
var
  I: Integer;
  Age, Scale, Alpha: Single;
begin
  for I := 0 to MaxPopups - 1 do
    if Popups[I].T > 0 then
    begin
      Age := Popups[I].MaxT - Popups[I].T;
      Scale := 1 + 0.6 * MaxF(0, 1 - Age / 0.15);
      Alpha := Clamp01(Popups[I].T / 0.35);
      DrawStr(Popups[I].Size, Popups[I].Text, Popups[I].X + CamX, Popups[I].Y + CamY,
              alCenter, Popups[I].R, Popups[I].G, Popups[I].B, ClampByte(Alpha * 255), Scale);
    end;
end;

procedure DrawShocksAndBolts;
var
  I: Integer;
  K: Single;
begin
  for I := 0 to MaxShocks - 1 do
    if Shocks[I].T > 0 then
    begin
      K := Shocks[I].T / Shocks[I].MaxT;
      Ring(Shocks[I].X, Shocks[I].Y, Shocks[I].R, Shocks[I].R * Shocks[I].Flat, 2 + 8 * K,
           ColAlpha(Shocks[I].C, K), 0, 2 * Pi, 0, 36);
    end;
  for I := 0 to MaxBolts - 1 do
    if Bolts[I].T > 0 then
      DrawBolt(Bolts[I].X1, Bolts[I].Y1, Bolts[I].X2, Bolts[I].Y2, Bolts[I].Seed,
               Col(140, 230, 255, ClampByte(Bolts[I].T / 0.35 * 255)));
end;

procedure DrawDrops;
var
  I: Integer;
  X, Y, Bob, Shine: Single;
  K: TPowerKind;
  C: TCol;
begin
  for I := 0 to MaxDrops - 1 do
    if Drops[I].Active then
    begin
      K := Drops[I].Kind;
      C := Col(PowerColor[K, 0], PowerColor[K, 1], PowerColor[K, 2]);
      Bob := Sin(Drops[I].T * 8) * 1.5;
      X := Drops[I].X - DropW / 2;
      Y := Drops[I].Y - DropH / 2 + Bob;
      Glow(Drops[I].X, Y + DropH / 2, DropW * 0.8, DropH * 1.4, ColAlpha(C, 0.35));
      RoundRectGrad(X, Y, DropW, DropH, DropH / 2, ColScale(C, 1.3), ColScale(C, 0.75));
      Shine := Frac(Drops[I].T * 0.8) * (DropW + 20) - 10;
      if (Shine > 4) and (Shine < DropW - 10) then
        Rect(X + Shine, Y + 2, 5, DropH - 4, Col(255, 255, 255, 110));
      DrawStr(fsTiny, PowerLetter[K], Drops[I].X + CamX, Y + DropH / 2 + CamY,
              alCenter, 255, 255, 255, 255, 1.0, 0, True);
    end;
end;

procedure DrawBotPaddle;
var
  Glw, LX, LY, DX, DY, L, EX: Single;
  I: Integer;
begin
  Glw := BotGlow;
  Glow(BotX, BotY + PaddleH / 2, BotW * 0.7 + 10 * Glw, 26 + 10 * Glw,
       Col(255, 140, 60, ClampByte(60 + Glw * 120)));
  RoundRectGrad(BotX - BotW / 2, BotY, BotW, PaddleH, 6,
                Col(255, ClampByte(200 + 40 * Glw), 140), Col(220, 90, 40));
  { eyes follow the nearest ball }
  LX := BotX; LY := ScreenH;
  for I := 0 to MaxBalls - 1 do
    if Balls[I].Active then
    begin
      LX := Balls[I].X + BallSize / 2;
      LY := Balls[I].Y + BallSize / 2;
      Break;
    end;
  DX := LX - BotX; DY := LY - (BotY + PaddleH / 2);
  L := MaxF(1, Sqrt(DX * DX + DY * DY));
  for I := 0 to 1 do
  begin
    EX := BotX + (I * 2 - 1) * 12;
    Ellipse(EX, BotY + PaddleH / 2, 5, 5, Col(255, 255, 255), 10);
    Ellipse(EX + DX / L * 2.2, BotY + PaddleH / 2 + DY / L * 2.2, 2.4, 2.4, Col(40, 20, 10), 8);
  end;
  DrawStr(fsTiny, 'BOT  ' + ModeShort[Mode], BotX + CamX, BotY + PaddleH + 12 + CamY, alCenter,
          255, 170, 100, 170, 0.9, 0, False);
end;

procedure DrawWorld;
var
  I, J: Integer;
  Rc: TSDL_FRect;
  K, Glw: Single;
  BallC: TCol;
begin
  for I := 0 to BrickCount - 1 do
    DrawBrick(Bricks[I], Clock);

  { ghosts of broken bricks }
  for I := 0 to MaxFlashes - 1 do
    if Flashes[I].T > 0 then
    begin
      K := Flashes[I].T / 0.3;
      Glw := (1 - K) * 10;
      Rc := Flashes[I].Rect;
      FillRect(MakeRect(Rc.x - Glw, Rc.y - Glw / 2, Rc.w + Glw * 2, Rc.h + Glw),
               Flashes[I].R, Flashes[I].G, Flashes[I].B, ClampByte(K * 140));
      FillRect(Rc, 255, 255, 255, ClampByte(K * K * 200));
    end;

  DrawShocksAndBolts;
  DrawDrops;

  { paddle }
  Glw := PaddleGlow;
  if Glw > 0 then
    Glow(PaddleX + PaddleW / 2, PaddleY + PaddleH / 2, PaddleW * 0.7 + 10 * Glw, 26,
         Col(140, 170, 255, ClampByte(Glw * 140)));
  if WideTimer > 0 then
    RoundRect(PaddleX - 3, PaddleY - 3, PaddleW + 6, PaddleH + 6, 8,
              Col(PowerColor[pkWide, 0], PowerColor[pkWide, 1], PowerColor[pkWide, 2],
                  ClampByte(90 + 60 * Sin(Clock * 8))));
  RoundRectGrad(PaddleX, PaddleY, PaddleW, PaddleH, 6,
                Col(255, 255, 255), Col(ClampByte(170 + 60 * Glw), ClampByte(180 + 50 * Glw), 215));

  { the bot's paddle: orange, glows when it hits, eyes watch the ball }
  if Versus then DrawBotPaddle;

  { balls: blue = yours, orange = the bot's, green tint while slowed }
  for J := 0 to MaxBalls - 1 do
    if Balls[J].Active then
    begin
      if Versus and (Balls[J].Owner = 1) then BallC := Col(255, 160, 70)
      else BallC := Col(180, 210, 255);
      if SlowTimer > 0 then BallC := ColMix(BallC, Col(170, 255, 200), 0.6);
      for I := Balls[J].TrailCount - 1 downto 1 do
      begin
        K := 1 - I / TrailLen;
        Ellipse(Balls[J].TrailX[I] + BallSize / 2, Balls[J].TrailY[I] + BallSize / 2,
                BallSize / 2 * K, BallSize / 2 * K, ColAlpha(BallC, K * 0.5), 10);
      end;
      Glow(Balls[J].X + BallSize / 2, Balls[J].Y + BallSize / 2, 14, 14, ColAlpha(BallC, 0.5));
      EllipseGrad(Balls[J].X + BallSize / 2 - 1, Balls[J].Y + BallSize / 2 - 1, BallSize / 2 + 1,
                  BallSize / 2 + 1, Col(255, 255, 255), ColScale(BallC, 0.95), 14);
    end;

  if State <> gsMenu then
  begin
    DrawParticles;
    DrawPopups;
  end;
end;

procedure DrawTimerBar(var X: Single; Kind: TPowerKind; Left, Total: Single);
const
  BarW = 70;
begin
  X := X - BarW;
  FillRect(MakeRect(X, ScreenH - 18, BarW, 8), 255, 255, 255, 30);
  FillRect(MakeRect(X, ScreenH - 18, BarW * Clamp01(Left / Total), 8),
           PowerColor[Kind, 0], PowerColor[Kind, 1], PowerColor[Kind, 2]);
  DrawStr(fsTiny, PowerLetter[Kind], X - 8, ScreenH - 14, alRight,
          PowerColor[Kind, 0], PowerColor[Kind, 1], PowerColor[Kind, 2]);
  X := X - 30;
end;

procedure DrawHUD;
var
  K, Scale, X: Single;
  R, G, B: Byte;
  I, Best: Integer;
  Hint: string;
begin
  K := ScorePulse;
  Scale := 1 + 0.45 * K * K;
  R := LerpB(240, 255, K); G := LerpB(240, 210, K); B := LerpB(245, 80, K);
  DrawStr(fsTiny, 'SCORE', 16, 14, alLeft, 150, 160, 200);
  DrawStr(fsMedium, IntToStr(Round(DisplayScore)), 16, 38, alLeft, R, G, B, 255, Scale);

  DrawStr(fsTiny, 'LEVEL ' + IntToStr(Level) + '  -  ' + Levels[Level].Name,
          ScreenW / 2, 14, alCenter, 150, 160, 200);
  Best := Max(BestAtStart, Integer(Round(DisplayScore)));
  if Versus then
  begin
    K := BotPulse;
    DrawStr(fsSmall, 'BOT ' + IntToStr(Round(BotDisplay)), ScreenW / 2 - 6, 36, alRight,
            255, LerpB(150, 220, K), LerpB(60, 120, K), 255, 1 + 0.35 * K * K);
    DrawStr(fsTiny, 'ROUNDS  ' + IntToStr(RoundYou) + ' : ' + IntToStr(RoundBot), ScreenW / 2 + 10, 36,
            alLeft, 200, 205, 230);
  end
  else if BeatBest then
    DrawStr(fsSmall, 'BEST ' + IntToStr(Best), ScreenW / 2, 36, alCenter, 255, 215, 90, 255,
            1 + 0.08 * Sin(Clock * 6))
  else
    DrawStr(fsSmall, 'BEST ' + IntToStr(Best), ScreenW / 2, 36, alCenter, 220, 225, 240);

  DrawStr(fsTiny, 'LIVES', ScreenW - 16, 14, alRight, 150, 160, 200);
  for I := 0 to Lives - 1 do
    RoundRect(ScreenW - 16 - (I + 1) * 26 + 4, 34, 22, 7, 3, Col(220, 225, 240));

  X := ScreenW - 16;
  if WideTimer > 0 then DrawTimerBar(X, pkWide, WideTimer, WideTime);
  if SlowTimer > 0 then DrawTimerBar(X, pkSlow, SlowTimer, SlowTime);

  if State <> gsMenu then
  begin
    Hint := 'ESC menu   P pause   M music   N sound';
    if not MusicOn then Hint := Hint + '   [music off]';
    if not SfxOn then Hint := Hint + '   [sound off]';
    DrawStr(fsTiny, Hint, 16, ScreenH - 12, alLeft, 140, 140, 175, 200, 0.85, 0, False);
  end;
end;

{ the code panel on the level-clear screen: characters "decode" one by one }
procedure DrawCodePanel(Appear: Single);
var
  I, Reveal: Integer;
  Shown: string;
  A: Byte;
  Pulse: Single;
begin
  if Appear <= 0 then Exit;
  A := ClampByte(Appear * 255);
  RoundRect(ScreenW / 2 - 250, 288, 500, 112, 12, Col(255, 215, 90, ClampByte(Appear * 200)));
  RoundRect(ScreenW / 2 - 248, 290, 496, 108, 11, Col(14, 14, 32, ClampByte(Appear * 245)));
  DrawStr(fsTiny, 'CHEAT CODE FOR LEVEL ' + IntToStr(Level + 1) + '  (keeps scores, lives and mode)',
          ScreenW / 2, 306, alCenter, 160, 220, 255, A);

  Reveal := Trunc((LevelT - 0.8) * 14);
  Shown := '';
  for I := 1 to Length(LevelCode) do
    if (LevelCode[I] = '-') or (I <= Reveal) then Shown := Shown + LevelCode[I]
    else Shown := Shown + CodeChars[Random(Length(CodeChars)) + 1];

  Pulse := 1 + 0.04 * Sin(Clock * 5);
  if Reveal >= Length(LevelCode) then
    DrawStr(fsLarge, Shown, ScreenW / 2, 344, alCenter, 255, 215, 90, A, Pulse)
  else
    DrawStr(fsLarge, Shown, ScreenW / 2, 344, alCenter, 160, 255, 200, A);

  if CodeCopiedT > 0 then
    DrawStr(fsTiny, 'Copied to clipboard!', ScreenW / 2, 382, alCenter, 120, 255, 160, A)
  else
    DrawStr(fsTiny, 'press C to copy  -  enter it later on the Cheat-code screen',
            ScreenW / 2, 382, alCenter, 150, 155, 190, A);
end;

procedure DrawOverlays;
var
  K, Pulse, A: Single;
  R, G, B: Byte;
  Title: string;
begin
  case State of
    gsLevelIntro:
      begin
        K := EaseOutBack(LevelT / 0.5);
        A := Clamp01((IntroLen - LevelT) / 0.4);
        FillRect(MakeRect(0, 368, ScreenW, 140), 5, 5, 15, ClampByte(A * 150));
        if Versus then
          DrawStr(fsTiny, ModeNames[Mode], ScreenW / 2, 378, alCenter, 255, 170, 100, ClampByte(A * 255));
        DrawStr(fsLarge, 'LEVEL ' + IntToStr(Level), ScreenW / 2, 404, alCenter,
                255, 255, 255, ClampByte(A * 255), MaxF(0.01, K));
        DrawStr(fsMedium, Levels[Level].Name, ScreenW / 2, 448, alCenter,
                255, 215, 90, ClampByte(A * Clamp01((LevelT - 0.2) * 3) * 255));
        if IntroHint <> '' then
          DrawStr(fsSmall, IntroHint, ScreenW / 2, 488, alCenter,
                  160, 220, 255, ClampByte(A * Clamp01((LevelT - 0.5) * 3) * 255));
      end;

    gsServe:
      DrawStr(fsSmall, 'SPACE or CLICK to launch', ScreenW / 2, 518, alCenter,
              240, 240, 245, ClampByte(170 + 85 * Sin(Clock * 4)));

    gsPaused:
      begin
        FillRect(MakeRect(0, 0, ScreenW, ScreenH), 0, 0, 0, 150);
        DrawStr(fsLarge, 'PAUSED', ScreenW / 2, ScreenH / 2 - 20, alCenter, 255, 255, 255, 255,
                1 + 0.04 * Sin(Clock * 3));
        DrawStr(fsSmall, 'P to resume   -   ESC for menu', ScreenW / 2, ScreenH / 2 + 30,
                alCenter, 200, 205, 230);
      end;

    gsLevelClear:
      begin
        FillRect(MakeRect(0, 0, ScreenW, ScreenH), 0, 0, 0, ClampByte(MinF(1, LevelT * 3) * 140));
        Rainbow(Clock * 3, R, G, B);
        DrawStr(fsHuge, 'LEVEL CLEAR!', ScreenW / 2, 150, alCenter, R, G, B, 255,
                MaxF(0.01, EaseOutBack(LevelT / 0.5)));
        A := Clamp01((LevelT - 0.4) * 4);
        if Versus then
        begin
          if RoundMsg = 'YOU WIN THE ROUND!' then
            DrawStr(fsMedium, RoundMsg + '   +' + IntToStr(ClearBonus), ScreenW / 2, 212,
                    alCenter, 255, 215, 90, ClampByte(A * 255))
          else
            DrawStr(fsMedium, RoundMsg + '   +' + IntToStr(ClearBonus), ScreenW / 2, 212,
                    alCenter, 255, 150, 60, ClampByte(A * 255));
          DrawStr(fsSmall, 'You ' + IntToStr(Round(DisplayScore)) + '     Bot ' + IntToStr(Round(BotDisplay)) +
                  '     Rounds ' + IntToStr(RoundYou) + ' : ' + IntToStr(RoundBot),
                  ScreenW / 2, 250, alCenter, 240, 240, 245, ClampByte(A * 255));
        end
        else
        begin
          DrawStr(fsMedium, 'Bonus  +' + IntToStr(ClearBonus), ScreenW / 2, 215,
                  alCenter, 255, 215, 90, ClampByte(A * 255));
          DrawStr(fsMedium, 'Score  ' + IntToStr(Round(DisplayScore)), ScreenW / 2, 252,
                  alCenter, 240, 240, 245, ClampByte(A * 255));
        end;

        if LevelCode <> '' then
          DrawCodePanel(Clamp01((LevelT - 0.6) * 3));

        if Level < LevelCount then
          DrawStr(fsSmall, 'Next:  ' + Levels[Level + 1].Name, ScreenW / 2, 432,
                  alCenter, 200, 205, 230, ClampByte(Clamp01((LevelT - 0.9) * 4) * 255));
        if LevelT > 0.8 then
          DrawStr(fsSmall, 'SPACE or CLICK to continue', ScreenW / 2, 478, alCenter,
                  240, 240, 245, ClampByte(150 + 100 * Sin(Clock * 4)));
      end;

    gsGameOver, gsWon:
      begin
        FillRect(MakeRect(0, 0, ScreenW, ScreenH), 0, 0, 0, ClampByte(MinF(1, EndT * 3) * 160));
        K := EaseOutBack(EndT / 0.6);
        if State = gsWon then Title := 'CHAMPION!' else Title := 'GAME OVER';
        if Versus and (State = gsWon) then
        begin
          if Score > BotScore then Title := 'VICTORY!' else Title := 'DEFEAT';
        end;
        if (State = gsWon) and ((not Versus) or (Score > BotScore)) then Rainbow(Clock * 3, R, G, B)
        else begin R := 255; G := 110; B := 110; end;
        DrawStr(fsHuge, Title, ScreenW / 2, ScreenH / 2 - 80, alCenter, R, G, B, 255,
                MaxF(0.01, K), (1 - Clamp01(EndT / 0.6)) * -8);

        if EndT > 0.4 then
        begin
          if State = gsWon then
            DrawStr(fsSmall, 'All ' + IntToStr(LevelCount) + ' levels cleared', ScreenW / 2,
                    ScreenH / 2 - 25, alCenter, 200, 205, 230, ClampByte(Clamp01((EndT - 0.4) * 4) * 255))
          else
            DrawStr(fsSmall, 'Reached level ' + IntToStr(Level), ScreenW / 2,
                    ScreenH / 2 - 25, alCenter, 200, 205, 230, ClampByte(Clamp01((EndT - 0.4) * 4) * 255));
          if Versus then
          begin
            DrawStr(fsSmall, 'You ' + IntToStr(Round(DisplayScore)) + '     Bot ' + IntToStr(Round(BotDisplay)) +
                    '     Rounds ' + IntToStr(RoundYou) + ' : ' + IntToStr(RoundBot),
                    ScreenW / 2, ScreenH / 2 + 8, alCenter, 240, 240, 245,
                    ClampByte(Clamp01((EndT - 0.4) * 4) * 255));
            if Score > BotScore then
              DrawStr(fsMedium, 'YOU WIN THE MATCH!', ScreenW / 2, ScreenH / 2 + 34, alCenter,
                      255, 215, 90, ClampByte(Clamp01((EndT - 0.5) * 4) * 255))
            else if Score < BotScore then
              DrawStr(fsMedium, 'THE BOT WINS THE MATCH', ScreenW / 2, ScreenH / 2 + 34, alCenter,
                      255, 150, 60, ClampByte(Clamp01((EndT - 0.5) * 4) * 255))
            else
              DrawStr(fsMedium, 'IT''S A DRAW', ScreenW / 2, ScreenH / 2 + 34, alCenter,
                      220, 225, 240, ClampByte(Clamp01((EndT - 0.5) * 4) * 255));
          end
          else
            DrawStr(fsMedium, 'Score  ' + IntToStr(Round(DisplayScore)), ScreenW / 2, ScreenH / 2 + 10,
                    alCenter, 240, 240, 245, ClampByte(Clamp01((EndT - 0.4) * 4) * 255));
        end;

        if (NewRank >= 0) and (EndT > 0.7) then
        begin
          Pulse := 1 + 0.08 * Sin(Clock * 7);
          Rainbow(Clock * 4, R, G, B);
          DrawStr(fsMedium, 'NEW HIGH SCORE!  #' + IntToStr(NewRank + 1), ScreenW / 2,
                  ScreenH / 2 + 72, alCenter, R, G, B, 255,
                  Pulse * EaseOutBack((EndT - 0.7) / 0.4));
        end;

        if EndT > 1.0 then
          DrawStr(fsSmall, 'SPACE play again   -   ESC menu', ScreenW / 2, ScreenH / 2 + 118,
                  alCenter, 200, 205, 230, ClampByte(150 + 100 * Sin(Clock * 4)));
      end;
  end;
end;

procedure DrawTitle;
const
  TitleText = 'BREAKOUT';
var
  I: Integer;
  X, W, Total, Y, Sc: Single;
  Ch: string;
  Intro: Single;
begin
  Intro := EaseOutBack(MenuOpenT / 0.6);
  Total := 0;
  for I := 1 to Length(TitleText) do
    Total := Total + TextWidth(fsHuge, TitleText[I]) + 4;
  X := ScreenW / 2 - Total / 2;
  for I := 1 to Length(TitleText) do
  begin
    Ch := TitleText[I];
    W := TextWidth(fsHuge, Ch);
    Y := 110 + Sin(Clock * 3 + I * 0.6) * 7;
    Sc := MaxF(0.01, Intro) * (1 + 0.06 * Sin(Clock * 4 + I));
    DrawStr(fsHuge, Ch, X + W / 2, Y, alCenter,
            TitleColors[(I - 1) mod 6, 0], TitleColors[(I - 1) mod 6, 1],
            TitleColors[(I - 1) mod 6, 2], 255, Sc, Sin(Clock * 2 + I) * 4);
    X := X + W + 4;
  end;
  DrawStr(fsTiny, 'S D L 3   +   L A Z A R U S', ScreenW / 2, 162, alCenter, 150, 160, 210);
  if BestScore > 0 then
    DrawStr(fsSmall, 'BEST  ' + IntToStr(BestScore), ScreenW / 2, 195, alCenter, 255, 215, 90, 255,
            1 + 0.05 * Sin(Clock * 3));
end;

procedure DrawHighScoreTable;
var
  I: Integer;
  Y, Appear: Single;
  R, G, B, A: Byte;
  Txt: string;
begin
  for I := 0 to MaxHighScores - 1 do
  begin
    Y := 160 + I * 34;
    Appear := EaseOutCubic((MenuOpenT - I * 0.05) / 0.3);
    A := ClampByte(Appear * 255);
    if I = NewRank then
      Rainbow(Clock * 4, R, G, B)
    else if I = 0 then
    begin R := 255; G := 215; B := 90; end
    else
    begin R := 220; G := 225; B := 240; end;

    if I mod 2 = 0 then
      FillRect(MakeRect(MenuCX - 260 + (1 - Appear) * 80, Y - 15, 520, 30), 255, 255, 255,
               ClampByte(Appear * 14));

    if HighScores[I].Score > 0 then Txt := IntToStr(HighScores[I].Score) else Txt := '---';
    DrawStr(fsSmall, IntToStr(I + 1) + '.', MenuCX - 220 + (1 - Appear) * 80, Y, alLeft, R, G, B, A);
    DrawStr(fsSmall, Txt, MenuCX + 10 + (1 - Appear) * 80, Y, alRight, R, G, B, A);
    if HighScores[I].Score > 0 then
      DrawStr(fsTiny, ModeShort[EnsureRange(HighScores[I].Mode, 0, 3)], MenuCX + 145 + (1 - Appear) * 80, Y,
              alRight, 255, 170, 100, A);
    if HighScores[I].Level > 0 then
      DrawStr(fsTiny, 'LV ' + IntToStr(HighScores[I].Level), MenuCX + 80 + (1 - Appear) * 80, Y,
              alRight, 160, 220, 255, A);
    DrawStr(fsTiny, HighScores[I].Date, MenuCX + 245 + (1 - Appear) * 80, Y, alRight, 150, 160, 200, A);
  end;
end;

procedure DrawNewGameInfo;
const
  Info: array[0..3] of string = (
    'Classic Breakout - just you and the bricks',
    'A sleepy bot: slow, late, and misses about half the time',
    'A fair rival: quick, follows the ball, sometimes aims at bricks',
    'A sharp bot: very fast, rarely misses, aims at explosives and gold');
var
  A: Byte;
  K: Single;
begin
  A := ClampByte(EaseOutCubic(MenuOpenT / 0.35) * 255);
  if StartLevelChoice > 1 then
    DrawStr(fsSmall, 'Starting at level ' + IntToStr(StartLevelChoice) + '  -  ' + Levels[StartLevelChoice].Name,
            ScreenW / 2, 140, alCenter, 160, 220, 255, A);

  { section label between SOLO and the bot difficulties }
  K := EaseOutCubic((MenuOpenT - 0.1) / 0.35);
  FillRect(MakeRect(MenuCX - 200, 250, 110 * K, 2), 255, 150, 60, 160);
  FillRect(MakeRect(MenuCX + 200 - 110 * K, 250, 110 * K, 2), 255, 150, 60, 160);
  DrawStr(fsTiny, 'PLAY AGAINST A BOT', ScreenW / 2, 251, alCenter, 255, 170, 100, ClampByte(K * 255));

  { what the highlighted choice means }
  if MenuSel <= 3 then
  begin
    DrawStr(fsTiny, Info[MenuSel], ScreenW / 2, 452, alCenter, 200, 205, 230, A);
    if MenuSel > 0 then
      DrawStr(fsTiny, 'The bot guards the top.  Bricks score for whoever hit the ball last.  Most points wins.',
              ScreenW / 2, 474, alCenter, 255, 170, 100, A);
  end;
end;

procedure DrawCheatScreen;
const
  CellW = 30;
var
  N: Integer;
  X0, X, Y, ShakeOff, Sc, Blink: Single;
  Ch: string;
  BorderC, TextC: TCol;
  A: Byte;
begin
  A := ClampByte(EaseOutCubic(MenuOpenT / 0.35) * 255);
  DrawStr(fsSmall, 'Enter a code from a LEVEL CLEAR screen', ScreenW / 2, 160, alCenter,
          200, 205, 230, A);
  DrawStr(fsTiny, 'It continues from that level with your scores, lives and mode (solo or vs bot)', ScreenW / 2, 186, alCenter,
          150, 155, 190, A);

  { input box: shakes red on a wrong code, glows green on a correct one }
  ShakeOff := Sin(Clock * 70) * 10 * CheatShake;
  if CheatFlash > 0 then BorderC := ColMix(Col(255, 215, 90), Col(90, 255, 140), CheatFlash)
  else if CheatShake > 0 then BorderC := ColMix(Col(255, 215, 90), Col(255, 70, 70), CheatShake)
  else BorderC := Col(255, 215, 90, ClampByte(170 + 60 * Sin(Clock * 3)));
  if CheatFlash > 0 then
    Glow(ScreenW / 2, 262, 260, 70, Col(90, 255, 140, ClampByte(CheatFlash * 120)));
  RoundRect(ScreenW / 2 - 235 + ShakeOff, 228, 470, 68, 12, BorderC);
  RoundRect(ScreenW / 2 - 232 + ShakeOff, 231, 464, 62, 10, Col(12, 14, 34, 245));

  { 12 character cells in groups of 4 (older 9-character codes also work) }
  X0 := ScreenW / 2 - (CodeLen * CellW + 2 * 16) / 2 + CellW / 2 + ShakeOff;
  Y := 262;
  for N := 1 to CodeLen do
  begin
    X := X0 + (N - 1) * CellW + ((N - 1) div 4) * 16;
    if (N > 1) and ((N - 1) mod 4 = 0) then
      DrawStr(fsSmall, '-', X - CellW / 2 - 8, Y, alCenter, 150, 155, 190);
    if N <= Length(CheatInput) then
    begin
      Ch := CheatInput[N];
      Sc := 1;
      if (N = Length(CheatInput)) and (CheatTypedT > 0) then Sc := 1 + 0.5 * CheatTypedT;
      if CheatFlash > 0 then TextC := Col(140, 255, 170) else TextC := Col(255, 255, 255);
      DrawStr(fsMedium, Ch, X, Y, alCenter, TextC.R, TextC.G, TextC.B, 255, Sc);
    end
    else
    begin
      Rect(X - 9, Y + 12, 18, 3, Col(150, 155, 190, 110));        { empty slot }
      Blink := 0.5 + 0.5 * Sin(Clock * 8);
      if (N = Length(CheatInput) + 1) and (CheatStartT < 0) then  { cursor }
        Rect(X - 9, Y + 12, 18, 3, Col(255, 215, 90, ClampByte(Blink * 255)));
    end;
  end;

  { message under the box }
  if CheatMsg <> '' then
  begin
    if CheatMsgOK then
    begin
      DrawStr(fsMedium, CheatMsg, ScreenW / 2, 316, alCenter, 120, 255, 160, 255,
              1 + 0.05 * Sin(Clock * 6));
      DrawStr(fsSmall, CheatMsg2, ScreenW / 2, 342, alCenter, 255, 215, 90);
    end
    else
      DrawStr(fsSmall, CheatMsg, ScreenW / 2, 318, alCenter, 255, 110, 110);
  end;

  { the last code you earned }
  if (LastCode <> '') and (LastCodeLevel >= 2) then
    DrawStr(fsTiny, 'Last code you earned:  ' + LastCode + '  (level ' + IntToStr(LastCodeLevel) +
            ')   -   press TAB to fill it in', ScreenW / 2, 508, alCenter, 160, 220, 255, A);
end;

procedure DrawMenu;
var
  I, S, L: Integer;
  Y, Appear, Off, Sc, Ang, H, Bob, BarW, BH: Single;
  R, G, B, A: Byte;
  Heading: string;
  Font: TFontSize;
begin
  Heading := '';
  if GameInProgress then FillRect(MakeRect(0, 0, ScreenW, ScreenH), 5, 5, 15, 200)
  else FillRect(MakeRect(0, 0, ScreenW, ScreenH), 5, 5, 15, 60);

  case MenuScreen of
    msMain: DrawTitle;
    msLevels: Heading := 'LEVELS';
    msGraphics: Heading := 'GRAPHICS';
    msSound: Heading := 'SOUND';
    msHighScores: Heading := 'HIGH SCORES';
    msCheat: Heading := 'CHEAT CODE';
    msNewGame: Heading := 'NEW GAME';
  end;
  if MenuScreen <> msMain then
    DrawStr(fsLarge, Heading, ScreenW / 2, 90, alCenter, 255, 255, 255, 255,
            MaxF(0.01, EaseOutBack(MenuOpenT / 0.5)));
  if MenuScreen = msHighScores then DrawHighScoreTable;
  if MenuScreen = msCheat then DrawCheatScreen;
  if MenuScreen = msNewGame then DrawNewGameInfo;

  { the corner "Cheat-code" button always shows its outline }
  if MenuScreen = msMain then
  begin
    Appear := EaseOutCubic((MenuOpenT - 0.4) / 0.35);
    RoundRect(ItemCX(7) - ItemHalfW(7), ItemY(7) - 16, ItemHalfW(7) * 2, 32, 8,
              Col(160, 220, 255, ClampByte(Appear * 120)));
    RoundRect(ItemCX(7) - ItemHalfW(7) + 2, ItemY(7) - 14, ItemHalfW(7) * 2 - 4, 28, 7,
              Col(12, 14, 34, ClampByte(Appear * 235)));
  end;

  { selection bar: glides to the chosen item and resizes to fit it }
  BH := SelBarHH;
  BarW := SelBarHW * 2 * (1 + 0.04 * Sin(Clock * 5)) + SelFlash * 40;
  FillRect(MakeRect(SelBarX - BarW / 2, SelBarY - BH, BarW, BH * 2), 10, 12, 30, 235);
  FillRect(MakeRect(SelBarX - BarW / 2, SelBarY - BH - SelFlash * 4, BarW, BH * 2 + SelFlash * 8),
           90, 110, 255, ClampByte(55 + 25 * Sin(Clock * 5) + SelFlash * 150));
  FillRect(MakeRect(SelBarX - BarW / 2, SelBarY - BH, 4, BH * 2), 255, 215, 90, 220);
  FillRect(MakeRect(SelBarX + BarW / 2 - 4, SelBarY - BH, 4, BH * 2), 255, 215, 90, 220);
  if SelFlash > 0 then
    FillRect(MakeRect(SelBarX - BarW / 2, SelBarY - BH, BarW, BH * 2), 255, 255, 255,
             ClampByte(SelFlash * SelFlash * 160));

  for I := 0 to MenuCount - 1 do
  begin
    Y := ItemY(I);
    Appear := EaseOutCubic((MenuOpenT - I * 0.05) / 0.35);
    if Odd(I) then Off := (1 - Appear) * 260 else Off := (1 - Appear) * -260;
    A := ClampByte(Appear * 255);
    H := MenuHi[I];
    Sc := 1 + 0.12 * H + 0.35 * MenuPunch[I] * MenuPunch[I];
    Ang := H * Sin(Clock * 5) * 1.5;

    if not MenuEnabled[I] then
    begin R := 90; G := 90; B := 115; end
    else
    begin
      R := LerpB(190, 255, H);
      G := LerpB(195, ClampByte(215 + 30 * Sin(Clock * 6)), H);
      B := LerpB(225, 120, H);
    end;

    if MenuIsSlider[I] then
    begin
      DrawStr(fsSmall, MenuLabel[I], MenuCX - MenuHalfW + 18 + Off, Y, alLeft, R, G, B, A, Sc, Ang);
      for S := 0 to 9 do
      begin
        if S < MenuSlider[I] then
          FillRect(MakeRect(MenuCX + 40 + S * 15 + Off, Y - 9 + (9 - S) * 0.6, 11, 18 - (9 - S) * 1.2),
                   LerpB(120, 255, S / 9), LerpB(200, 215, S / 9), LerpB(255, 90, S / 9), A)
        else
          FillRect(MakeRect(MenuCX + 40 + S * 15 + Off, Y - 9 + (9 - S) * 0.6, 11, 18 - (9 - S) * 1.2),
                   255, 255, 255, A div 6);
      end;
    end
    else if MenuValue[I] <> '' then
    begin
      DrawStr(fsSmall, MenuLabel[I], MenuCX - MenuHalfW + 18 + Off, Y, alLeft, R, G, B, A, Sc, Ang);
      DrawStr(fsSmall, MenuValue[I], MenuCX + MenuHalfW - 18 + Off, Y, alRight,
              LerpB(200, 255, H), LerpB(205, 215, H), LerpB(230, 90, H), A, Sc);
    end
    else
    begin
      if (MenuScreen = msLevels) or IsCornerItem(I) then Font := fsSmall else Font := fsMedium;
      DrawStr(Font, MenuLabel[I], ItemCX(I) + Off, Y, alCenter, R, G, B, A, Sc, Ang);
    end;
  end;

  Bob := Sin(Clock * 8) * 5;
  if not IsCornerItem(MenuSel) then
  begin
    DrawStr(fsMedium, '>', SelBarX - SelBarHW - 22 - Bob, SelBarY, alCenter, 255, 215, 90);
    DrawStr(fsMedium, '<', SelBarX + SelBarHW + 22 + Bob, SelBarY, alCenter, 255, 215, 90);
  end;

  DrawParticles;

  { details of the highlighted level }
  if (MenuScreen = msLevels) and (MenuSel < LevelCount) then
  begin
    L := MenuSel + 1;
    DrawStr(fsTiny, 'Bricks: ' + StyleNames[Levels[L].Style] + '     Background: ' + BgNames[Levels[L].Bg],
            ScreenW / 2, 492, alCenter, 160, 220, 255);
  end;

  if MenuScreen in [msGraphics, msSound] then
    DrawStr(fsTiny, 'LEFT / RIGHT to change   -   ENTER to cycle   -   ESC back',
            ScreenW / 2, ScreenH - 20, alCenter, 140, 145, 180)
  else if MenuScreen = msCheat then
    DrawStr(fsTiny, 'type the code   -   ENTER apply   -   Ctrl+V paste   -   BACKSPACE delete   -   ESC back',
            ScreenW / 2, ScreenH - 20, alCenter, 140, 145, 180)
  else
    DrawStr(fsTiny, 'UP / DOWN or mouse to choose   -   ENTER to select   -   F11 fullscreen',
            ScreenW / 2, ScreenH - 20, alCenter, 140, 145, 180);
end;

procedure Render;
begin
  SDL_SetRenderDrawColor(Renderer, 0, 0, 0, 255);
  SDL_RenderClear(Renderer);

  CamX := 0; CamY := 0;
  DrawOffX := 0; DrawOffY := 0;
  BgDraw(BgFlash);

  if (State <> gsMenu) or GameInProgress then
  begin
    CamX := ShakeX; CamY := ShakeY;
    DrawOffX := CamX; DrawOffY := CamY;
    DrawWorld;
    CamX := 0; CamY := 0;
    DrawOffX := 0; DrawOffY := 0;
    DrawHUD;
  end;

  if State = gsMenu then DrawMenu
  else DrawOverlays;

  SDL_RenderPresent(Renderer);
end;

{ ================= main ================= }

var
  LastTicks, NowTicks: UInt64;
  DT: Single;
begin
  Randomize;
  LoadAll;

  if not SDL_Init(SDL_INIT_VIDEO) then
    Fatal('SDL_Init failed');

  if not SDL_CreateWindowAndRenderer('SDL3 Breakout (Lazarus)', ScreenW, ScreenH,
                                     SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
    Fatal('Could not create window/renderer');

  SDL_SetRenderLogicalPresentation(Renderer, ScreenW, ScreenH, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  SDL_SetRenderDrawBlendMode(Renderer, SDL_BLENDMODE_BLEND);

  DrawInit(Renderer);
  TextInit(Renderer);
  AudioInit;
  ApplySettings;
  BgSet(bgStarfield);
  PaddleW := BasePaddleW;
  PaddleX := (ScreenW - PaddleW) / 2;
  OpenMenu(msMain, 0);

  Running := True;
  LastTicks := SDL_GetTicks;
  while Running do
  begin
    NowTicks := SDL_GetTicks;
    DT := MinF((NowTicks - LastTicks) / 1000.0, 0.05);
    LastTicks := NowTicks;

    HandleEvents;
    Update(DT);
    AudioUpdate;
    Render;

    SDL_Delay(1);
  end;

  AudioShutdown;
  TextShutdown;
  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
