unit GameLevels;

{ The 10 levels: layout, brick size, brick style, background and colors.

  Map characters:
    .  empty          #  normal          2  tough (2 hits)     3  armored (3 hits)
    S  steel (unbreakable, not needed to clear the level)
    X  explosive (blows up its neighbours, chains into other X)
    G  gold (big points, always drops a power-up)
    M  moving (slides left/right into the empty cells beside it)
    H  ghost (fades in and out; the ball passes through while it is faded)
    E  electric (when destroyed, lightning jumps to 3 nearby bricks)

  To make your own level, copy a Def(...) block in DefineLevels and edit it.
  Rows must all be the same length. }

{$mode objfpc}{$H+}

interface

type
  TBrickStyle = (lsClassic, lsCartoon, lsSaturn, lsOval, lsCyber, lsCrystal,
                 lsHex, lsPixel, lsGlossy, lsMixed);
  TBgKind = (bgStarfield, bgNebula, bgWarp, bgOcean, bgSynthCity, bgCrystalCave,
             bgAurora, bgMatrix, bgLava, bgBlackHole);
  TColorMode = (cmRow, cmCol, cmDiag, cmRadial);
  TBrickKind = (bkNormal, bkTough, bkArmored, bkSteel, bkExplosive, bkGold,
                bkMoving, bkGhost, bkElectric);

  TLevelDef = record
    Name: string;
    Style: TBrickStyle;
    Bg: TBgKind;
    BrickW, BrickH, Gap, Top: Integer;
    OffsetOdd: Boolean;            { honeycomb: shift odd rows by half a brick }
    ColorMode: TColorMode;
    Palette: array[0..5] of Cardinal;
    Map: array of string;
  end;

const
  LevelCount = 10;

var
  Levels: array[1..LevelCount] of TLevelDef;

function CharToKind(Ch: Char; out Kind: TBrickKind): Boolean;   { False for '.' }
procedure LevelColor(const L: TLevelDef; Row, Col: Integer; out R, G, B: Byte);
function LevelCols(const L: TLevelDef): Integer;
function LevelRows(const L: TLevelDef): Integer;

implementation

procedure Def(N: Integer; const AName: string; AStyle: TBrickStyle; ABg: TBgKind;
              AW, AH, AGap, ATop: Integer; AOffset: Boolean; AMode: TColorMode;
              const APal: array of Cardinal; const AMap: array of string);
var
  I: Integer;
begin
  Levels[N].Name := AName;
  Levels[N].Style := AStyle;
  Levels[N].Bg := ABg;
  Levels[N].BrickW := AW;
  Levels[N].BrickH := AH;
  Levels[N].Gap := AGap;
  Levels[N].Top := ATop;
  Levels[N].OffsetOdd := AOffset;
  Levels[N].ColorMode := AMode;
  for I := 0 to 5 do
    if I <= High(APal) then Levels[N].Palette[I] := APal[I]
    else Levels[N].Palette[I] := $FFFFFF;
  SetLength(Levels[N].Map, Length(AMap));
  for I := 0 to High(AMap) do
    Levels[N].Map[I] := AMap[I];
end;

