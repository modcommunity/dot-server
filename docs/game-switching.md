# Game switching and delivered content

## The change flow

`DotGameManager.change_game`:

1. fire a cancellable `game_changing` event;
2. `_acquire_content`: the server fetches and mounts the new content itself, **before** clients are told, so a server that cannot get it abandons the change while nobody has been disturbed (and a game whose dependency cannot be fetched is not loaded at all);
3. tell every client to fetch the new content (`content.sync`, with `content_extra` for the game's `dependencies`; `server_dependencies` are never sent);
4. wait for all of them, or `sync_timeout_sec`;
5. free the old scene, instantiate the new one;
6. put everyone back through `LOADING`.

- **During a sync the current game is deliberately still the OLD one.** `report_content_ready` accepts `pending_content_key()` as well as `current_content_key()`, and a client that finishes downloading is not sent a load until the swap (`load_info()` describes the running game).
- **`session.content_key` is cleared when a sync begins**, or a client returning to a game it already played looks ready before it has been told.
- **`client_state_changed` is emitted when a change moves a session**, as on the join path.
- Clients still downloading at `sync_timeout_sec` are **kicked** by default: the players who got the content should not be denied the change.
- A failed change **restores the previous game**: a server with no game is worse than one on the old map.
- The old scene is `free()`d, not `queue_free()`d: the next scene is added in the same call, and two games in the tree means duplicate nodes, groups and physics for a frame.
- Releasing old content calls dot-cloud's `release()`. A resource pack cannot be unmounted; version-namespaced mount paths are what make that sufficient (see dot-cloud's [mounting.md](../../dot-cloud/docs/mounting.md#a-mounted-resource-pack-can-never-be-unmounted)).
- `DotGameDescriptor.cvars` are applied when the game loads, in two passes ([console.md](console.md#modules)).
- The server wakes for a game load ([boot.md](boot.md#a-game-loads-awake)).

## Delivered or shipped in the build

**Delivered is `needs_delivered_content()`, not "has a `manifest_url`".** A relative scene path can only resolve against a mount, so a descriptor carrying one has already said what it is; the id and version say which content, and `DotCloudClient.ensure` finds it against whatever bases that client has. `manifest_url` is still honoured and wins, for content whose client has no base. `content_key()` and `client_scene_or_scene()` follow the same rule: an empty content key is what a client reports and what `_resolve_scene` splits to build the mount path, so a delivered game with no URL once told clients to download something with no name.

**A game shipped inside its build has no client scene to name.** `client_scene_or_scene()` returns `""` for it. `_resolve_scene` refuses every absolute path outside the mount ([security.md](security.md#security-decisions-worth-not-undoing)), so falling back to the server's own absolute `scene` produced a refusal and a client timed out in `LOADING`. The empty string is the "you already have it" path (`game.loaded`, then `PLAYING`), and the application loads whatever its own build says the client is. A delivered game sets a relative `client_scene` and gets the mounted one.

**The client `ensure`s rather than `acquire`s**, so a server cannot point a client at another published pack and have it mounted under the expected key.

## What a game parents under `Server` goes with the game

A game's RPC node (its "net link") lives under `Server` on both ends, because Godot routes an RPC by the receiver's node path relative to the scoped `MultiplayerAPI` root and both ends call their half `Server` (`DotServer`, `DotClientLink`). The game's scene is freed at a change; that node is not inside the scene, and no game frees it.

**So both ends retire it at the change.** `DotGameManager` remembers the server's children when a game's scene goes in, and at `_unload_current` every child added since is the game's. `DotClientLink` treats every child that is not its own (chat, the two timers, a default game root) as the game's, at every `LOAD_GAME` and at unload. Each such node is **renamed** `<name>_retired_<id>` at once and **freed `RETIRED_SECONDS` (10 s) later**.

**Why renamed, not freed.** Freed or left alone are both wrong:

- Left alone (the old behaviour), the next time the same game loaded its node collided with the leftover's name, and Godot renamed the newcomer `@Node@<n>`. The ends' paths disagreed and every request the client sent was dropped with `Node not found: "Server/@Node@2370"`, `Failed to get path from RPC`, `Invalid packet received`. A rotation that comes back to a game is the ordinary case.
- Freed at once, everything already in flight (a client sends until `LOAD_GAME` reaches it, the server's last snapshots are still travelling) became `Failed to get cached node from peer` or `Node not found: "Server/<Game>"`. Godot resolves an already-cached RPC path by the node's object, not its name, and forgets the cache when the node leaves the tree.
- Renamed and kept, stragglers land on a node whose bridge is gone and are dropped quietly, and the name is free for the next game this frame.

The rule this puts on everything else: **nothing but a game adds children under `DotServer` after boot.** The host's own nodes live under the host.

## Pack lists on a descriptor

`DotGameDescriptor.dependencies` (mounted on the server and sent to clients), `server_dependencies` (server only) and `maps` (fetched when the server changes to one), with `DotGameManager.current_server_dependencies()` / `current_maps()` (API level 2). Pinning the versions is the host's job; dot-server-deploy's installer does it ([its doc](../../dot-server-deploy/docs/installing-games.md#three-lists-of-packs-beside-the-games-own)).

## Coupling: nothing is imported

dot-server works standalone. Optional addons are found through `DotRegistry` at runtime or reached duck-typed:

| Optional addon | How it is found | Without it |
| --- | --- | --- |
| dot-auth | `dot_auth_server` | Everyone is a guest with a per-device id; `DotGuestIdentity` gives the same duck-typed surface as `DotAuthIdentity` |
| dot-cloud | `dot_cloud_client` | Games must ship inside the build; a server needing downloadable content refuses the client with a clear reason |
| dot-auth admin source | duck-typed `lookup()` / `source_name()` | File-based admins only |
| dot-moderation | `dot_ban_source` | `DotBanManager`'s list is the whole ban list |
| dot-chat | `watch_relay` / `relay_fn` | Chat state reports no relay |
| dot-server-query | `attach_query_host(host)` | The server answers nothing on the query port, a supported configuration |

**Keep it this way.** A script that mentions a `class_name` the project does not have fails to parse and takes every script referencing it down with it, so naming an optional addon's class anywhere here makes that repository mandatory. A hard dependency in either direction makes both harder to adopt.

## Server queries live in dot-server-query

Both query protocols, their snapshot, the challenge, the provider API and the two console commands moved to [dot-server-query](../../dot-server-query). What is left here is one hook, `attach_query_host(host: Object) -> DotResult`: `DotQueryHost` calls it, and `DotServer` opens it once `RUNNING` (or at once if already). `query_host`, `query_source`, `query` and `a2s` are typed `Object` and reached with `.call(...)`.

**The configuration stayed**: `query_enabled`, `a2s_enabled`, `query_port`, `a2s_port`, `query_bind_address`, `query_player_detail` and the rest are `DotServerConfig` fields, and `sv_query`, `sv_a2s` and `sv_query_players` are registered here before `server.cfg` runs. They name no class, so every operator's config keeps working and a server without the addon has settings nothing reads. Without the addon, `DotModule.add_query_provider` returns a failed `DotResult` naming it and `to_stats_report()` reports 0 bots.

## Subsystems are `DotNodeRef`s

Every subsystem on `DotServer` is an exported `DotNodeRef` defaulting to `of_created(...)`. A bare `DotServer` works; a host can place its own nodes or point two servers at one console. Created nodes have already run `_ready()` when their `config` is set ([boot.md](boot.md#boot-order-is-fixed-and-load-bearing)).
