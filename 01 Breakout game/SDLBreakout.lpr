program SDLBreakout;

{ Breakout clone using SDL3 + Free Pascal / Lazarus.
  Bindings: https://github.com/PascalGameDevelopment/SDL3-for-Pascal
  Controls: Left/Right or A/D or mouse = move paddle
            Space / click = launch ball, P = pause,
            R = restart, Esc = quit }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, Math, SDL3;

const
  ScreenW = 800;
  ScreenH = 600;

  BrickRows = 6;
  BrickCols = 10;
  BrickW    = 70;
  BrickH    = 22;
  BrickGap  = 6;
  BrickTop  = 70;
  BrickLeft = (ScreenW - (BrickCols * BrickW + (BrickCols - 1) * BrickGap)) div 2;

  PaddleW     = 110;
  PaddleH     = 14;
  PaddleY     = ScreenH - 40;
  PaddleSpeed = 620.0;

  BallSize       = 10;
  BallStartSpeed = 360.0;
  BallMaxSpeed   = 760.0;

  StartLives = 3;
  PhysStep   = 1.0 / 240.0;   { fixed physics step (seconds) }

  RowColors: array[0..BrickRows - 1, 0..2] of Byte = (
    (235,  75,  85),
    (245, 145,  60),
    (240, 210,  70),
    ( 90, 200, 110),
    ( 70, 160, 235),
    (150, 110, 230));

type
  TGameState = (gsServe, gsPlaying, gsPaused, gsGameOver, gsWon);

var
  Window: PSDL_Window = nil;
  Renderer: PSDL_Renderer = nil;

  Bricks: array[0..BrickRows - 1, 0..BrickCols - 1] of Boolean;
  BricksLeft: Integer;

  PaddleX: Single;
  BallX, BallY, BallVX, BallVY: Single;

  Score, Lives: Integer;
  State: TGameState;
  LeftDown, RightDown, Running: Boolean;

{ ---------- helpers ---------- }

function MakeRect(X, Y, W, H: Single): TSDL_FRect;
begin
  Result.x := X; Result.y := Y; Result.w := W; Result.h := H;
end;

function Overlaps(const A, B: TSDL_FRect): Boolean;
begin
  Result := (A.x < B.x + B.w) and (A.x + A.w > B.x) and
            (A.y < B.y + B.h) and (A.y + A.h > B.y);
end;

function BrickRect(R, C: Integer): TSDL_FRect;
begin
  Result := MakeRect(BrickLeft + C * (BrickW + BrickGap),
                     BrickTop + R * (BrickH + BrickGap), BrickW, BrickH);
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

{ ---------- game logic ---------- }

procedure ServeBall;
begin
  State := gsServe;
  BallVX := 0;
  BallVY := 0;
end;

procedure NewGame;
var
  R, C: Integer;
begin
  for R := 0 to BrickRows - 1 do
    for C := 0 to BrickCols - 1 do
      Bricks[R, C] := True;
  BricksLeft := BrickRows * BrickCols;
  Score := 0;
  Lives := StartLives;
  PaddleX := (ScreenW - PaddleW) / 2;
  ServeBall;
end;

procedure LaunchBall;
var
  Angle: Single;
begin
  { random angle within +/- ~30 degrees of straight up }
  Angle := (Random - 0.5) * 1.0;
  BallVX := BallStartSpeed * Sin(Angle);
  BallVY := -BallStartSpeed * Cos(Angle);
  State := gsPlaying;
end;

procedure StepBall(DT: Single);
var
  Ball, Paddle, B: TSDL_FRect;
  R, C: Integer;
  Hit, Speed, Angle: Single;
  OvL, OvR, OvT, OvB: Single;
