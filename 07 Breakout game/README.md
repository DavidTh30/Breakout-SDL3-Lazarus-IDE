# SDL3 Breakout — Lazarus / Free Pascal (Windows 64-bit)

A complete Breakout game with 10 themed levels, solo or against a bot (3 difficulties), an animated menu, power-ups, TrueType text, synthesized music and sound, and saved high scores, built on SDL3's 2D renderer.

## Project files

```
SDLBreakout\
  SDLBreakout.lpi          project
  SDLBreakout.lpr          game flow, ball physics, brick hits + chain reactions, menu, HUD
  GameLevels.pas           the 10 level maps, brick sizes, styles, colors   <- edit to make levels
  GameBricks.pas           brick drawing: 10 styles x 9 brick types
  GameBackground.pas       10 animated backgrounds
  GameDraw.pas             shapes: gradients, ellipses, rings, polygons (SDL_RenderGeometry)
  GameAudio.pas            synthesized music + sound effects (plain SDL3 audio)
  GameText.pas             TrueType text via SDL3_ttf, with texture cache
  GameSave.pas             settings, high scores, unlocked levels, last cheat code (INI file)
  GameCheat.pas            cheat codes: next level, scores, lives and mode (solo / vs bot)
  fonts\RussoOne-Regular.ttf   game font (SIL Open Font License, see OFL-RussoOne.txt)
  SDL3.dll                 you copy this in
  SDL3_ttf.dll             you copy this in
```

## Setup — do these in order

### 1. Prepare Windows 64-bit
Everything must be 64-bit: Lazarus, the compiler target, and the DLLs.

### 2. Install SDL3 into Lazarus
1. Download the packages folder from
   https://github.com/sechshelme/Lazarus-SDL-3.0-Packages-and-Examples/tree/main/packages
2. Download the **64-bit** DLLs (`*-win32-x64.zip`):
   - SDL3 — https://github.com/libsdl-org/SDL/releases
   - **SDL3_ttf — https://github.com/libsdl-org/SDL_ttf/releases** (needed for the fonts)
   - SDL3_image / SDL3_mixer — optional, not used by this game
3. For a clean start, uninstall Lazarus and delete `C:\Lazarus` and `C:\Users\<you>\AppData\Local\lazarus`.
4. Install **Lazarus 64-bit**.
5. Copy the SDL3 packages to `C:\Lazarus\components\SDL3`.
6. **Package → Open Package File (.lpk)** → `sdl3_package.lpk` → **Use → Install**, allow the IDE rebuild ("make it fat" if it fails).

### 3. Build the game
1. Copy **`SDL3.dll`** and **`SDL3_ttf.dll`** (64-bit) into the project folder.
2. Keep the `fonts` folder next to the project (the exe is built in the same folder).
3. Open `SDLBreakout.lpi` and press **F9**.

If `SDL3_ttf.dll` is missing, Windows refuses to start the program ("SDL3_ttf.dll was not found").
If only the font file is missing, the game falls back to a Windows font (Segoe UI Bold / Arial Bold), and if no font loads at all it falls back to SDL's built-in pixel font.

sechshelme's package names event fields with a leading underscore (`Ev._type`, `Ev.key._repeat`); the source already uses those names.

## Controls

**Menu**

| Key | Action |
|---|---|
| ↑ ↓ / W S / mouse | Choose item |
| Enter / Space / click | Select (on options: cycle value) |
| ← → / A D | Change option value |
| Esc / Backspace | Back (on main menu: continue game) |
| F11 | Fullscreen on/off |

**Game**

| Key | Action |
|---|---|
| ← → / A D / mouse | Move paddle |
| Space / Enter / click | Launch ball, continue after level clear, play again after game over |
| C | Copy the cheat code (level-clear screen) |
| P | Pause |
| Esc | Open menu (Continue resumes) |
| M / N | Quick mute music / sound effects |
| F11 | Fullscreen on/off |

## Menu

- **New Game, Continue, Levels, High Scores, Graphics, Sound, Exit.** Levels shows all 10 levels; locked ones are greyed out, and the highlighted level shows its brick style and background. Continue is greyed out unless a game is in progress.
- **Graphics:** Fullscreen, VSync, Particles (Off / Low / High), Screen shake, Background (Animated / Static).
- **Sound:** Music volume and Effects volume (0–10 sliders).
- **Animations:** items slide in one after another; the selection bar glides between items; the chosen item grows, wobbles and turns gold; selecting an item makes it "punch", flash and throw sparks, with sound; the BREAKOUT title waves letter by letter.

## Levels

| # | Name | Brick style | Brick size | Background | New brick types |
|---|---|---|---|---|---|
| 1 | First Light | Classic | 70×22 | Starfield | tough, gold |
| 2 | Bubblegum Heart | Cartoon (googly eyes follow the ball) | 56×26 | Nebula | explosive |
| 3 | Ring World | Saturn (planet + tilting ring) | 46×34 | Warp speed | |
| 4 | Pill Factory | Oval | 62×24 | Ocean (rays, bubbles) | moving |
| 5 | Neon District | Cyberpunk (neon outline, glitch) | 62×22 | Synth city | steel, electric |
| 6 | Crystal Caverns | Crystal gem | 48×28 | Crystal cave | armored, ghost |
| 7 | Honeycomb | Hexagon, offset rows | 54×32 | Aurora | |
| 8 | Digital Rain | Pixel | 34×16 (187 bricks) | Matrix rain | |
| 9 | Lava Core | Glossy lava | 66×26 | Lava lamp | steel fortress |
| 10 | Event Horizon | Mixed (every style) | 52×26 | Black hole | all types |

