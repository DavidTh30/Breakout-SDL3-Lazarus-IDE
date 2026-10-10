unit GameDraw;

{ Shape drawing on top of SDL_RenderGeometry: gradients, ellipses, rings,
  polygons, rounded rectangles and thick lines. Every brick style and
  background is built from these.

  DrawOffX / DrawOffY are added to every coordinate (used for screen shake). }

{$mode objfpc}{$H+}

interface

uses
  SDL3;

type
  TCol = record
    R, G, B, A: Byte;
  end;

var
  DrawOffX: Single = 0;
  DrawOffY: Single = 0;

procedure DrawInit(ARenderer: PSDL_Renderer);

function Col(R, G, B: Byte; A: Byte = 255): TCol;
function ColHex(RGB: Cardinal; A: Byte = 255): TCol;
function ColScale(const C: TCol; K: Single): TCol;        { brighter > 1 > darker }
function ColMix(const A, B: TCol; T: Single): TCol;       { 0 = A, 1 = B }
function ColAlpha(const C: TCol; K: Single): TCol;        { multiply alpha }

procedure Rect(X, Y, W, H: Single; const C: TCol);
procedure RectGrad(X, Y, W, H: Single; const Top, Bottom: TCol);
procedure RectGradH(X, Y, W, H: Single; const Left, Right: TCol);
procedure RectOutline(X, Y, W, H, Thick: Single; const C: TCol);
procedure Tri(X1, Y1, X2, Y2, X3, Y3: Single; const C1, C2, C3: TCol);
procedure Quad(X1, Y1, X2, Y2, X3, Y3, X4, Y4: Single; const C: TCol);
procedure Line(X1, Y1, X2, Y2, Thick: Single; const C: TCol);
procedure Ellipse(CX, CY, RX, RY: Single; const C: TCol; Seg: Integer = 24);
procedure EllipseGrad(CX, CY, RX, RY: Single; const Inner, Outer: TCol; Seg: Integer = 24);
procedure Glow(CX, CY, RX, RY: Single; const C: TCol);    { soft light blob }
procedure Ring(CX, CY, RX, RY, Thick: Single; const C: TCol;
               A0: Single = 0; A1: Single = 6.2832; Tilt: Single = 0; Seg: Integer = 32);
procedure Poly(const Pts: array of TSDL_FPoint; const C: TCol);
procedure PolyGrad(const Pts: array of TSDL_FPoint; const Center, Edge: TCol);
procedure RoundRect(X, Y, W, H, Rad: Single; const C: TCol);
procedure RoundRectGrad(X, Y, W, H, Rad: Single; const Top, Bottom: TCol);
procedure Star(CX, CY, R: Single; const C: TCol);          { 4-point sparkle }

function FPt(X, Y: Single): TSDL_FPoint;

implementation

const
  MaxVerts = 1536;

var
  Renderer: PSDL_Renderer = nil;
  Buf: array[0..MaxVerts - 1] of TSDL_Vertex;
  Count: Integer = 0;

procedure DrawInit(ARenderer: PSDL_Renderer);
begin
  Renderer := ARenderer;
end;

function Col(R, G, B: Byte; A: Byte): TCol;
begin
  Result.R := R; Result.G := G; Result.B := B; Result.A := A;
end;

function ColHex(RGB: Cardinal; A: Byte): TCol;
begin
  Result := Col((RGB shr 16) and $FF, (RGB shr 8) and $FF, RGB and $FF, A);
end;

function Clamp255(V: Single): Byte;
begin
  if V < 0 then Result := 0
  else if V > 255 then Result := 255
  else Result := Round(V);
end;

function ColScale(const C: TCol; K: Single): TCol;
begin
  if K <= 1 then
    Result := Col(Clamp255(C.R * K), Clamp255(C.G * K), Clamp255(C.B * K), C.A)
  else     { brighten towards white }
    Result := Col(Clamp255(C.R + (255 - C.R) * (K - 1)),
                  Clamp255(C.G + (255 - C.G) * (K - 1)),
                  Clamp255(C.B + (255 - C.B) * (K - 1)), C.A);
end;

function ColMix(const A, B: TCol; T: Single): TCol;
begin
  Result := Col(Clamp255(A.R + (B.R - A.R) * T), Clamp255(A.G + (B.G - A.G) * T),
                Clamp255(A.B + (B.B - A.B) * T), Clamp255(A.A + (B.A - A.A) * T));
end;

function ColAlpha(const C: TCol; K: Single): TCol;
begin
  Result := C;
  Result.A := Clamp255(C.A * K);
end;

function FPt(X, Y: Single): TSDL_FPoint;
begin
  Result.x := X;
  Result.y := Y;
end;

{ ---------- vertex buffer ---------- }

procedure Flush;
begin
  if (Count > 0) and (Renderer <> nil) then
    SDL_RenderGeometry(Renderer, nil, @Buf[0], Count, nil, 0);
  Count := 0;