begin
  BallX := BallX + BallVX * DT;
  BallY := BallY + BallVY * DT;

  { walls }
  if BallX < 0 then begin BallX := 0; BallVX := Abs(BallVX); end;
  if BallX + BallSize > ScreenW then begin BallX := ScreenW - BallSize; BallVX := -Abs(BallVX); end;
  if BallY < 0 then begin BallY := 0; BallVY := Abs(BallVY); end;

  { fell off the bottom }
  if BallY > ScreenH then
  begin
    Dec(Lives);
    if Lives <= 0 then State := gsGameOver else ServeBall;
    Exit;
  end;

  Ball := MakeRect(BallX, BallY, BallSize, BallSize);

  { paddle: bounce angle depends on where the ball hits }
  Paddle := MakeRect(PaddleX, PaddleY, PaddleW, PaddleH);
  if (BallVY > 0) and Overlaps(Ball, Paddle) then
  begin
    BallY := PaddleY - BallSize;
    Hit := ((BallX + BallSize / 2) - (PaddleX + PaddleW / 2)) / (PaddleW / 2);
    Hit := EnsureRange(Hit, -1.0, 1.0);
    Speed := Min(Single(Hypot(BallVX, BallVY) * 1.03), Single(BallMaxSpeed));
    Angle := Hit * 1.05;               { up to ~60 degrees }
    BallVX := Speed * Sin(Angle);
    BallVY := -Speed * Cos(Angle);
    Exit;
  end;

  { bricks: at most one hit per step }
  for R := 0 to BrickRows - 1 do
    for C := 0 to BrickCols - 1 do
      if Bricks[R, C] then
      begin
        B := BrickRect(R, C);
        if Overlaps(Ball, B) then
        begin
          Bricks[R, C] := False;
          Dec(BricksLeft);
          Inc(Score, (BrickRows - R) * 10);

          { reflect on the axis of smallest penetration }
          OvL := (Ball.x + Ball.w) - B.x;
          OvR := (B.x + B.w) - Ball.x;
          OvT := (Ball.y + Ball.h) - B.y;
          OvB := (B.y + B.h) - Ball.y;
          if Min(OvL, OvR) < Min(OvT, OvB) then
          begin
            if OvL < OvR then BallVX := -Abs(BallVX) else BallVX := Abs(BallVX);
          end
          else
          begin
            if OvT < OvB then BallVY := -Abs(BallVY) else BallVY := Abs(BallVY);
          end;

          if BricksLeft = 0 then State := gsWon;
          Exit;
        end;
      end;
end;

procedure Update(DT: Single);
begin
  if State in [gsPaused, gsGameOver, gsWon] then Exit;

  if LeftDown then PaddleX := PaddleX - PaddleSpeed * DT;
  if RightDown then PaddleX := PaddleX + PaddleSpeed * DT;
  PaddleX := EnsureRange(PaddleX, 0.0, ScreenW - PaddleW);

  if State = gsServe then
  begin
    BallX := PaddleX + (PaddleW - BallSize) / 2;
    BallY := PaddleY - BallSize - 1;
    Exit;
  end;

  { fixed sub-steps so a fast ball never tunnels through a brick }
  while (DT > 0) and (State = gsPlaying) do
  begin
    StepBall(Min(DT, Single(PhysStep)));
    DT := DT - PhysStep;
  end;
end;

{ ---------- input ---------- }

procedure HandleKey(Key: TSDL_Keycode; Down: Boolean);
begin
  case Key of
    SDLK_LEFT, SDLK_A:  LeftDown := Down;
    SDLK_RIGHT, SDLK_D: RightDown := Down;
  end;
  if not Down then Exit;

  case Key of
    SDLK_ESCAPE: Running := False;
    SDLK_SPACE, SDLK_RETURN:
      case State of
        gsServe: LaunchBall;
        gsGameOver, gsWon: NewGame;
      end;
    SDLK_P:
      if State = gsPlaying then State := gsPaused
      else if State = gsPaused then State := gsPlaying;
    SDLK_R: NewGame;
  end;
end;

procedure HandleEvents;
var
  Ev: TSDL_Event;
begin
  while SDL_PollEvent(@Ev) do
  begin
    { map mouse coords from window space to our 800x600 logical space }
    SDL_ConvertEventToRenderCoordinates(Renderer, @Ev);
    case Ev._type of
      SDL_EVENT_QUIT:
        Running := False;
      SDL_EVENT_KEY_DOWN:
        if not Ev.key._repeat then HandleKey(Ev.key.key, True);
      SDL_EVENT_KEY_UP:
        HandleKey(Ev.key.key, False);
      SDL_EVENT_MOUSE_MOTION:
        if State in [gsServe, gsPlaying] then
          PaddleX := EnsureRange(Ev.motion.x - PaddleW / 2, 0.0, ScreenW - PaddleW);
      SDL_EVENT_MOUSE_BUTTON_DOWN:
        case State of
          gsServe: LaunchBall;
          gsGameOver, gsWon: NewGame;
        end;
      SDL_EVENT_WINDOW_FOCUS_LOST:
        if State = gsPlaying then State := gsPaused;
    end;
  end;
end;

{ ---------- drawing ---------- }