procedure DefineLevels;
begin
  Def(1, 'FIRST LIGHT', lsClassic, bgStarfield, 70, 22, 6, 86, False, cmRow,
      [$EB4B55, $F5913C, $F0D246, $5AC86E, $46A0EB, $966EE6],
      ['##########',
       '##########',
       '###G##G###',
       '##########',
       '#2######2#',
       '##########']);
  Def(2, 'BUBBLEGUM HEART', lsCartoon, bgNebula, 56, 26, 7, 80, False, cmRow,
      [$FF6FA8, $FF8FC0, $F26CD6, $C77DFF, $FF9F6F, $FFC96F],
      ['..##....##..',
       '.####..####.',
       '####2##2####',
       '###G####G###',
       '.##########.',
       '..###XX###..',
       '...######...',
       '....####....',
       '.....##.....']);
  Def(3, 'RING WORLD', lsSaturn, bgWarp, 46, 34, 8, 80, False, cmRadial,
      [$FFD27A, $F2A65A, $D9775B, $B45EA0, $7E6BD9, $5A9BE6],
      ['......G......',
       '....##X##....',
       '..###2#2###..',
       '#####XGX#####',
       '..###2#2###..',
       '....##X##....',
       '......#......']);
  Def(4, 'PILL FACTORY', lsOval, bgOcean, 62, 24, 8, 80, False, cmCol,
      [$4DE1D2, $3FC1E8, $5A8CF0, $8C7CF5, $F07CC8, $F5B04D],
      ['#2#2#2#2#2#',
       '#.#.#.#.#.#',
       '.M...M...M.',
       '##G#####G##',
       '...M...M...',
       '2#2#2#2#2#2',
       '#.#.#.#.#.#']);
  Def(5, 'NEON DISTRICT', lsCyber, bgSynthCity, 62, 22, 8, 80, False, cmRow,
      [$00F0FF, $FF2BD6, $B14BFF, $00FF9C, $FFE600, $FF5A36],
      ['..E.....E..',
       '...#...#...',
       '..#######..',
       '.##S###S##.',
       '###########',
       '#.##2G2##.#',
       '#.#.....#.#',
       '...##.##...']);
  Def(6, 'CRYSTAL CAVERNS', lsCrystal, bgCrystalCave, 48, 28, 6, 80, False, cmDiag,
      [$8FE9FF, $A7B8FF, $D4A6FF, $FF9FE5, $9FFFD9, $E0F4FF],
      ['3............3',
       '#3..........3#',
       'H#3........3#H',
       '.H#3..GG..3#H.',
       '..H#3.##.3#H..',
       '...H#3##3#H...',
       '....H#33#H....',
       '.....H##H.....']);
  Def(7, 'HONEYCOMB', lsHex, bgAurora, 54, 32, 8, 80, True, cmRow,
      [$FFC83D, $FFA62B, $F2804B, $E8D15A, $C9E265, $FFB86B],
      ['############',
       '#X##2##X##2#',
       '##2##X##2###',
       '#G##2##X##G#',
       '##X##2##2##X',
       '############']);
  Def(8, 'DIGITAL RAIN', lsPixel, bgMatrix, 34, 16, 4, 78, False, cmCol,
      [$39FF6A, $22D65A, $7CFF9E, $16B84A, $B8FFC9, $4DFF88],
      ['####################',
       '#E######H######E####',
       '##H##########H######',
       '######E######...####',
       '####.....G.....#####',
       '###H##########H#####',
       '#E######22######E###',
       '#####H########H#####',
       '##########E#########',
       '####################']);
  Def(9, 'LAVA CORE', lsGlossy, bgLava, 66, 26, 10, 80, False, cmRadial,
      [$FFE07A, $FFB347, $FF7A2F, $E8452C, $C22A3A, $8E1E4A],
      ['S########S',
       'S#XXXXXX#S',
       'S#X3GG3X#S',
       'S#XXXXXX#S',
       'S########S',
       'SSSS..SSSS',
       '3333333333']);
  Def(10, 'EVENT HORIZON', lsMixed, bgBlackHole, 52, 26, 6, 80, False, cmRadial,
      [$FFFFFF, $C9B6FF, $9B7BFF, $6B5BE8, $FF7AD9, $7AE1FF],
      ['S.....G.....S',
       '.3H3..E..3H3.',
       '..X.M...M.X..',
       'S#2#E#3#E#2#S',
       '###H#XGX#H###',
       '.M...#.#...M.',
       'S2#3#2E2#3#2S',
       '..H.#####.H..']);
end;

function CharToKind(Ch: Char; out Kind: TBrickKind): Boolean;
begin
  Result := True;
  case Ch of
    '#': Kind := bkNormal;
    '2': Kind := bkTough;
    '3': Kind := bkArmored;
    'S': Kind := bkSteel;
    'X': Kind := bkExplosive;
    'G': Kind := bkGold;
    'M': Kind := bkMoving;
    'H': Kind := bkGhost;
    'E': Kind := bkElectric;
  else
    begin
      Kind := bkNormal;
      Result := False;
    end;
  end;
end;

function LevelCols(const L: TLevelDef): Integer;
begin
  if Length(L.Map) = 0 then Result := 0 else Result := Length(L.Map[0]);
end;

function LevelRows(const L: TLevelDef): Integer;
begin
  Result := Length(L.Map);
end;

procedure LevelColor(const L: TLevelDef; Row, Col: Integer; out R, G, B: Byte);
var
  Idx, Rows, Cols: Integer;
  C: Cardinal;
  DX, DY: Single;
begin
  Rows := LevelRows(L);
  Cols := LevelCols(L);
  case L.ColorMode of
    cmRow:  Idx := Row;
    cmCol:  Idx := Col * 6 div (Cols + 1);
    cmDiag: Idx := Row + Col div 2;
  else
    begin    { rings from the center outward }
      DX := (Col - (Cols - 1) / 2) / (Cols / 2);
      DY := (Row - (Rows - 1) / 2) / (Rows / 2);
      Idx := Trunc(Sqrt(DX * DX + DY * DY) * 4);
    end;
  end;
  C := L.Palette[Abs(Idx) mod 6];
  R := (C shr 16) and $FF;
  G := (C shr 8) and $FF;
  B := C and $FF;
end;

initialization
  DefineLevels;

end.
