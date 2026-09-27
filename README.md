# FPS Multiplayer Template

A 3D first-person multiplayer starter for Godot 4.5 (GDScript, no C#). It started life as a
multiplayer dodgeball game, so it ships with a working pick-up / charge / throw ball loop you can
keep, reskin, or rip out.

## What's in it

- **First-person player** (`Components/Player`) with sprint, crouch, dash, double jump, stamina,
  climbing, and hands that grab and throw objects.
- **Networking** (`Screens/game.gd`) over Steam lobbies (GodotSteam) or local ENet loopback. The
  host owns match state and replicates it to clients.
- **Match flow** (`Global/Autoload/MatchManager.gd`) with Team Battle, Capture the Flag, Battle
  Royale, and Race modes, plus a Classic tournament series.
- **Throwables** (`Components/Dodgeball`, `Components/BallSpawner`): grabbable balls, explosive
  balls, and spawners.
- **UI**: HUD (hearts, damage indicator), pause menu, map/mode select, end screen.
- **Creative mode** for building maps in-game (F2). Gated by `dev_mode` on the `Game` node, which
  is on in this template; turn it off for release builds.
- **Maps**: `LobbyMap` (the hub everyone waits in) and `ColosseumMap` (the default arena).

## Setup

1. Install [Godot 4.5](https://godotengine.org/download/) (standard build, not .NET).
2. Clone the repo.
3. Install **GodotSteam** (GDExtension) into `addons/godotsteam/`, e.g. from the Godot Asset
   Library. `addons/` is not committed.
4. Open the project and press **F5**.

`steam_appid.txt` is set to `480` (Valve's Spacewar test app, which every Steam account owns), so
Steam lobbies work out of the box. Swap in your own app ID when you have one.

## Running

- **Two instances on one machine:** set `net_mode` on the `Game` node (`Screens/Game.tscn`) to
  `LOCAL`, then use *Debug → Customize Run Instances* to launch two windows.
- **Over Steam:** leave `net_mode` on `STEAM`, have Steam running, host from the in-game menu, and
  invite friends.

## Controls

| Action | Keyboard / mouse | Gamepad |
| --- | --- | --- |
| Move | WASD / arrows | Left stick |
| Look | Mouse | Right stick |
| Jump | Space | A |
| Sprint | Shift | Left trigger |
| Crouch | Ctrl | B |
| Dash | Q | Left shoulder |
| Grab / throw (hold to charge) | Left mouse | Right trigger |
| Pause | Esc | |

## Adding a map

Save a new scene in `Screens/Maps/`. The Map Select menu picks up every `.tscn` there
automatically (except `LobbyMap`). A playable map needs a `SpawnPoints` node; CTF needs
`CTFBase` + `Flag` nodes and Race needs a `RaceFinish` trigger. Use `ColosseumMap.tscn` as the
reference. To make a map a mode's default or add it to the Classic tournament, edit `MAP_OF` and
`CLASSIC_MAP_POOL` in `Global/Autoload/MatchManager.gd`.