procedure FillRect(const R: TSDL_FRect; Red, Green, Blue: Byte; Alpha: Byte = 255);
begin
  SDL_SetRenderDrawColor(Renderer, Red, Green, Blue, Alpha);
  SDL_RenderFillRect(Renderer, @R);
end;

{ SDL3's built-in 8x8 debug font, scaled up }
procedure DrawText(X, Y: Single; const S: AnsiString; Scale: Single = 2.0);
begin
  SDL_SetRenderScale(Renderer, Scale, Scale);
  SDL_SetRenderDrawColor(Renderer, 240, 240, 245, 255);
  SDL_RenderDebugText(Renderer, X / Scale, Y / Scale, PAnsiChar(S));
  SDL_SetRenderScale(Renderer, 1.0, 1.0);
end;

procedure DrawCentered(Y: Single; const S: AnsiString; Scale: Single = 2.0);
begin
  DrawText((ScreenW - Length(S) * 8 * Scale) / 2, Y, S, Scale);
end;

procedure Render;
var
  R, C: Integer;
  Rc: TSDL_FRect;
begin
  SDL_SetRenderDrawColor(Renderer, 18, 20, 32, 255);
  SDL_RenderClear(Renderer);

  { bricks with a simple highlight strip }
  for R := 0 to BrickRows - 1 do
    for C := 0 to BrickCols - 1 do
      if Bricks[R, C] then
      begin
        Rc := BrickRect(R, C);
        FillRect(Rc, RowColors[R, 0], RowColors[R, 1], RowColors[R, 2]);
        FillRect(MakeRect(Rc.x, Rc.y, Rc.w, 4), 255, 255, 255, 70);
      end;

  { paddle and ball }
  FillRect(MakeRect(PaddleX, PaddleY, PaddleW, PaddleH), 220, 225, 240);
  FillRect(MakeRect(BallX, BallY, BallSize, BallSize), 255, 255, 255);

  { HUD }
  DrawText(16, 20, 'SCORE ' + IntToStr(Score));
  DrawText(ScreenW - 16 - 9 * 16, 20, 'LIVES ' + IntToStr(Lives));

  { overlays }
  if State in [gsPaused, gsGameOver, gsWon] then
    FillRect(MakeRect(0, 0, ScreenW, ScreenH), 0, 0, 0, 150);

  case State of
    gsServe:    DrawCentered(ScreenH / 2 + 60, 'SPACE or CLICK to launch');
    gsPaused:   DrawCentered(ScreenH / 2 - 8, 'PAUSED - press P', 3);
    gsGameOver:
      begin
        DrawCentered(ScreenH / 2 - 40, 'GAME OVER', 4);
        DrawCentered(ScreenH / 2 + 20, 'Final score ' + IntToStr(Score));
        DrawCentered(ScreenH / 2 + 50, 'SPACE to play again');
      end;
    gsWon:
      begin
        DrawCentered(ScreenH / 2 - 40, 'YOU WIN!', 4);
        DrawCentered(ScreenH / 2 + 20, 'Score ' + IntToStr(Score));
        DrawCentered(ScreenH / 2 + 50, 'SPACE to play again');
      end;
  end;

  SDL_RenderPresent(Renderer);
end;

{ ---------- main ---------- }

var
  LastTicks, NowTicks: UInt64;
  DT: Single;

begin
  Randomize;

  if not SDL_Init(SDL_INIT_VIDEO) then
    Fatal('SDL_Init failed');

  if not SDL_CreateWindowAndRenderer('SDL3 Breakout (Lazarus)', ScreenW, ScreenH,
                                     SDL_WINDOW_RESIZABLE, @Window, @Renderer) then
    Fatal('Could not create window/renderer');

  { fixed 800x600 game space, scaled to any window size }
  SDL_SetRenderLogicalPresentation(Renderer, ScreenW, ScreenH, SDL_LOGICAL_PRESENTATION_LETTERBOX);
  SDL_SetRenderDrawBlendMode(Renderer, SDL_BLENDMODE_BLEND);
  SDL_SetRenderVSync(Renderer, 1);

  NewGame;
  Running := True;
  LastTicks := SDL_GetTicks;

  while Running do
  begin
    NowTicks := SDL_GetTicks;
    DT := Min(Single((NowTicks - LastTicks) / 1000.0), Single(0.05));  { clamp after stalls }
    LastTicks := NowTicks;

    HandleEvents;
    Update(DT);
    Render;

    SDL_Delay(1);  { be nice if vsync is unavailable }
  end;

  SDL_DestroyRenderer(Renderer);
  SDL_DestroyWindow(Window);
  SDL_Quit;
end.
