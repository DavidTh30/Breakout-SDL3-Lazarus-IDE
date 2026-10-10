unit GameSave;

{ Settings and high scores, stored in an INI file in the per-user data
  folder that SDL picks (on Windows:
  C:\Users\<you>\AppData\Roaming\LazarusGames\SDLBreakout\breakout.ini). }

{$mode objfpc}{$H+}

interface

const
  MaxHighScores = 10;

type
  TSettings = record
    Fullscreen: Boolean;
    VSync: Boolean;
    Particles: Integer;      { 0 = off, 1 = low, 2 = high }
    ScreenShake: Boolean;
    AnimatedBg: Boolean;
    MusicVolume: Integer;    { 0..10 }
    SfxVolume: Integer;      { 0..10 }
  end;

  THighScore = record
    Score: Integer;
    Level: Integer;          { level reached }
    Mode: Integer;           { 0 solo, 1..3 vs bot easy / normal / hard }
    Date: string;
  end;

var
  Settings: TSettings;
  HighScores: array[0..MaxHighScores - 1] of THighScore;
  UnlockedLevel: Integer = 1;   { highest level you may start from (Levels menu) }
  LastCode: string = '';        { last cheat code earned on a level-clear screen }
  LastCodeLevel: Integer = 0;

procedure LoadAll;
procedure SaveSettings;
procedure SaveHighScores;
procedure UnlockLevel(Level: Integer);   { saves if it is a new record }
procedure SaveLastCode(Level: Integer; const Code: string);

{ inserts the score if it makes the table; returns its rank (0 = best) or -1 }
function AddHighScore(Score, Level, Mode: Integer): Integer;
function BestScore: Integer;
function SaveFileName: string;

implementation

uses
  SysUtils, Math, IniFiles, SDL3;

var
  FileName: string = '';

function SaveFileName: string;
var
  P: PAnsiChar;
begin
  if FileName = '' then
  begin
    P := SDL_GetPrefPath('LazarusGames', 'SDLBreakout');   { creates the folder }
    if P <> nil then
    begin
      FileName := string(P) + 'breakout.ini';
      SDL_free(P);
    end
    else
      FileName := 'breakout.ini';   { fall back to the current folder }
  end;
  Result := FileName;
end;

procedure DefaultSettings;
begin
  Settings.Fullscreen := False;
  Settings.VSync := True;
  Settings.Particles := 2;
  Settings.ScreenShake := True;
  Settings.AnimatedBg := True;
  Settings.MusicVolume := 7;
  Settings.SfxVolume := 8;
end;

procedure LoadAll;
var
  Ini: TIniFile;
  I: Integer;
begin
  DefaultSettings;
  for I := 0 to MaxHighScores - 1 do
  begin
    HighScores[I].Score := 0;
    HighScores[I].Level := 0;
    HighScores[I].Mode := 0;
    HighScores[I].Date := '';
  end;
  UnlockedLevel := 1;

  try
    Ini := TIniFile.Create(SaveFileName);
    try
      Settings.Fullscreen  := Ini.ReadBool('Settings', 'Fullscreen', Settings.Fullscreen);
      Settings.VSync       := Ini.ReadBool('Settings', 'VSync', Settings.VSync);
      Settings.Particles   := EnsureRange(Ini.ReadInteger('Settings', 'Particles', Settings.Particles), 0, 2);
      Settings.ScreenShake := Ini.ReadBool('Settings', 'ScreenShake', Settings.ScreenShake);
      Settings.AnimatedBg  := Ini.ReadBool('Settings', 'AnimatedBackground', Settings.AnimatedBg);
      Settings.MusicVolume := EnsureRange(Ini.ReadInteger('Settings', 'MusicVolume', Settings.MusicVolume), 0, 10);
      Settings.SfxVolume   := EnsureRange(Ini.ReadInteger('Settings', 'SfxVolume', Settings.SfxVolume), 0, 10);

      for I := 0 to MaxHighScores - 1 do
      begin
        HighScores[I].Score := Max(0, Ini.ReadInteger('HighScores', 'Score' + IntToStr(I), 0));
        HighScores[I].Level := Max(0, Ini.ReadInteger('HighScores', 'Level' + IntToStr(I), 0));
        HighScores[I].Mode := EnsureRange(Ini.ReadInteger('HighScores', 'Mode' + IntToStr(I), 0), 0, 3);
        HighScores[I].Date := Ini.ReadString('HighScores', 'Date' + IntToStr(I), '');
      end;
      UnlockedLevel := Max(1, Ini.ReadInteger('Progress', 'UnlockedLevel', 1));
      LastCode := Ini.ReadString('Progress', 'LastCode', '');
      LastCodeLevel := Ini.ReadInteger('Progress', 'LastCodeLevel', 0);
    finally
      Ini.Free;
    end;
  except
    { unreadable file: keep defaults }
  end;
