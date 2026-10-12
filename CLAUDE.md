# dot-server

Dedicated server framework for Godot 4: console variables and commands, RCON, flag-based admin permissions, moderation, votes, a game event bus, hot-loadable modules, and switching games while players stay connected. Every game in the family runs on it, and `DotClientLink` is the client half every shell uses.

**The distributable is `addons/dot_server/`.** It requires [dot-core](../dot-core) and optionally integrates with dot-auth, dot-cloud, dot-moderation, dot-chat and dot-server-query, all discovered at runtime, none imported.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
# Optional; the self-test runs the ban-source seam against a real dot-moderation and says so loudly when the link is missing.
ln -s ../../dot-moderation/addons/dot_moderation addons/dot_moderation
```

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to dot-server. The reasoning is in [docs/](docs/README.md).

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/boot.md](docs/boot.md) | boot order, `server.cfg`, startup-only cvars, hibernation, `sv_tickrate` |
| [docs/signon.md](docs/signon.md) | anything on the join path, `DotClientLink`, `DotEnvelope`, `DotSignon`, heartbeats, the metered peer |
| [docs/transports.md](docs/transports.md) | `transport_mode`, ENet, the shared UDP port, credentials |
| [docs/game-facing.md](docs/game-facing.md) | `DotNotice`, the scoreboard, chat state, `DotBotQuota` |
| [docs/console.md](docs/console.md) | a command or cvar, chat commands, `add_source`, completion, modules, target names |
| [docs/security.md](docs/security.md) | permissions, RCON, sanitising, bans, `dot_ban_source`, the per-address limit |
| [docs/game-switching.md](docs/game-switching.md) | `DotGameManager`, descriptors, delivered content, an optional addon, the query hook |
| [docs/testing.md](docs/testing.md) | the four suites |
| [docs/history.md](docs/history.md) | a server bug that "cannot be happening" |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_server/dot_server_api.gd` | the API level and what each level added |
| `console/` | `dot_convar.gd` (values as strings, flags enforced here), `dot_concommand.gd`, `dot_cmd_context.gd` (who is calling), `dot_console.gd` (registry, buffer, cfg, completion, `add_source`), `dot_builtin_commands.gd` (the whole command surface) |
| `server/` | `dot_server_config.gd` (boot config; `validate()`), `dot_client_session.gd` (the signon state machine: read it), `dot_guest_identity.gd`, `dot_server.gd` (lifecycle, sessions, the six envelope RPCs, timeouts, tick, notices, scoreboard) |
| `client/` | `dot_client_link.gd` (the client's half: the same six RPCs, the other ends' kinds), `dot_client_chat.gd` (declares no RPC) |
| `net/` | `dot_envelope.gd` (kinds, adverts, required/optional, the refusal sentence), `dot_signon.gd` (the six RPC names as twelve characters), `dot_notice.gd` |
| `admin/` | `dot_admin_flags.gd`, `dot_admin_manager.gd` (resolution, merging, sources) |
| `moderation/` | `dot_ban_manager.gd`, `dot_address_guard.gd`, `dot_audit_log.gd` (JSONL, flushed per entry) |
| `rcon/` | `dot_rcon_server.gd` (classic RCON plus WebSocket) |
| `chat/` | `dot_chat_manager.gd` (routing, flood control, sanitising, chat triggers) |
| `game/` | `dot_game_descriptor.gd` (scene paths resolve under the mount prefix), `dot_game_manager.gd` (the change flow) |
| `vote/`, `events/` | `dot_vote_manager.gd`; `dot_event.gd` (pre-hooks may rewrite or cancel), `dot_event_bus.gd` |
| `modules/` | `dot_module.gd` (base class; the helpers are not optional), `dot_module_host.gd`, `dot_bot_quota.gd` |
| `cfg/` | `server.cfg` (shipped defaults; copy to `user://cfg` and edit that), `autoexec.cfg` |
| `examples/` | `dedicated_server`, `signon_revision`, `content_switch`, `mixed_transports` |

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `dedicated_server.tscn`, `signon_revision.tscn`, `content_switch.tscn` and `mixed_transports.tscn`. `dedicated_server.tscn -- --serve` runs a real server. **A change here is not done until dot-server-deploy's `*_client` suites and the games' net suites agree.** [testing](docs/testing.md)

