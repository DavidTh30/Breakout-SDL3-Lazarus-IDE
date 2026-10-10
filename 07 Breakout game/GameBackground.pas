unit GameBackground;

{ Ten animated backgrounds, one per level.
  BgSet(kind) re-seeds the moving elements, BgUpdate advances them,
  BgDraw paints the whole 800x600 screen. }

{$mode objfpc}{$H+}

interface

uses
  GameLevels;

var
  BgAnimated: Boolean = True;     { False = frozen ("Static" graphics option) }

procedure BgSet(AKind: TBgKind);
procedure BgUpdate(DT: Single);
procedure BgDraw(Flash: Single);    { Flash 0..1 brightens briefly on brick hits }

implementation

uses
  SDL3, Math, GameDraw, GameText;

const
  SW = 800;
  SH = 600;
  MaxItems = 240;
  Glyphs = '0123456789ABCDEFXZ$#@*+=<>';

type
  TItem = record
    X, Y, VX, VY, Size, Phase, Speed: Single;
  end;

var
  CurKind: TBgKind = bgStarfield;
  T: Single = 0;
  Items: array[0..MaxItems - 1] of TItem;
  ItemCount: Integer = 0;
  Buildings: array[0..39] of TItem;     { synth city skyline }

function RandF(A, B: Single): Single;
begin
  Result := A + Random * (B - A);
end;

function CB(V: Single): Byte;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Round(V);
end;

{ ---------- setup ---------- }

procedure BgSet(AKind: TBgKind);
var
  I: Integer;
  X: Single;
begin
  CurKind := AKind;
  case CurKind of
    bgStarfield, bgNebula, bgAurora: ItemCount := 140;
    bgWarp:        ItemCount := 170;
    bgOcean:       ItemCount := 60;
    bgSynthCity:   ItemCount := 70;
    bgCrystalCave: ItemCount := 26;
    bgMatrix:      ItemCount := 42;
    bgLava:        ItemCount := 70;
  else
    ItemCount := 220;     { black hole }
  end;

  for I := 0 to ItemCount - 1 do
    with Items[I] do
    begin
      X := RandF(0, SW);
      Y := RandF(0, SH);
      VX := 0;
      VY := 0;
      Size := RandF(1, 3);
      Phase := RandF(0, 2 * Pi);
      Speed := RandF(0.5, 1.5);
    end;

  case CurKind of
    bgWarp:
      for I := 0 to ItemCount - 1 do
      begin
        Items[I].Phase := RandF(0, 2 * Pi);     { direction }
        Items[I].Y := RandF(5, 500);           { distance from center }
      end;
    bgMatrix:
      for I := 0 to ItemCount - 1 do
      begin
        Items[I].X := I * (SW / ItemCount) + 4;
        Items[I].Y := RandF(-SH, SH);
        Items[I].Speed := RandF(90, 260);
      end;
    bgBlackHole:
      for I := 0 to ItemCount - 1 do
      begin
        Items[I].Phase := RandF(0, 2 * Pi);     { angle }
        Items[I].Y := RandF(40, 420);          { radius }
      end;
    bgLava:
      for I := 0 to ItemCount - 1 do
        if I < 8 then
        begin   { big blobs }
          Items[I].X := 60 + I * 95 + RandF(-20, 20);
          Items[I].Size := RandF(45, 85);
          Items[I].Speed := RandF(0.15, 0.35);
        end;
    bgCrystalCave:
      for I := 0 to ItemCount - 1 do
      begin
        Items[I].Size := RandF(8, 26);
        Items[I].Speed := RandF(-0.6, 0.6);     { spin }
      end;
  end;

  { skyline for the synth city }
  X := 0;
  for I := 0 to High(Buildings) do
  begin
    Buildings[I].X := X;
    Buildings[I].Size := RandF(18, 46);                       { width }
    Buildings[I].Y := RandF(25, 120);                         { height }
    Buildings[I].Phase := RandF(0, 100);
    X := X + Buildings[I].Size + RandF(0, 4);
  end;
end;

{ ---------- update ---------- }

procedure BgUpdate(DT: Single);
var
  I: Integer;
