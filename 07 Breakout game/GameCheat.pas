unit GameCheat;

{ Cheat codes. A level-clear screen hands out a code like  KNV8-2KGL-66EH
  that stores the NEXT level, your score, your lives, the game mode
  (solo / vs bot easy / normal / hard) and the bot's score.
  Typing it on the Cheat-code screen continues from there.

  Code (version 2, 12 characters = 60 bits):
    payload 47 bits = level 4 | lives 4 | mode 2 | score 20 (max 1,048,575)
                      | bot score 17 (max 131,071)
    check   13 bits = hash of the payload            -> typos are rejected
    the payload is XOR-scrambled with a key made from the check, so nearly
    identical games give completely different codes.

  Older 9-character codes (version 1: level, lives, score) are still
  accepted and start a solo game.
  The 32 letters skip look-alikes (no I, O, 0, 1). }

{$mode objfpc}{$H+}
{$Q-}{$R-}

interface

const
  CodeChars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  CodeLen       = 12;      { characters in a new code, without dashes }
  LegacyCodeLen = 9;       { old solo-only codes }
  MaxCodeScore    = 1048575;
  MaxCodeBotScore = 131071;

  { Mode: 0 = solo, 1 = vs bot easy, 2 = vs bot normal, 3 = vs bot hard }
function MakeCheatCode(Level, Score, Lives, Mode, BotScore: Integer): string;

{ True when the code is genuine; all values are filled in }
function ReadCheatCode(const Code: string;
                       out Level, Score, Lives, Mode, BotScore: Integer): Boolean;

{ upper-case, keep only valid code letters (drops dashes and spaces) }
function NormalizeCode(const S: string): string;

{ 'ABCDEFGHJKLM' -> 'ABCD-EFGH-JKLM' (works on partial input too) }
function FormatCode(const Raw: string): string;

implementation

const
  M32: QWord    = $FFFFFFFF;
  { version 1 }
  Salt: QWord   = $5A17C0DE;
  KeyAdd: QWord = $B5297A4D;
  { version 2 }
  Salt2: QWord  = $3C6EF372;
  KeyA: QWord   = $9E3779B9;
  KeyB: QWord   = $7F4A7C15;

function Mask47: QWord;
begin
  Result := (QWord(1) shl 47) - 1;
end;

function Mix32(X: QWord): QWord;
begin
  X := X and M32;
  X := X xor (X shr 16);
  X := (X * $45D9F3B) and M32;
  X := X xor (X shr 16);
  X := (X * $45D9F3B) and M32;
  X := X xor (X shr 16);
  Result := X;
end;

{ ---- version 1 (9 characters) ---- }

function Check1(Payload: QWord): QWord;
begin
  Result := Mix32(Payload xor Salt) and $1FFF;
end;

function Key1(Check: QWord): QWord;
begin
  Result := Mix32(Check + KeyAdd);
end;

{ ---- version 2 (12 characters) ---- }

function Check2(Payload: QWord): QWord;
begin
  Result := Mix32((Payload and M32) xor Mix32(((Payload shr 32) + Salt2) and M32)) and $1FFF;
end;

function Key2(Check: QWord): QWord;
begin
  Result := ((Mix32(Check + KeyA) shl 15) xor Mix32(Check + KeyB)) and Mask47;
end;

{ ---- helpers ---- }

function Clamp(V, Lo, Hi: Integer): Integer;
begin
  if V < Lo then Result := Lo
  else if V > Hi then Result := Hi
  else Result := V;
end;

function NormalizeCode(const S: string): string;
var
  I: Integer;
  Ch: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    Ch := UpCase(S[I]);
    if Pos(Ch, CodeChars) > 0 then Result := Result + Ch;
  end;
end;

function FormatCode(const Raw: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(Raw) do
  begin
    if (I > 1) and ((I - 1) mod 4 = 0) then Result := Result + '-';
    Result := Result + Raw[I];
  end;
end;

function MakeCheatCode(Level, Score, Lives, Mode, BotScore: Integer): string;
var
  Payload, Check, V: QWord;
  I: Integer;
  Raw: string;
begin
  Payload := (QWord(Clamp(Level, 0, 15)) shl 43) or
             (QWord(Clamp(Lives, 0, 15)) shl 39) or
             (QWord(Clamp(Mode, 0, 3)) shl 37) or
             (QWord(Clamp(Score, 0, MaxCodeScore)) shl 17) or
             QWord(Clamp(BotScore, 0, MaxCodeBotScore));
  Check := Check2(Payload);
  V := (((Payload xor Key2(Check)) and Mask47) shl 13) or Check;

  Raw := '';
  for I := CodeLen - 1 downto 0 do
    Raw := Raw + CodeChars[((V shr (5 * I)) and 31) + 1];
  Result := FormatCode(Raw);
end;

function ReadCheatCode(const Code: string;
                       out Level, Score, Lives, Mode, BotScore: Integer): Boolean;
var
  Raw: string;
  V, Check, Payload: QWord;
  I: Integer;
begin
  Level := 0;
  Score := 0;
  Lives := 0;
  Mode := 0;
  BotScore := 0;
  Result := False;

  Raw := NormalizeCode(Code);
  if (Length(Raw) <> CodeLen) and (Length(Raw) <> LegacyCodeLen) then Exit;

  V := 0;
  for I := 1 to Length(Raw) do
    V := (V shl 5) or QWord(Pos(Raw[I], CodeChars) - 1);
  Check := V and $1FFF;

  if Length(Raw) = LegacyCodeLen then
  begin
    Payload := ((V shr 13) and M32) xor Key1(Check);
    if Check1(Payload) <> Check then Exit;
    Level := Integer((Payload shr 28) and 15);
    Lives := Integer((Payload shr 24) and 15);
    Score := Integer(Payload and $FFFFFF);
  end
  else
  begin
    Payload := ((V shr 13) and Mask47) xor Key2(Check);
    if Check2(Payload) <> Check then Exit;
    Level := Integer((Payload shr 43) and 15);
    Lives := Integer((Payload shr 39) and 15);
    Mode := Integer((Payload shr 37) and 3);
    Score := Integer((Payload shr 17) and $FFFFF);
    BotScore := Integer(Payload and $1FFFF);
  end;
  Result := True;
end;

end.
