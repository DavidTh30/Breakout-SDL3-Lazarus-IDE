unit GameText;

{ TrueType text for the game, using SDL3_ttf.
  - Each string is rendered once to a texture and cached, then drawn with
    any color, alpha, scale and rotation (cheap enough for animations).
  - Fonts are rendered at 2x resolution so text stays sharp when the
    800x600 game is scaled up to a bigger window or fullscreen.
  - If no font can be loaded, it falls back to SDL's built-in 8x8 debug font. }

{$mode objfpc}{$H+}

interface

uses
  SDL3;

type
  TFontSize = (fsTiny, fsSmall, fsMedium, fsLarge, fsHuge);
  TAlign = (alLeft, alCenter, alRight);

procedure TextInit(ARenderer: PSDL_Renderer);
procedure TextShutdown;
function TextUsingTTF: Boolean;

{ (X, Y) is the anchor: Align picks left/center/right edge, Y is the
  vertical CENTER of the text, so scaling grows around the middle. }
procedure DrawStr(Size: TFontSize; const S: string; X, Y: Single;
                  Align: TAlign; R, G, B: Byte; A: Byte = 255;
                  Scale: Single = 1.0; Angle: Single = 0; Shadow: Boolean = True);

{ width of a string in game pixels at Scale = 1 }
function TextWidth(Size: TFontSize; const S: string): Single;

implementation

uses
  SysUtils, SDL3_ttf;

const
  FontPx: array[TFontSize] of Single = (14, 18, 26, 40, 72);
  Oversample = 2;
  CacheSize = 128;

  FontFile = 'RussoOne-Regular.ttf';

type
  TCacheEntry = record
    Used: Boolean;
    Size: TFontSize;
    Text: string;
    Tex: PSDL_Texture;
    W, H: Integer;          { texture size in real pixels }
    Stamp: QWord;
  end;

var
  Renderer: PSDL_Renderer = nil;
  Fonts: array[TFontSize] of PTTF_Font;
  HaveTTF: Boolean = False;
  Cache: array[0..CacheSize - 1] of TCacheEntry;
  Clock: QWord = 0;

function FindFontFile: string;
var
  Base: PAnsiChar;
  Candidates: array[0..4] of string;
  I: Integer;
begin
  Base := SDL_GetBasePath;          { folder of the .exe (owned by SDL, don't free) }
  if Base <> nil then Candidates[0] := string(Base) + 'fonts' + PathDelim + FontFile
  else Candidates[0] := '';
  Candidates[1] := 'fonts' + PathDelim + FontFile;
  Candidates[2] := FontFile;
  { fallbacks that exist on every Windows install }
  Candidates[3] := 'C:\Windows\Fonts\segoeuib.ttf';
  Candidates[4] := 'C:\Windows\Fonts\arialbd.ttf';

  for I := 0 to High(Candidates) do
    if (Candidates[I] <> '') and FileExists(Candidates[I]) then Exit(Candidates[I]);
  Result := '';
end;

procedure TextInit(ARenderer: PSDL_Renderer);
var
  Path: string;
  F: TFontSize;
begin
  Renderer := ARenderer;
  HaveTTF := False;
  if not TTF_Init then Exit;

  Path := FindFontFile;
  if Path = '' then Exit;

  for F := Low(TFontSize) to High(TFontSize) do
  begin
    Fonts[F] := TTF_OpenFont(PAnsiChar(AnsiString(Path)), FontPx[F] * Oversample);
    if Fonts[F] = nil then Exit;
    TTF_SetFontHinting(Fonts[F], TTF_HINTING_LIGHT);
  end;
  HaveTTF := True;
end;

procedure TextShutdown;
var
  I: Integer;
  F: TFontSize;
begin
  for I := 0 to CacheSize - 1 do
    if Cache[I].Used and (Cache[I].Tex <> nil) then
    begin
      SDL_DestroyTexture(Cache[I].Tex);
      Cache[I].Used := False;
    end;
  for F := Low(TFontSize) to High(TFontSize) do
    if Fonts[F] <> nil then
    begin
      TTF_CloseFont(Fonts[F]);
      Fonts[F] := nil;
    end;
  if HaveTTF then TTF_Quit;
  HaveTTF := False;
end;

function TextUsingTTF: Boolean;
begin
  Result := HaveTTF;
end;

{ find or create the texture for (Size, S); returns cache index or -1 }
function Lookup(Size: TFontSize; const S: string): Integer;
var
  I, Oldest: Integer;
  Surf: PSDL_Surface;
  White: TSDL_Color;
begin
  Inc(Clock);
  for I := 0 to CacheSize - 1 do
    if Cache[I].Used and (Cache[I].Size = Size) and (Cache[I].Text = S) then
    begin
      Cache[I].Stamp := Clock;
      Exit(I);
    end;

  { not cached: reuse a free slot or the least recently used one }
  Oldest := 0;
  for I := 0 to CacheSize - 1 do
  begin
    if not Cache[I].Used then begin Oldest := I; Break; end;
    if Cache[I].Stamp < Cache[Oldest].Stamp then Oldest := I;
  end;
  if Cache[Oldest].Used and (Cache[Oldest].Tex <> nil) then
    SDL_DestroyTexture(Cache[Oldest].Tex);
  Cache[Oldest].Used := False;

  White.r := 255; White.g := 255; White.b := 255; White.a := 255;
  Surf := TTF_RenderText_Blended(Fonts[Size], PAnsiChar(AnsiString(S)), Length(S), White);
  if Surf = nil then Exit(-1);

  Cache[Oldest].Tex := SDL_CreateTextureFromSurface(Renderer, Surf);
  Cache[Oldest].W := Surf^.w;
  Cache[Oldest].H := Surf^.h;
  SDL_DestroySurface(Surf);
  if Cache[Oldest].Tex = nil then Exit(-1);

  SDL_SetTextureScaleMode(Cache[Oldest].Tex, SDL_SCALEMODE_LINEAR);
  Cache[Oldest].Used := True;
  Cache[Oldest].Size := Size;
  Cache[Oldest].Text := S;
  Cache[Oldest].Stamp := Clock;
  Result := Oldest;
end;

function TextWidth(Size: TFontSize; const S: string): Single;
var
  I: Integer;
begin
  if S = '' then Exit(0);
  if not HaveTTF then Exit(Length(S) * FontPx[Size]);   { debug font: 8x8 cells }
  I := Lookup(Size, S);
  if I < 0 then Exit(0);
  Result := Cache[I].W / Oversample;
end;

procedure DrawDebugFallback(Size: TFontSize; const S: string; X, Y: Single;
                            Align: TAlign; R, G, B, A: Byte; Scale: Single);
var
  K, W: Single;
begin
  K := FontPx[Size] / 8 * Scale;
  W := Length(S) * 8 * K;
  case Align of
    alCenter: X := X - W / 2;
    alRight:  X := X - W;
  end;
  Y := Y - 4 * K;
  SDL_SetRenderScale(Renderer, K, K);
  SDL_SetRenderDrawColor(Renderer, R, G, B, A);
  SDL_RenderDebugText(Renderer, X / K, Y / K, PAnsiChar(AnsiString(S)));
  SDL_SetRenderScale(Renderer, 1, 1);
end;

procedure DrawStr(Size: TFontSize; const S: string; X, Y: Single;
                  Align: TAlign; R, G, B: Byte; A: Byte; Scale: Single;
                  Angle: Single; Shadow: Boolean);
var
  I: Integer;
  W, H: Single;
  Dst, Sh: TSDL_FRect;
begin
  if (S = '') or (A = 0) or (Scale <= 0) then Exit;
  if not HaveTTF then
  begin
    DrawDebugFallback(Size, S, X, Y, Align, R, G, B, A, Scale);
    Exit;
  end;

  I := Lookup(Size, S);
  if I < 0 then Exit;

  W := Cache[I].W / Oversample * Scale;
  H := Cache[I].H / Oversample * Scale;
  case Align of
    alLeft:   Dst.x := X;
    alCenter: Dst.x := X - W / 2;
  else
    Dst.x := X - W;
  end;
  Dst.y := Y - H / 2;
  Dst.w := W;
  Dst.h := H;

  if Shadow then
  begin
    Sh := Dst;
    Sh.x := Sh.x + 2 * Scale;
    Sh.y := Sh.y + 2 * Scale;
    SDL_SetTextureColorMod(Cache[I].Tex, 0, 0, 0);
    SDL_SetTextureAlphaMod(Cache[I].Tex, A * 6 div 10);
    if Angle <> 0 then
      SDL_RenderTextureRotated(Renderer, Cache[I].Tex, nil, @Sh, Angle, nil, SDL_FLIP_NONE)
    else
      SDL_RenderTexture(Renderer, Cache[I].Tex, nil, @Sh);
  end;

  SDL_SetTextureColorMod(Cache[I].Tex, R, G, B);
  SDL_SetTextureAlphaMod(Cache[I].Tex, A);
  if Angle <> 0 then
    SDL_RenderTextureRotated(Renderer, Cache[I].Tex, nil, @Dst, Angle, nil, SDL_FLIP_NONE)
  else
    SDL_RenderTexture(Renderer, Cache[I].Tex, nil, @Dst);
end;

end.