begin
  if not BgAnimated then Exit;
  T := T + DT;

  for I := 0 to ItemCount - 1 do
    with Items[I] do
      case CurKind of
        bgStarfield, bgAurora, bgNebula:
          begin
            Y := Y + (6 + Size * 10) * DT;
            if Y > SH then begin Y := -4; X := RandF(0, SW); end;
          end;
        bgWarp:
          begin
            Y := Y + (20 + Y * 1.6) * DT;          { accelerate outward }
            if Y > 620 then begin Y := RandF(2, 30); Phase := RandF(0, 2 * Pi); end;
          end;
        bgOcean, bgSynthCity:
          begin   { bubbles / floating dust rise }
            Y := Y - (20 + Size * 15) * Speed * DT;
            X := X + Sin(T * 2 + Phase) * 12 * DT;
            if Y < -10 then begin Y := SH + 10; X := RandF(0, SW); end;
          end;
        bgCrystalCave:
          begin
            Y := Y - (4 + 8 * Abs(Speed)) * DT;
            if Y < -30 then begin Y := SH + 30; X := RandF(0, SW); end;
          end;
        bgMatrix:
          begin
            Y := Y + Speed * DT;
            if Y - 16 * 14 > SH then begin Y := RandF(-200, 0); Speed := RandF(90, 260); end;
          end;
        bgLava:
          if I >= 8 then
          begin   { embers }
            Y := Y - (30 + Size * 25) * DT;
            X := X + Sin(T * 3 + Phase) * 20 * DT;
            if Y < -5 then begin Y := SH + 5; X := RandF(0, SW); end;
          end;
        bgBlackHole:
          begin   { orbit faster near the center, slowly fall in }
            Phase := Phase + (60 / (Y + 20)) * DT;
            Y := Y - (6 + 300 / (Y + 10)) * DT;
            if Y < 28 then begin Y := RandF(320, 430); Phase := RandF(0, 2 * Pi); end;
          end;
      end;
end;

{ ---------- drawing helpers ---------- }

procedure Gradient(const Top, Bottom: TCol);
const
  Bands = 12;
var
  I: Integer;
begin
  for I := 0 to Bands - 1 do
    RectGrad(0, I * SH / Bands, SW, SH / Bands + 1,
             ColMix(Top, Bottom, I / Bands), ColMix(Top, Bottom, (I + 1) / Bands));
end;

procedure Stars(Bright: Single);
var
  I: Integer;
  K: Single;
begin
  for I := 0 to ItemCount - 1 do
  begin
    K := (0.55 + 0.45 * Sin(T * (1 + Items[I].Speed * 2) + Items[I].Phase)) * Bright;
    Rect(Items[I].X, Items[I].Y, Items[I].Size, Items[I].Size, Col(255, 255, 255, CB(K * (80 + Items[I].Size * 50))));
  end;
end;

{ ---------- the ten backgrounds ---------- }

procedure DrawStarfield;
var
  Mix, Y, Off: Single;
  I: Integer;
begin
  Mix := 0.5 + 0.5 * Sin(T * 0.2);
  Gradient(ColMix(Col(34, 16, 70), Col(10, 40, 80), Mix), Col(8, 8, 20));
  Off := Frac(T * 0.5) * 40;
  Y := SH * 0.55 + Off;
  while Y < SH do
  begin
    Rect(0, Y, SW, 1, Col(120, 90, 220, CB(10 + 45 * (Y - SH * 0.55) / (SH * 0.45))));
    Y := Y + 40;
  end;
  I := 0;
  while I <= SW do
  begin
    Rect(I, SH * 0.55, 1, SH * 0.45, Col(120, 90, 220, 22));
    Inc(I, 50);
  end;
  Stars(1);
end;

procedure DrawNebula;
const
  Colors: array[0..5] of Cardinal = ($FF4FA3, $8A4FFF, $4F8AFF, $FF7AD9, $B04FFF, $4FD1FF);
var
  I: Integer;
  CX, CY, R: Single;