end;

procedure V(X, Y: Single; const C: TCol);
begin
  if Count >= MaxVerts then Flush;
  Buf[Count].position.x := X + DrawOffX;
  Buf[Count].position.y := Y + DrawOffY;
  Buf[Count].color.r := C.R / 255;
  Buf[Count].color.g := C.G / 255;
  Buf[Count].color.b := C.B / 255;
  Buf[Count].color.a := C.A / 255;
  Buf[Count].tex_coord.x := 0;
  Buf[Count].tex_coord.y := 0;
  Inc(Count);
end;

{ one triangle; flushes first if it would not fit, so triangles never split }
procedure T3(X1, Y1: Single; const C1: TCol; X2, Y2: Single; const C2: TCol;
             X3, Y3: Single; const C3: TCol);
begin
  if Count + 3 > MaxVerts then Flush;
  V(X1, Y1, C1);
  V(X2, Y2, C2);
  V(X3, Y3, C3);
end;

{ ---------- shapes ---------- }

procedure Tri(X1, Y1, X2, Y2, X3, Y3: Single; const C1, C2, C3: TCol);
begin
  T3(X1, Y1, C1, X2, Y2, C2, X3, Y3, C3);
  Flush;
end;

procedure Quad(X1, Y1, X2, Y2, X3, Y3, X4, Y4: Single; const C: TCol);
begin
  T3(X1, Y1, C, X2, Y2, C, X3, Y3, C);
  T3(X1, Y1, C, X3, Y3, C, X4, Y4, C);
  Flush;
end;

procedure RectGrad(X, Y, W, H: Single; const Top, Bottom: TCol);
begin
  if (W <= 0) or (H <= 0) then Exit;
  T3(X, Y, Top, X + W, Y, Top, X + W, Y + H, Bottom);
  T3(X, Y, Top, X + W, Y + H, Bottom, X, Y + H, Bottom);
  Flush;
end;

procedure RectGradH(X, Y, W, H: Single; const Left, Right: TCol);
begin
  if (W <= 0) or (H <= 0) then Exit;
  T3(X, Y, Left, X + W, Y, Right, X + W, Y + H, Right);
  T3(X, Y, Left, X + W, Y + H, Right, X, Y + H, Left);
  Flush;
end;

procedure Rect(X, Y, W, H: Single; const C: TCol);
begin
  RectGrad(X, Y, W, H, C, C);
end;

procedure RectOutline(X, Y, W, H, Thick: Single; const C: TCol);
begin
  Rect(X, Y, W, Thick, C);
  Rect(X, Y + H - Thick, W, Thick, C);
  Rect(X, Y + Thick, Thick, H - 2 * Thick, C);
  Rect(X + W - Thick, Y + Thick, Thick, H - 2 * Thick, C);
end;

procedure Line(X1, Y1, X2, Y2, Thick: Single; const C: TCol);
var
  DX, DY, L, NX, NY: Single;
begin
  DX := X2 - X1;
  DY := Y2 - Y1;
  L := Sqrt(DX * DX + DY * DY);
  if L < 0.001 then Exit;
  NX := -DY / L * Thick / 2;
  NY := DX / L * Thick / 2;
  Quad(X1 + NX, Y1 + NY, X2 + NX, Y2 + NY, X2 - NX, Y2 - NY, X1 - NX, Y1 - NY, C);
end;

procedure EllipseGrad(CX, CY, RX, RY: Single; const Inner, Outer: TCol; Seg: Integer);
var
  I: Integer;
  A0, A1: Single;
begin
  if (RX <= 0) or (RY <= 0) then Exit;
  if Seg < 6 then Seg := 6;
  for I := 0 to Seg - 1 do
  begin
    A0 := I * 2 * Pi / Seg;
    A1 := (I + 1) * 2 * Pi / Seg;
    T3(CX, CY, Inner, CX + Cos(A0) * RX, CY + Sin(A0) * RY, Outer,
       CX + Cos(A1) * RX, CY + Sin(A1) * RY, Outer);
  end;
  Flush;
end;

procedure Ellipse(CX, CY, RX, RY: Single; const C: TCol; Seg: Integer);
begin
  EllipseGrad(CX, CY, RX, RY, C, C, Seg);
end;

procedure Glow(CX, CY, RX, RY: Single; const C: TCol);
begin
  EllipseGrad(CX, CY, RX, RY, C, ColAlpha(C, 0), 20);
end;

procedure Ring(CX, CY, RX, RY, Thick: Single; const C: TCol;
               A0: Single; A1: Single; Tilt: Single; Seg: Integer);
var
  I: Integer;
  A, B, CT, ST: Single;
  OX1, OY1, IX1, IY1, OX2, OY2, IX2, IY2: Single;

  procedure P(Ang, RadX, RadY: Single; out PX, PY: Single);
  var
    EX, EY: Single;
  begin
    EX := Cos(Ang) * RadX;
    EY := Sin(Ang) * RadY;
    PX := CX + EX * CT - EY * ST;     { rotate the ellipse by Tilt }
    PY := CY + EX * ST + EY * CT;
  end;

