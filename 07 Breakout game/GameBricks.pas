unit GameBricks;

{ Brick data and brick drawing.
  Every brick has a STYLE (its shape/look, set per level) and a KIND
  (its behaviour: tough, steel, explosive, gold, moving, ghost, electric).
  DrawBrick draws the style's shape, then the kind's overlay on top. }

{$mode objfpc}{$H+}
{$Q-}{$R-}   { the lightning zig-zag uses integer wrap-around }

interface

uses
  SDL3, GameLevels, GameDraw;

type
  TBrick = record
    Alive: Boolean;
    Kind: TBrickKind;
    Style: TBrickStyle;
    HP, MaxHP: Integer;
    X, Y, W, H: Single;        { home position }
    OffX: Single;              { current slide offset (moving bricks) }
    MoveAmp, MoveSpeed: Single;
    R, G, B: Byte;             { base color }
    Flash: Single;             { white flash after a hit, 1 -> 0 }
    Squash: Single;            { wobble after a hit, 1 -> 0 }
    Phase: Single;             { random, so bricks don't animate in sync }
    Spawn: Single;             { 0..1 fly-in progress at level start }
    SpawnDelay: Single;
    Row, Col: Integer;
    PendingT: Single;          { chain reaction: damage arrives after this delay }
    PendingDmg: Integer;
    PendingOwner: Integer;     { who gets the points: 0 = you, 1 = bot }
  end;

var
  { cartoon eyes look at this point (the ball) }
  LookX: Single = 400;
  LookY: Single = 500;

function BrickCurRect(const B: TBrick): TSDL_FRect;
function GhostAlpha(const B: TBrick; Time: Single): Single;
function GhostSolid(const B: TBrick; Time: Single): Boolean;
function BrickColor(const B: TBrick): TCol;
procedure DrawBrick(const B: TBrick; Time: Single);
procedure DrawShape(Style: TBrickStyle; X, Y, W, H: Single; const C: TCol;
                    Time, Phase: Single; Detail: Boolean);
procedure DrawBolt(X1, Y1, X2, Y2: Single; Seed: Integer; const C: TCol);

implementation

uses
  Math;

function ClampB(V: Single): Byte;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Round(V);
end;

function MinF(A, B: Single): Single;
begin
  if A < B then Result := A else Result := B;
end;

function BrickCurRect(const B: TBrick): TSDL_FRect;
begin
  Result.x := B.X + B.OffX;
  Result.y := B.Y;
  Result.w := B.W;
  Result.h := B.H;
end;

function GhostAlpha(const B: TBrick; Time: Single): Single;
begin
  if B.Kind <> bkGhost then Exit(1);
  Result := 0.575 + 0.425 * Sin(Time * 1.7 + B.Phase * 6);
end;

function GhostSolid(const B: TBrick; Time: Single): Boolean;
begin
  Result := GhostAlpha(B, Time) > 0.4;
end;

function BrickColor(const B: TBrick): TCol;
begin
  case B.Kind of
    bkSteel:     Result := Col(165, 175, 192);
    bkExplosive: Result := Col(255, 96, 40);
    bkGold:      Result := Col(255, 200, 60);
    bkGhost:     Result := Col(185, 150, 255);
    bkElectric:  Result := Col(80, 225, 255);
    bkTough:     Result := ColScale(Col(B.R, B.G, B.B), 0.82);
    bkArmored:   Result := ColScale(Col(B.R, B.G, B.B), 0.68);
  else
    Result := Col(B.R, B.G, B.B);
  end;
end;

{ ---------- shapes for each style ---------- }

procedure DrawShape(Style: TBrickStyle; X, Y, W, H: Single; const C: TCol;
                    Time, Phase: Single; Detail: Boolean);
var
  CX, CY, PR, RX, RY, Tilt, K, EX, EY, DX, DY, L, S: Single;
  Pts: array[0..5] of TSDL_FPoint;
  White, Dark: TCol;
  I: Integer;
begin
  CX := X + W / 2;
  CY := Y + H / 2;
  White := Col(255, 255, 255, C.A);
  Dark := ColScale(C, 0.35);

  case Style of
    lsClassic:
      begin
        RectGrad(X, Y, W, H, ColScale(C, 1.08), ColScale(C, 0.85));
        if Detail then
        begin
          Rect(X, Y, W, 4, ColAlpha(White, 0.25 + 0.2 * Sin(Time * 3 + Phase * 6)));
          Rect(X, Y + H - 3, W, 3, Col(0, 0, 0, C.A div 4));
        end;
      end;

    lsCartoon:
      begin
        RoundRect(X - 2, Y - 2, W + 4, H + 4, 10, Dark);                      { ink outline }
        RoundRectGrad(X, Y, W, H, 8, ColScale(C, 1.25), ColScale(C, 0.88));
        if Detail then
        begin
          Ellipse(X + W * 0.27, Y + H * 0.28, W * 0.14, H * 0.13, ColAlpha(White, 0.6), 12);
          { googly eyes that follow the ball }
          DX := LookX - CX;
          DY := LookY - CY;
          L := Sqrt(DX * DX + DY * DY);
          if L < 1 then L := 1;
          EX := DX / L * H * 0.07;
          EY := DY / L * H * 0.07;
          for I := 0 to 1 do
          begin
            K := CX + (I * 2 - 1) * W * 0.13;
            Ellipse(K, CY + H * 0.05, H * 0.17, H * 0.2, White, 12);
            Ellipse(K + EX, CY + H * 0.05 + EY, H * 0.08, H * 0.09, Col(30, 20, 40, C.A), 10);
          end;
        end;
      end;

    lsSaturn:
      begin
        PR := Min(W, H) * 0.4;
        RX := W * 0.5;
        RY := H * 0.17;
        Tilt := -0.28 + 0.1 * Sin(Time * 0.8 + Phase * 6);
        if Detail then   { back half of the ring, behind the planet }
          Ring(CX, CY, RX, RY, 3, ColAlpha(ColMix(C, White, 0.5), 0.7), Pi, 2 * Pi, Tilt, 16);
        EllipseGrad(CX - PR * 0.25, CY - PR * 0.25, PR * 1.2, PR * 1.2, ColScale(C, 1.4), ColScale(C, 0.55), 20);
        if Detail then
        begin
          { planet bands }
          Ellipse(CX, CY - PR * 0.25, PR * 0.85, PR * 0.12, ColAlpha(ColScale(C, 0.7), 0.6), 12);
          Ellipse(CX, CY + PR * 0.2, PR * 0.9, PR * 0.1, ColAlpha(ColScale(C, 0.75), 0.5), 12);
          { front half of the ring }
          Ring(CX, CY, RX, RY, 3, ColMix(C, White, 0.55), 0, Pi, Tilt, 16);
        end;
      end;

    lsOval:
      begin
        EllipseGrad(CX, CY, W / 2, H / 2, ColScale(C, 1.3), ColScale(C, 0.72), 28);
        if Detail then
          Ellipse(CX - W * 0.1, Y + H * 0.28, W * 0.3, H * 0.12, ColAlpha(White, 0.45), 16);
      end;

    lsCyber:
      begin
        S := 0;
        if Detail and (Frac(Time * 0.37 + Phase) < 0.035) then S := 3;   { glitch }
        Rect(X + S, Y, W, H, Col(C.R div 6, C.G div 6, C.B div 6, ClampB(MinF(230, C.A))));
        if Detail then
          RectOutline(X - 3, Y - 3, W + 6, H + 6, 3, ColAlpha(C, 0.18 + 0.1 * Sin(Time * 4 + Phase * 6)));
        RectOutline(X + S, Y, W, H, 2, ColScale(C, 1.1));
        if Detail then
        begin
          if S > 0 then RectOutline(X - S, Y + 1, W, H, 1, Col(255, 40, 200, C.A));
          K := Frac(Time * 0.9 + Phase) * (H - 4);
          Rect(X + 3, Y + 2 + K, W - 6, 1.5, ColAlpha(C, 0.7));                 { scanline }
          Tri(X + W - 9, Y, X + W, Y, X + W, Y + 9, Dark, Dark, Dark);             { cut corner }
          Rect(X + 4, Y + H - 5, W * 0.3, 2, ColAlpha(C, 0.8));
        end;
      end;

    lsCrystal:
      begin
        Pts[0] := FPt(X, CY);
        Pts[1] := FPt(X + W * 0.2, Y);
        Pts[2] := FPt(X + W * 0.8, Y);
        Pts[3] := FPt(X + W, CY);
        Pts[4] := FPt(X + W * 0.8, Y + H);
        Pts[5] := FPt(X + W * 0.2, Y + H);
        PolyGrad(Pts, ColScale(C, 1.45), ColScale(C, 0.7));
        if Detail then
        begin
          Quad(X + W * 0.2, Y, X + W * 0.8, Y, X + W * 0.66, CY - H * 0.1, X + W * 0.34, CY - H * 0.1,
               ColAlpha(White, 0.35));
          Line(X + W * 0.34, CY - H * 0.1, X + W * 0.2, Y + H, 1, ColAlpha(White, 0.3));
          Line(X + W * 0.66, CY - H * 0.1, X + W * 0.8, Y + H, 1, ColAlpha(White, 0.3));
          K := Frac(Time * 0.35 + Phase);
          if K < 0.25 then
            Star(X + W * (0.25 + K * 2), Y + H * 0.3, 7 * Sin(K * 4 * Pi), ColAlpha(White, 0.95));
        end;
      end;

    lsHex:
      begin
        Pts[0] := FPt(CX, Y - H * 0.08);
        Pts[1] := FPt(X + W, Y + H * 0.22);
        Pts[2] := FPt(X + W, Y + H * 0.78);
        Pts[3] := FPt(CX, Y + H * 1.08);
        Pts[4] := FPt(X, Y + H * 0.78);
        Pts[5] := FPt(X, Y + H * 0.22);
        PolyGrad(Pts, ColScale(C, 1.2), ColScale(C, 0.72));
        if Detail then
        begin
          for I := 0 to 5 do
            Pts[I] := FPt(CX + (Pts[I].x - CX) * 0.55, CY + (Pts[I].y - CY) * 0.55);
          Poly(Pts, ColAlpha(ColScale(C, 1.45), 0.45 + 0.15 * Sin(Time * 2 + Phase * 6)));
        end;
      end;

    lsPixel:
      begin
        Rect(X, Y, W, H, ColScale(C, 0.45));
        Rect(X + 2, Y + 2, W - 4, H - 4, C);
        if Detail then
        begin
          Rect(X + 2, Y + 2, W - 4, 2, ColAlpha(White, 0.45));
          { a few "pixels" that blink on and off }
          for I := 0 to 2 do
            if Frac(Time * (0.7 + I * 0.3) + Phase + I * 0.31) < 0.5 then
              Rect(X + 4 + Frac(Phase * (I + 3) * 7) * (W - 12), Y + 5 + (I * 3) mod Max(1, Integer(Round(H - 9))),
                   3, 3, ColAlpha(ColScale(C, 1.5), 0.9));
        end;
      end;

  else { lsGlossy (and fallback) }
    begin
      if Detail then
        Glow(CX, CY, W * 0.7, H * 1.1, ColAlpha(C, 0.22 + 0.08 * Sin(Time * 2.5 + Phase * 6)));
      RoundRectGrad(X, Y, W, H, H * 0.45, ColScale(C, 1.35), ColScale(C, 0.55));
      if Detail then
      begin
        RoundRect(X + 4, Y + 2, W - 8, H * 0.38, H * 0.2, ColAlpha(White, 0.3));
        Ellipse(X + W * 0.22, Y + H * 0.3, 3, 2, ColAlpha(White, 0.9), 8);
      end;
    end;
  end;
end;

{ ---------- per-kind overlays ---------- }

procedure DrawCracks(X, Y, W, H: Single; Amount: Integer; Phase: Single; A: Byte);
var
  I, J: Integer;
  PX, PY, NX, NY, Seed: Single;
begin
  for I := 0 to Amount - 1 do
  begin
    Seed := Phase * 13 + I * 3.7;
    PX := X + W * (0.2 + 0.6 * Frac(Seed));
    PY := Y + 1;
    for J := 1 to 4 do
    begin
      NX := PX + (Frac(Seed * J * 1.37) - 0.5) * W * 0.25;
      NY := Y + H * J / 4;
      Line(PX, PY, NX, NY, 1.6, Col(20, 15, 25, A));
      PX := NX;
      PY := NY;
    end;
  end;
end;

procedure DrawBolt(X1, Y1, X2, Y2: Single; Seed: Integer; const C: TCol);
var
  I: Integer;
  PX, PY, NX, NY, T: Single;
  S: Cardinal;
begin
  S := Cardinal(Seed) * 2654435761;
  PX := X1;
  PY := Y1;
  for I := 1 to 6 do
  begin
    S := S * 1103515245 + 12345;
    T := I / 6;
    NX := X1 + (X2 - X1) * T;
    NY := Y1 + (Y2 - Y1) * T;
    if I < 6 then
    begin
      NX := NX + ((S shr 16) and $FF) / 255 * 8 - 4;
      NY := NY + ((S shr 8) and $FF) / 255 * 8 - 4;
    end;
    Line(PX, PY, NX, NY, 3, ColAlpha(C, 0.35));
    Line(PX, PY, NX, NY, 1.2, Col(255, 255, 255, C.A));
    PX := NX;
    PY := NY;
  end;
end;

procedure DrawBrick(const B: TBrick; Time: Single);
var
  X, Y, W, H, CX, CY, Alpha, K, Pulse: Single;
  C: TCol;
  I: Integer;
begin
  if (not B.Alive) or (B.Spawn <= 0) then Exit;

  { fly in from above at level start, wobble when hit }
  K := 1 - B.Spawn;
  W := B.W * (1 + 0.12 * B.Squash);
  H := B.H * (1 - 0.15 * B.Squash);
  X := B.X + B.OffX - (W - B.W) / 2;
  Y := B.Y - (H - B.H) / 2 - K * K * 320;
  CX := X + W / 2;
  CY := Y + H / 2;

  Alpha := MinF(1, B.Spawn * 1.5) * GhostAlpha(B, Time);
  C := ColAlpha(BrickColor(B), Alpha);

  { glows behind the brick }
  case B.Kind of
    bkExplosive:
      begin
        Pulse := 0.5 + 0.5 * Sin(Time * 7 + B.Phase * 6);
        Glow(CX, CY, W * 0.85, H * 1.3, Col(255, 120, 40, ClampB((50 + 70 * Pulse) * Alpha)));
      end;
    bkGold:
      Glow(CX, CY, W * 0.8, H * 1.2, Col(255, 210, 80, ClampB(60 * Alpha)));
    bkElectric:
      Glow(CX, CY, W * 0.8, H * 1.2, Col(80, 220, 255, ClampB((40 + 40 * Sin(Time * 11 + B.Phase * 6)) * Alpha)));
    bkGhost:
      Glow(CX, CY, W * 0.75, H * 1.2, Col(170, 130, 255, ClampB(50 * Alpha)));
    bkMoving:
      if Abs(B.MoveAmp) > 0 then   { motion trail }
        DrawShape(B.Style, X - Cos(Time * B.MoveSpeed + B.Phase * 6) * 10, Y, W, H,
                  ColAlpha(C, 0.25), Time, B.Phase, False);
  end;

  DrawShape(B.Style, X, Y, W, H, C, Time, B.Phase, True);

  { overlays }
  case B.Kind of
    bkTough, bkArmored:
      begin
        if B.HP < B.MaxHP then
          DrawCracks(X, Y, W, H, (B.MaxHP - B.HP) * 2, B.Phase, ClampB(220 * Alpha));
        if B.Kind = bkArmored then
        begin
          Ellipse(X + 5, Y + 5, 2, 2, Col(230, 230, 240, ClampB(200 * Alpha)), 6);
          Ellipse(X + W - 5, Y + 5, 2, 2, Col(230, 230, 240, ClampB(200 * Alpha)), 6);
          Ellipse(X + 5, Y + H - 5, 2, 2, Col(230, 230, 240, ClampB(200 * Alpha)), 6);
          Ellipse(X + W - 5, Y + H - 5, 2, 2, Col(230, 230, 240, ClampB(200 * Alpha)), 6);
        end;
        { hit points left as small pips }
        for I := 0 to B.HP - 1 do
          Rect(X + W - 8 - I * 6, Y + H - 6, 4, 3, Col(255, 255, 255, ClampB(170 * Alpha)));
      end;

    bkSteel:
      begin
        K := Frac(Time * 0.45 + B.Phase) * (W + 40) - 20;
        if (K > 2) and (K < W - 10) then
          Quad(X + K, Y + 2, X + K + 8, Y + 2, X + K + 4, Y + H - 2, X + K - 4, Y + H - 2,
               Col(255, 255, 255, ClampB(110 * Alpha)));
        Ellipse(X + 5, CY, 2, 2, Col(90, 95, 110, ClampB(255 * Alpha)), 6);
        Ellipse(X + W - 5, CY, 2, 2, Col(90, 95, 110, ClampB(255 * Alpha)), 6);
      end;

    bkExplosive:
      begin
        Ellipse(CX, CY, H * 0.26, H * 0.26, Col(25, 15, 15, ClampB(230 * Alpha)), 12);
        Pulse := 0.5 + 0.5 * Sin(Time * 9 + B.Phase * 6);
        Ellipse(CX, CY, H * 0.12, H * 0.12, Col(255, ClampB(60 + 150 * Pulse), 40, ClampB(255 * Alpha)), 10);
        Star(CX + H * 0.2, CY - H * 0.3, 5 + 3 * Pulse, Col(255, 230, 120, ClampB(255 * Alpha)));
      end;

    bkGold:
      begin
        for I := 0 to 1 do
        begin
          K := Frac(Time * 0.6 + B.Phase + I * 0.5);
          if K < 0.3 then
            Star(X + W * (0.2 + 0.6 * Frac(B.Phase * 7 + I * 0.37)), Y + H * (0.25 + 0.5 * I),
                 8 * Sin(K / 0.3 * Pi), Col(255, 255, 255, ClampB(255 * Alpha)));
        end;
      end;

    bkMoving:
      begin
        Tri(X + 3, CY, X + 9, CY - 5, X + 9, CY + 5,
            Col(255, 255, 255, ClampB(150 * Alpha)), Col(255, 255, 255, ClampB(150 * Alpha)),
            Col(255, 255, 255, ClampB(150 * Alpha)));
        Tri(X + W - 3, CY, X + W - 9, CY - 5, X + W - 9, CY + 5,
            Col(255, 255, 255, ClampB(150 * Alpha)), Col(255, 255, 255, ClampB(150 * Alpha)),
            Col(255, 255, 255, ClampB(150 * Alpha)));
      end;

    bkGhost:
      begin   { spooky eyes }
        Ellipse(CX - W * 0.12, CY, H * 0.11, H * 0.17, Col(30, 10, 50, ClampB(230 * Alpha)), 10);
        Ellipse(CX + W * 0.12, CY, H * 0.11, H * 0.17, Col(30, 10, 50, ClampB(230 * Alpha)), 10);
      end;

    bkElectric:
      DrawBolt(X + 4, CY + (Frac(B.Phase * 9) - 0.5) * H * 0.4, X + W - 4,
               CY - (Frac(B.Phase * 5) - 0.5) * H * 0.4,
               Trunc(Time * 14) + Round(B.Phase * 1000), Col(200, 245, 255, ClampB(255 * Alpha)));
  end;

  { white flash after a hit }
  if B.Flash > 0 then
    DrawShape(B.Style, X, Y, W, H, Col(255, 255, 255, ClampB(220 * B.Flash * Alpha)),
              Time, B.Phase, False);
end;

end.