begin
  Gradient(Col(40, 8, 50), Col(10, 6, 30));
  for I := 0 to 5 do
  begin
    CX := 400 + Sin(T * 0.07 * (I + 1) + I * 1.7) * 320;
    CY := 300 + Cos(T * 0.05 * (I + 2) + I * 2.3) * 220;
    R := 220 + 60 * Sin(T * 0.3 + I);
    Glow(CX, CY, R * 1.3, R, ColHex(Colors[I], 55));
  end;
  Stars(0.9);
end;

procedure DrawWarp;
var
  I: Integer;
  D, L, CX, CY, A: Single;
begin
  Gradient(Col(4, 6, 22), Col(0, 0, 6));
  CX := 400 + Sin(T * 0.3) * 30;
  CY := 260 + Cos(T * 0.23) * 20;
  Glow(CX, CY, 160, 160, Col(90, 120, 255, 50));
  for I := 0 to ItemCount - 1 do
  begin
    D := Items[I].Y;
    A := Items[I].Phase;
    L := 2 + D * 0.12;
    Line(CX + Cos(A) * D, CY + Sin(A) * D, CX + Cos(A) * (D + L), CY + Sin(A) * (D + L),
         1 + D / 300, Col(200, 220, 255, CB(40 + D * 0.5)));
  end;
end;

procedure DrawOcean;
var
  I: Integer;
  X, S: Single;
begin
  Gradient(Col(20, 110, 150), Col(4, 18, 50));
  { light rays from the surface }
  for I := 0 to 5 do
  begin
    X := 80 + I * 130 + Sin(T * 0.4 + I) * 40;
    Tri(X, 0, X + 60, 0, X - 80 + Sin(T * 0.3 + I * 2) * 60, SH,
        Col(180, 240, 255, 40), Col(180, 240, 255, 40), Col(180, 240, 255, 0));
  end;
  { surface waves }
  for I := 0 to 39 do
    Rect(I * 20, 0, 20, 10 + 5 * Sin(T * 2 + I * 0.6), Col(170, 235, 255, 50));
  { bubbles }
  for I := 0 to ItemCount - 1 do
  begin
    S := 2 + Items[I].Size * 3;
    Ring(Items[I].X, Items[I].Y, S, S, 1.2, Col(200, 245, 255, 120), 0, 2 * Pi, 0, 14);
    Ellipse(Items[I].X - S * 0.35, Items[I].Y - S * 0.35, S * 0.25, S * 0.25, Col(255, 255, 255, 140), 6);
  end;
end;

procedure DrawSynthCity;
const
  Horizon = 360;
var
  I: Integer;
  Y, K, X, VX: Single;
begin
  Gradient(Col(30, 8, 60), Col(255, 80, 140));
  Rect(0, Horizon, SW, SH - Horizon, Col(18, 4, 36));
  { striped sun }
  EllipseGrad(400, Horizon - 40, 130, 130, Col(255, 230, 90), Col(255, 70, 150), 40);
  for I := 0 to 6 do
  begin
    Y := Horizon - 40 + 10 + I * 14 + Frac(T * 0.25) * 14;
    Rect(270, Y, 260, 3 + I * 0.8, ColMix(Col(255, 120, 150), Col(255, 80, 140), I / 6));
  end;
  { skyline }
  for I := 0 to High(Buildings) do
    if Buildings[I].X < SW then
    begin
      Rect(Buildings[I].X, Horizon - Buildings[I].Y, Buildings[I].Size, Buildings[I].Y, Col(25, 6, 45));
      { blinking windows }
      if Frac(T * 0.2 + Buildings[I].Phase) < 0.7 then
        Rect(Buildings[I].X + 4, Horizon - Buildings[I].Y + 8, 3, 3, Col(0, 240, 255, 200));
      if Frac(T * 0.13 + Buildings[I].Phase * 1.7) < 0.6 then
        Rect(Buildings[I].X + Buildings[I].Size - 8, Horizon - Buildings[I].Y + 20, 3, 3, Col(255, 40, 210, 200));
    end;
  Rect(0, Horizon - 1, SW, 2, Col(255, 60, 200));
  { perspective grid }
  for I := 0 to 11 do
  begin
    K := (I + Frac(T * 0.8)) / 12;
    Y := Horizon + K * K * (SH - Horizon);
    Rect(0, Y, SW, 1 + K * 2, Col(255, 40, 200, CB(60 + K * 160)));
  end;
  for I := -12 to 12 do
  begin
    X := 400 + I * 38;
    VX := 400 + I * 200;
    Line(X, Horizon, VX, SH, 1.4, Col(0, 220, 255, 110));
  end;
  { floating dust }
  for I := 0 to ItemCount - 1 do
    Rect(Items[I].X, Items[I].Y, 2, 2, Col(255, 150, 230, 90));