Each level also has its own music key, tempo and lead tone, and the ball gets a little faster each level.
Clearing a level gives a bonus (250 × level + 100 × lives), unlocks the next one in the **LEVELS** menu, and shows a **cheat code** (see below). The level-clear screen waits for Space / click so you have time to note the code.
The first time a new brick type appears, the level intro explains it.

### Brick types

| Map char | Type | Behaviour | Effect |
|---|---|---|---|
| `#` | Normal | 1 hit | style-specific debris (shards, bubbles, pixels, comic "POW!") |
| `2` | Tough | 2 hits | cracks appear, HP pips, wobble + chips |
| `3` | Armored | 3 hits | rivets, deeper cracks |
| `S` | Steel | unbreakable, not needed to clear | metallic sheen, clang + sparks |
| `X` | Explosive | destroys neighbours; chains into other X | shockwave rings, fire, smoke, big shake |
| `G` | Gold | 100+ points, always drops a power-up | sparkles, coin burst |
| `M` | Moving | slides into empty cells beside it | motion trail, arrows |
| `H` | Ghost | ball passes through while faded | fades in/out, spooky eyes, wisps |
| `E` | Electric | lightning hits the 3 nearest bricks | crackling arcs, lightning bolts |

### Make your own level

Open `GameLevels.pas`, copy one `Def(...)` block in `DefineLevels` and edit it: name, style, background, brick width/height/gap, top position, color mode and the map rows (all rows the same length, `.` = empty). Keep the map within about 780 px wide and above y ≈ 440.

**Testing tip:** to unlock every level, close the game and set `UnlockedLevel=10` in the `[Progress]` section of `breakout.ini` (path below).

## Solo or against a bot

**NEW GAME** (and starting from the **LEVELS** menu) asks how you want to play:

| Choice | What happens |
|---|---|
| **SOLO** | Classic Breakout. |
| **EASY** | Bot is slow and late; misses about half its returns. Drifts around the middle. |
| **NORMAL** | Bot follows the ball and reacts quickly; misses about a quarter. Sometimes aims at bricks. |
| **HARD** | Bot is very fast and precise; misses about 1 in 25. Aims at explosives, gold and electric bricks. |

(Miss rates come from a simulation of the bot's AI used to tune the three levels.)

Rules against a bot:
- The bot's orange paddle guards the **top**; the bricks sit lower to make room.
- Every ball belongs to whoever hit it last: **blue = yours, orange = the bot's**. Broken bricks
  (and chain reactions they start) score for that player.
- Ball past the bot: **GOAL** for you (+100 + 25 × level), and you serve again without losing a life.
  Ball past you: points for the bot, and you lose a life once no ball is left.
- Each level is a **round**: whoever scored more in it wins the round and its bonus.
- The HUD shows the bot's score and rounds won. After the last level (or when you run out of lives)
  the bigger total score **wins the match**.
- How the bot thinks: it predicts where an incoming ball will reach its paddle (including side-wall
  bounces), re-decides every 0.04–0.28 s depending on difficulty with some aiming error,
  and chooses where on its paddle to meet the ball so the ball flies toward a target brick.
  It sometimes taunts you.

## Cheat codes

Every LEVEL CLEAR screen (levels 1–9) shows a code such as `KNV8-2KGL-66EH`. The code stores
**the next level, your score, your lives, the mode (solo or bot difficulty) and the bot's score**,
so a code from a bot match continues that match. Codes from the earlier version
(9 characters, like `KQ7M-XP3RT`) still work and start a solo game.

- **C** on the level-clear screen copies the code to the clipboard.
- On the main menu, the small **Cheat-code** button in the bottom-right corner opens the code screen
  (select it with the arrow keys after EXIT, or click it).
- Type the code (the dashes are added for you), or press **Ctrl+V** to paste it, or **TAB** to fill in the last code you earned. Then press **ENTER** or click **APPLY CODE**.
- A correct code flashes green, shows the level, score and lives, and starts that level.
  A wrong code shakes the box red.

How the codes work (`GameCheat.pas`): 12 characters × 5 bits = 60 bits, which holds the level (4 bits), lives (4 bits), mode (2 bits), your score (20 bits, up to 1,048,575), the bot's score (17 bits, up to 131,071) and a 13-bit checksum. The data is scrambled with a key derived from the checksum, so nearly identical scores give completely different codes. Single-character typos are always rejected, and a random guess is accepted only about 1 time in 5,000. Codes never use the look-alike characters I, O, 0 or 1.

## Power-ups

About 1 in 6 broken bricks drops a capsule. Catch it with the paddle:

| Capsule | Effect |
|---|---|
| **W** blue | Wider paddle for 12 s |
| **M** pink | Multi-ball: every ball in play splits into three |
| **S** green | Slower balls for 9 s |
| **+1** red (rare) | Extra life |

Timers for W and S show as bars at the bottom right. Losing your last ball clears active power-ups.

## Score and high scores

- The score rolls up, pops and flashes gold each time it increases. Sparkles fly off it.
- Beating your previous best mid-game shows **NEW BEST!** and the BEST counter turns gold.
- The top 10 scores (with the level reached, the mode — SOLO / EASY / NORM / HARD — and the date) are saved automatically. A new entry gets a rainbow **NEW HIGH SCORE! #n**, a fanfare and fireworks.
- Settings and scores are stored in
  `C:\Users\<you>\AppData\Roaming\LazarusGames\SDLBreakout\breakout.ini`
  Delete that file to reset everything.

## Notes

- The game draws in a fixed 800×600 logical space; the window is resizable and letterboxes. Text is rendered at 2× so it stays sharp when scaled up.
- Music and sound are synthesized in code; no sound files and no SDL3_mixer needed. If there is no audio device, the game runs silently.
- Physics run in fixed 1/240 s sub-steps so balls can't tunnel through bricks.