end;

procedure SaveSettings;
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(SaveFileName);
    try
      Ini.WriteBool('Settings', 'Fullscreen', Settings.Fullscreen);
      Ini.WriteBool('Settings', 'VSync', Settings.VSync);
      Ini.WriteInteger('Settings', 'Particles', Settings.Particles);
      Ini.WriteBool('Settings', 'ScreenShake', Settings.ScreenShake);
      Ini.WriteBool('Settings', 'AnimatedBackground', Settings.AnimatedBg);
      Ini.WriteInteger('Settings', 'MusicVolume', Settings.MusicVolume);
      Ini.WriteInteger('Settings', 'SfxVolume', Settings.SfxVolume);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
    { saving is best-effort; never crash the game over it }
  end;
end;

procedure SaveHighScores;
var
  Ini: TIniFile;
  I: Integer;
begin
  try
    Ini := TIniFile.Create(SaveFileName);
    try
      for I := 0 to MaxHighScores - 1 do
      begin
        Ini.WriteInteger('HighScores', 'Score' + IntToStr(I), HighScores[I].Score);
        Ini.WriteInteger('HighScores', 'Level' + IntToStr(I), HighScores[I].Level);
        Ini.WriteInteger('HighScores', 'Mode' + IntToStr(I), HighScores[I].Mode);
        Ini.WriteString('HighScores', 'Date' + IntToStr(I), HighScores[I].Date);
      end;
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
  end;
end;

procedure UnlockLevel(Level: Integer);
var
  Ini: TIniFile;
begin
  if Level <= UnlockedLevel then Exit;
  UnlockedLevel := Level;
  try
    Ini := TIniFile.Create(SaveFileName);
    try
      Ini.WriteInteger('Progress', 'UnlockedLevel', UnlockedLevel);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
  end;
end;

procedure SaveLastCode(Level: Integer; const Code: string);
var
  Ini: TIniFile;
begin
  LastCode := Code;
  LastCodeLevel := Level;
  try
    Ini := TIniFile.Create(SaveFileName);
    try
      Ini.WriteString('Progress', 'LastCode', Code);
      Ini.WriteInteger('Progress', 'LastCodeLevel', Level);
      Ini.UpdateFile;
    finally
      Ini.Free;
    end;
  except
  end;
end;

function AddHighScore(Score, Level, Mode: Integer): Integer;
var
  I, Rank: Integer;
begin
  Result := -1;
  if Score <= 0 then Exit;

  Rank := -1;
  for I := 0 to MaxHighScores - 1 do
    if Score > HighScores[I].Score then
    begin
      Rank := I;
      Break;
    end;
  if Rank < 0 then Exit;

  for I := MaxHighScores - 1 downto Rank + 1 do
    HighScores[I] := HighScores[I - 1];
  HighScores[Rank].Score := Score;
  HighScores[Rank].Level := Level;
  HighScores[Rank].Mode := Mode;
  HighScores[Rank].Date := FormatDateTime('yyyy-mm-dd', Now);
  SaveHighScores;
  Result := Rank;
end;

function BestScore: Integer;
begin
  Result := HighScores[0].Score;
end;

end.
