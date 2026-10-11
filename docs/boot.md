# Boot, configuration and the tick rate

## Boot order is fixed and load-bearing

```
config resource -> JSON file -> env -> argv       (DotServerConfig layers)
  -> console created, cvars registered
  -> server.cfg executed                          <- FLAG_STARTUP_ONLY still settable
  -> command line, cvar half (+sv_tickrate 128)
  -> cvars read back into config
  -> subsystems created (events, audit, admins, bans, chat, games, votes, modules, rcon)
  -> LISTENER OPENS                               <- FLAG_STARTUP_ONLY locks here
  -> RUNNING (or HIBERNATING), then the query host is opened   <- dot-server-query, if attached
  -> autoexec.cfg executed
  -> +command arguments executed (the full pass)
```

- **`server.cfg` (`DotServerConfig.startup_config`) runs before the listener** because that is the only window in which a `FLAG_STARTUP_ONLY` cvar is settable. `autoexec.cfg` runs after and has them refused, so a startup-only cvar in the wrong file fails quietly.
- **The command line runs twice**: `execute_command_line(true)` before the listener lets through only statements naming a registered cvar; the full pass afterwards runs everything else, because `+changelevel` or `+say` needs the server up. Before this split, every startup-only cvar was unsettable from argv.
- `DotConfig`'s own layers (`--sv-tickrate=128`, `DOT_SERVER_TICKRATE=128`) are a separate path, applied to the config object before any cvar exists.
- `+command` arguments run last so a unit file can override a config file without editing it.
- **Created subsystems have already run `_ready()` when `DotServer` sets their `config`**, so loads are triggered explicitly (`admins.load_admins()`), never left to `_ready` ordering. The audit log was once missed this way and no administrative action was recorded in any default configuration.

`FLAG_STARTUP_ONLY` is for what a live server cannot re-negotiate; changing such a value at runtime would half-apply. No builtin cvar carries it any more since `sv_tickrate` went live (below); the flag, both passes and the test cvar in `dedicated_server` remain for cvars that need it.

## `sv_tickrate` is live, and applies at a boundary

Changing the tick rate used to mean a restart that disconnected everybody. Before the listener it still applies at once (`server.cfg`, `+sv_tickrate`). While running, a new value is held: `pending_tickrate()`, the `tickrate_pending(rate)` signal, and `stats` prints "tickrate N at the next map change".

- It is applied by `apply_pending_tickrate()`, which a game that follows maps calls as its old map goes, because a tick rate is the step every input timeline, prediction history, run and replay counts in, and a map change is where all of that starts over. Otherwise the next GAME change applies it.
- `tickrate_changed(rate)` fires when it lands; the game re-steps and tells its clients.
- `tickrate()` is the playing rate, never the hibernation rate the engine sits at while empty. Setting it back to the playing rate cancels what was waiting.

The family's tickrate chain is `sv_tickrate` → `Engine.physics_ticks_per_second` → the game.

## Hibernation: an empty server is idle, and its clocks wait

`sv_hibernate_when_empty` (`DotServerConfig.hibernate_when_empty`, default 1, live) puts a server with no sessions into `HIBERNATING` (`hibernate_tickrate` ticks, `hibernate_frame_rate` frames) **from boot** and whenever the last session leaves; the first client to spawn wakes it.

- **`hibernation_changed(hibernating: bool)` is the hook**, a plain bool on purpose: dot-vote's `DotVoteDirector.follow_hibernation(server)` and dot-map's `DotMapSession.follow_hibernation(server)` connect to it by name, and dot-game's `DotGameModule` hands the server to every such clock. Asleep they stop counting; on waking they restart from their configured values. Without this, a fresh server's map clock ran out to an empty room.
- Setting the cvar to 0 on an empty server wakes it. With it off, a time limit that runs out on nobody is dot-vote's `empty_choice`.
- **"Up" is `RUNNING or HIBERNATING`**, which is what `online` in the query answer has always said. A host waiting for `RUNNING` after boot will see `HIBERNATING`.

## A game loads awake

A game reads its tick rate from the engine as it starts, so a game loaded while the server slept started at `hibernate_tickrate` (a delivered netcode refused to start: "snapshot_rate must not exceed tick_rate, 32 > 5"). `DotServer` wakes on `game_changing` (`_begin_game_load`), refuses to hibernate while `_loading_game`, and after `game_loaded` or `game_load_failed` goes back to sleep **deferred** (`_end_game_load`), because a host's own `game_loaded` handler is what loads the module and it must run awake too. A wake for a load restarts the clocks following `hibernation_changed`, which is right for a new game.

**One process, one tick rate.** A test that runs a server and a client in one process must turn hibernation off in its fixture (`sv_hibernate_when_empty: false`): the server sleeps before the client connects and the client's game starts at 5 Hz. In production they are two processes.