end;

procedure DrawCrystalCave;
var
  I: Integer;
  X, Y, S, A: Single;
  Pts: array[0..3] of TSDL_FPoint;
begin
  Gradient(Col(10, 30, 60), Col(4, 8, 20));
  { glowing crystals drifting and spinning }
  for I := 0 to ItemCount - 1 do
  begin
    X := Items[I].X;
    Y := Items[I].Y;
    S := Items[I].Size;
    A := T * Items[I].Speed + Items[I].Phase;
    Glow(X, Y, S * 2.5, S * 2.5, Col(120, 220, 255, 30));
    Pts[0] := FPt(X + Cos(A) * S * 0.6, Y + Sin(A) * S * 0.6);
    Pts[1] := FPt(X + Cos(A + Pi / 2) * S * 1.4, Y + Sin(A + Pi / 2) * S * 1.4);
    Pts[2] := FPt(X + Cos(A + Pi) * S * 0.6, Y + Sin(A + Pi) * S * 0.6);
    Pts[3] := FPt(X + Cos(A + 3 * Pi / 2) * S * 1.4, Y + Sin(A + 3 * Pi / 2) * S * 1.4);
    PolyGrad(Pts, Col(220, 250, 255, 140), Col(80, 140, 255, 60));
    if Frac(T * 0.3 + Items[I].Phase) < 0.08 then
      Star(X, Y - S, 10, Col(255, 255, 255, 220));
  end;
  { stalactites }
  for I := 0 to 15 do
  begin
    X := I * 52 + 10;
    Tri(X, 0, X + 40, 0, X + 20, 30 + (I * 37 mod 50), Col(6, 14, 30), Col(6, 14, 30), Col(20, 50, 90));
  end;
end;

procedure DrawAurora;
var
  Band, I: Integer;
  X0, X1, Y0, Y1, H: Single;
  C: TCol;
begin
  Gradient(Col(4, 10, 30), Col(10, 30, 50));
  Stars(0.8);
  for Band := 0 to 2 do
  begin
    case Band of
      0: C := Col(80, 255, 160);
      1: C := Col(60, 200, 255);
    else
      C := Col(190, 110, 255);
    end;
    for I := 0 to 39 do
    begin
      X0 := I * 20;
      X1 := X0 + 20;
      Y0 := 90 + Band * 55 + Sin(T * 0.6 + I * 0.25 + Band * 2) * 40 + Sin(T * 0.23 + I * 0.1) * 30;
      Y1 := 90 + Band * 55 + Sin(T * 0.6 + (I + 1) * 0.25 + Band * 2) * 40 + Sin(T * 0.23 + (I + 1) * 0.1) * 30;
      H := 90 + 30 * Sin(T + I * 0.3 + Band);
      Tri(X0, Y0, X1, Y1, X1, Y1 + H, ColAlpha(C, 0.5), ColAlpha(C, 0.5), ColAlpha(C, 0));
      Tri(X0, Y0, X1, Y1 + H, X0, Y0 + H, ColAlpha(C, 0.5), ColAlpha(C, 0), ColAlpha(C, 0));
    end;
  end;
  { mountains }
  for I := 0 to 7 do
    Tri(I * 110 - 60, SH, I * 110 + 50, 430 + (I * 53 mod 90), I * 110 + 160, SH,
        Col(6, 10, 24), Col(20, 30, 60), Col(6, 10, 24));
end;

procedure DrawMatrix;
var
  I, J, G: Integer;
  Y: Single;
  A: Byte;