begin
  if Seg < 4 then Seg := 4;
  CT := Cos(Tilt);
  ST := Sin(Tilt);
  for I := 0 to Seg - 1 do
  begin
    A := A0 + (A1 - A0) * I / Seg;
    B := A0 + (A1 - A0) * (I + 1) / Seg;
    P(A, RX, RY, OX1, OY1);
    P(A, RX - Thick, RY - Thick * RY / RX, IX1, IY1);
    P(B, RX, RY, OX2, OY2);
    P(B, RX - Thick, RY - Thick * RY / RX, IX2, IY2);
    T3(OX1, OY1, C, OX2, OY2, C, IX2, IY2, C);
    T3(OX1, OY1, C, IX2, IY2, C, IX1, IY1, C);
  end;
  Flush;
end;

procedure PolyGrad(const Pts: array of TSDL_FPoint; const Center, Edge: TCol);
var
  I, N: Integer;
  CX, CY: Single;
begin
  N := Length(Pts);
  if N < 3 then Exit;
  CX := 0; CY := 0;
  for I := 0 to N - 1 do
  begin
    CX := CX + Pts[I].x;
    CY := CY + Pts[I].y;
  end;
  CX := CX / N;
  CY := CY / N;
  for I := 0 to N - 1 do
    T3(CX, CY, Center, Pts[I].x, Pts[I].y, Edge,
       Pts[(I + 1) mod N].x, Pts[(I + 1) mod N].y, Edge);
  Flush;
end;

procedure Poly(const Pts: array of TSDL_FPoint; const C: TCol);
begin
  PolyGrad(Pts, C, C);
end;

{ rounded rectangle as a convex outline of 4 quarter-circle corners }
procedure RoundRectPts(X, Y, W, H, Rad: Single; var Pts: array of TSDL_FPoint);
const
  Steps = 5;
var
  Corner, I, N: Integer;
  CX, CY, A: Single;
begin
  if Rad > W / 2 then Rad := W / 2;
  if Rad > H / 2 then Rad := H / 2;
  N := 0;
  for Corner := 0 to 3 do
  begin
    case Corner of
      0: begin CX := X + W - Rad; CY := Y + Rad;     end;   { top right }
      1: begin CX := X + W - Rad; CY := Y + H - Rad; end;   { bottom right }
      2: begin CX := X + Rad;     CY := Y + H - Rad; end;   { bottom left }
    else
      begin CX := X + Rad;     CY := Y + Rad;     end;      { top left }
    end;
    for I := 0 to Steps do
    begin
      A := -Pi / 2 + Corner * Pi / 2 + I * (Pi / 2) / Steps;
      Pts[N] := FPt(CX + Cos(A) * Rad, CY + Sin(A) * Rad);
      Inc(N);
    end;
  end;
end;

procedure RoundRect(X, Y, W, H, Rad: Single; const C: TCol);
var
  Pts: array[0..23] of TSDL_FPoint;
begin
  if (W <= 0) or (H <= 0) then Exit;
  RoundRectPts(X, Y, W, H, Rad, Pts);
  Poly(Pts, C);
end;

procedure RoundRectGrad(X, Y, W, H, Rad: Single; const Top, Bottom: TCol);
var
  Pts: array[0..23] of TSDL_FPoint;
  I: Integer;
  K, CX, CY: Single;
  C0, C1, CC: TCol;
begin
  if (W <= 0) or (H <= 0) then Exit;
  RoundRectPts(X, Y, W, H, Rad, Pts);
  CX := X + W / 2;
  CY := Y + H / 2;
  CC := ColMix(Top, Bottom, 0.5);
  for I := 0 to 23 do
  begin
    K := (Pts[I].y - Y) / H;
    C0 := ColMix(Top, Bottom, K);
    K := (Pts[(I + 1) mod 24].y - Y) / H;
    C1 := ColMix(Top, Bottom, K);
    T3(CX, CY, CC, Pts[I].x, Pts[I].y, C0, Pts[(I + 1) mod 24].x, Pts[(I + 1) mod 24].y, C1);
  end;
  Flush;
end;

procedure Star(CX, CY, R: Single; const C: TCol);
var
  Clear: TCol;
begin
  Clear := ColAlpha(C, 0);
  T3(CX, CY - R, Clear, CX + R * 0.18, CY, C, CX - R * 0.18, CY, C);
  T3(CX, CY + R, Clear, CX + R * 0.18, CY, C, CX - R * 0.18, CY, C);
  T3(CX - R, CY, Clear, CX, CY + R * 0.18, C, CX, CY - R * 0.18, C);
  T3(CX + R, CY, Clear, CX, CY + R * 0.18, C, CX, CY - R * 0.18, C);
  Flush;
end;

end.