## API level

`LEVEL` in `addons/dot_server/dot_server_api.gd` (no `class_name`) rises by one for anything a game could call that did not exist before; `OLDEST` is raised to `LEVEL` when something a game could call is removed or changes meaning. The rule is dot-core's `DotAddonApi`; packs declare what they need in `requires.json` and a server refuses one it cannot run. Write the new level's additions in the file's comment. Current levels: 2 descriptor pack lists, 3 dual transport, 4 the scoreboard roster, 5 `DotBotQuota` / `addon_set` / `rtt_ms()`, 6 `net_meter()` and the heartbeat ack's `"sv"`, 7 the `PROFILE` signon stage (`hold_profile` / `release_profile` / `refuse_profile`, `profile_timeout_sec`), 8 replicated cvars (`DotEnvelope.CVARS`, `DotClientLink.replicated_cvar()`), 9 the block list's roster (`"key"` and `"peer"` on scoreboard rows, `DotServer.player_key()`, `DotClientLink.request_scoreboard()`), 10 `DotClientLink.tls_connect_timeout_sec` (a native WebSocket join to a public bare `host:port` tries `wss://` first).

## Rules that bite

**The wire**

- `DotServer` and `DotClientLink` declare exactly six `@rpc` methods and nothing else here may declare any. A new feature is a new envelope kind, never an `@rpc`. [signon](docs/signon.md#the-rpc-surface-is-frozen-dotenvelope)
- Payloads change only by adding a field, read through `DotEnvelope.number`/`text`/`flag`; a change that cannot be an addition is a new kind. [signon](docs/signon.md#the-rpc-surface-is-frozen-dotenvelope)
- Only core join kinds are required; a feature kind is optional so an older peer loses the feature and keeps the game. [signon](docs/signon.md#the-rpc-surface-is-frozen-dotenvelope)
- The signon revision is derived from the RPC names, never written by hand; an empty revision is never a mismatch. [signon](docs/signon.md#the-signon-revision-dotsignon)
- A hidden browser tab announces itself reliably and flushes its own peer; the grace is the server's number. [signon](docs/signon.md#a-browser-tab-that-is-not-on-screen-is-not-running)
- `DotClientSession.State` values never move: a new stage goes on the end of the enum, the order is `_can_transition`'s. [signon](docs/signon.md#the-join-state-machine)
- A module holds `PROFILE` from inside `client_state_changed`, before any await; nobody holding means the player goes straight through. [signon](docs/signon.md#the-profile-stage-a-module-may-hold-a-player-and-refuse-them-unseen)
- No bearer secret (access token, account password) is ever sent over ENet; tickets and the server's own join password are. [transports](docs/transports.md)
- `FLAG_REPLICATED` cvars reach clients (`DotEnvelope.CVARS`, table before each `LOAD_GAME`, deltas after); never replicate a protected one. [game-facing](docs/game-facing.md#replicated-cvars-the-servers-rules-on-the-client)
- Ask a peer list before sending to a session; a session with no peer is an engine error per send. [game-facing](docs/game-facing.md#dotnotice-something-for-the-hud-that-is-not-chat)

**Boot and time**

- `server.cfg` runs before the listener and is the only file where a startup-only cvar works; argv's cvar half runs before the listener too. [boot](docs/boot.md#boot-order-is-fixed-and-load-bearing)
- A created subsystem has run `_ready()` before its config is set; trigger loads explicitly. [boot](docs/boot.md#boot-order-is-fixed-and-load-bearing)
- `sv_tickrate` set while running waits for `apply_pending_tickrate()` or the next game change; `tickrate()` is never the hibernation rate. [boot](docs/boot.md#sv_tickrate-is-live-and-applies-at-a-boundary)
- An empty server hibernates from boot; "up" is `RUNNING or HIBERNATING`; clocks follow `hibernation_changed`. [boot](docs/boot.md#hibernation-an-empty-server-is-idle-and-its-clocks-wait)
- A game load wakes the server, and it sleeps again deferred. A one-process server+client test turns hibernation off. [boot](docs/boot.md#a-game-loads-awake)

**Console and modules**

- Every path in goes through `DotConsole.execute` with a `DotCmdContext`; the permission flag is the boundary, not the source. [console](docs/console.md#console-design)
- Modules register through `DotModule`'s helpers, or an unload leaves handlers on a freed object. [console](docs/console.md#modules)
- Descriptor cvars apply in two passes; a host calls `reapply_descriptor_cvars()` once its module is up. [console](docs/console.md#modules)
- `map` is dot-map's; this addon switches games (`changelevel`, `game`). [console](docs/console.md#map-belongs-to-dot-map)
- A lambda held by a long-lived console can outlive its script at teardown; use static methods for validators. [game-facing](docs/game-facing.md#how-many-bots-dotbotquota)

**Security and moderation**

- Empty `rcon_password` means no listener; passwords compare in constant time; the allow-list is checked before the password. [security](docs/security.md#security-decisions-worth-not-undoing)
- `_resolve_scene` refuses absolute paths outside the mount; the client `ensure`s, never `acquire`s, server-named content. [security](docs/security.md#security-decisions-worth-not-undoing)
- A malformed `admins.json`/`bans.json` keeps the previous state; a failed ban-store load keeps what is in force. [security](docs/security.md)
- `dot_ban_source` is read-only and asked twice per join; a source that cannot answer is reported once and ignored. [security](docs/security.md#somebody-elses-ban-list-dot_ban_source)
- `await bans.unban(x).ok` binds to the property: assign the result first. [security](docs/security.md#sharing-a-ban-list-across-servers)
- `ip:` matches a household; acting on it checks immunity against every session there. [console](docs/console.md#naming-a-player)

**Games and content**

- Never name an optional addon's class here; reach it through `DotRegistry` or `Object.call`. [game-switching](docs/game-switching.md#coupling-nothing-is-imported)
- The server acquires the new content before telling clients; during a sync the current game is still the old one. [game-switching](docs/game-switching.md#the-change-flow)
- A built-in game has no client scene (`""`); delivered is `needs_delivered_content()`, not a `manifest_url`. [game-switching](docs/game-switching.md#delivered-or-shipped-in-the-build)
- The query config stays on `DotServerConfig` even though the responder is dot-server-query's. [game-switching](docs/game-switching.md#server-queries-live-in-dot-server-query)
- What a game parents under `Server` (its RPC link) is retired at the change on both ends: renamed at once, freed 10 s later. Nothing but a game adds children under `DotServer` after boot. [game-switching](docs/game-switching.md#what-a-game-parents-under-server-goes-with-the-game)

## Things deliberately not here

- **Serving content in-band.** dot-cloud's `DotCloudSourceNetchan` expects a server exposing `cloud_chunk_size()` / `cloud_request_chunk()`; nothing here does. `allow_netchan_content`, `netchan_chunk_bytes` and `netchan_chunks_per_second` are declared, sent to clients and enforced by nothing; when it lands, the rate limit is the security control.
- **State replication.** dot-server gets a player into the world and hands over; snapshots, prediction and lag compensation are a game's (dot-net). `DotTransport.Channel.STATE` is reserved for it.
- **A master-server heartbeat.** `sv_lan` exists and does nothing yet; a tracker has to be told the address.
- **Answering a query.** dot-server-query does that, and dot-browser asks.
- **A listen-server helper.** `DotServer` and `DotClientLink` in one process works (that is why there are no autoloads), but nothing wraps the pattern.