begin
  Gradient(Col(0, 18, 6), Col(0, 4, 2));
  for I := 0 to ItemCount - 1 do
    for J := 0 to 13 do
    begin
      Y := Items[I].Y - J * 16;
      if (Y < -16) or (Y > SH) then Continue;
      G := (Trunc(Items[I].Phase * 100) + J * 7 + Trunc(T * 6) * Ord(J = 0)) mod Length(Glyphs) + 1;
      A := CB(220 * (1 - J / 14));
      if J = 0 then
        DrawStr(fsTiny, Glyphs[G], Items[I].X, Y, alLeft, 220, 255, 220, 255, 1, 0, False)
      else
        DrawStr(fsTiny, Glyphs[G], Items[I].X, Y, alLeft, 40, 255, 110, A, 1, 0, False);
    end;
end;

procedure DrawLava;
var
  I: Integer;
  X, Y, R: Single;
begin
  Gradient(Col(60, 6, 10), Col(20, 2, 6));
  for I := 0 to Min(7, ItemCount - 1) do
  begin
    X := Items[I].X + Sin(T * 0.3 + I) * 30;
    Y := 300 + Sin(T * Items[I].Speed + Items[I].Phase) * 230;
    R := Items[I].Size * (1 + 0.15 * Sin(T * 1.3 + I));
    Glow(X, Y, R * 2.2, R * 2.2, Col(255, 90, 20, 70));
    EllipseGrad(X, Y, R, R * 1.15, Col(255, 200, 80, 200), Col(230, 50, 20, 120), 28);
  end;
  for I := 8 to ItemCount - 1 do
    Rect(Items[I].X, Items[I].Y, 2, 2, Col(255, CB(140 + 100 * Sin(T * 5 + Items[I].Phase)), 40, 200));
  Glow(400, SH + 40, 600, 160, Col(255, 120, 30, 90));
end;

procedure DrawBlackHole;
const
  CX = 400;
  CY = 250;
var
  I: Integer;
  R, A, K: Single;
begin
  Gradient(Col(6, 2, 16), Col(0, 0, 4));
  Glow(CX, CY, 360, 260, Col(120, 60, 200, 45));
  { spiraling matter }
  for I := 0 to ItemCount - 1 do
  begin
    R := Items[I].Y;
    A := Items[I].Phase;
    K := 1 - R / 430;
    Rect(CX + Cos(A) * R, CY + Sin(A) * R * 0.45, 2 + K * 2, 2 + K * 2,
         ColMix(Col(120, 140, 255, 160), Col(255, 200, 120, 255), K));
  end;
  { accretion disk }
  Ring(CX, CY, 150, 42, 14, Col(255, 150, 60, 110), 0, 2 * Pi, -0.15, 48);
  Ring(CX, CY, 120, 32, 8, Col(255, 220, 140, 150), 0, 2 * Pi, -0.15, 48);
  { event horizon with a pulsing photon ring }
  Glow(CX, CY, 90, 90, Col(255, 160, 255, CB(60 + 30 * Sin(T * 2))));
  Ellipse(CX, CY, 52, 52, Col(0, 0, 0), 40);
  Ring(CX, CY, 56, 56, 3, Col(255, 220, 255, 200), 0, 2 * Pi, 0, 40);
  { front part of the disk passes in front of the hole }
  Ring(CX, CY, 150, 42, 14, Col(255, 170, 80, 160), 0.15, Pi - 0.15, -0.15, 30);
end;

procedure BgDraw(Flash: Single);
begin
  DrawOffX := 0;
  DrawOffY := 0;
  case CurKind of
    bgStarfield:   DrawStarfield;
    bgNebula:      DrawNebula;
    bgWarp:        DrawWarp;
    bgOcean:       DrawOcean;
    bgSynthCity:   DrawSynthCity;
    bgCrystalCave: DrawCrystalCave;
    bgAurora:      DrawAurora;
    bgMatrix:      DrawMatrix;
    bgLava:        DrawLava;
    bgBlackHole:   DrawBlackHole;
  end;
  if Flash > 0 then
    Rect(0, 0, SW, SH, Col(255, 255, 255, CB(Flash * 28)));
end;

end.
