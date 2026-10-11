# Joining: the signon stages, the envelope and the client link

## The join state machine

`DotClientSession.State` is a real state machine with checked transitions, not a label:

```
CONNECTING -> AUTHENTICATING -> DOWNLOADING -> LOADING -> SPAWNED
     \              \               \             \
      ------------- REJECTED / DISCONNECTED -------------
```

- **Each stage has its own timeout** (`auth_timeout_sec`, `download_timeout_sec`, `load_timeout_sec`), because "reply to a challenge" and "download 400 MB" differ by three orders of magnitude. A client stuck in `AUTHENTICATING` has a credential problem; one stuck in `DOWNLOADING` has a slow connection. Collapsing them into "connecting" makes a server impossible to support.
- **`SPAWNED -> DOWNLOADING` is the game change**, and `LOADING -> DOWNLOADING` is legal too: a `changelevel` does not wait for a client that connected a second earlier ([game-switching.md](game-switching.md)).
- `DotClientLink` enters `PLAYING` itself after it sends `game.loaded`, with nothing coming back, so a client in `PLAYING` is not proof the server spawned it. A test of a join waits for the server session in `SPAWNED`.

## A browser tab that is not on screen is not running

A `SPAWNED` client is judged on silence: `sv_timeout` seconds without a packet and it is dropped. **A hidden browser tab sends nothing while its socket stays healthy**: the web main loop is driven by `requestAnimationFrame`, which the browser stops for a hidden tab, stopping `_process`, every `Timer` and the multiplayer poll together. A player who switched tabs was dropped about a minute in.

The client announces the switch from a `visibilitychange` listener (the `visibility` kind) and announces its return. `sv_background_grace` is the ceiling; `DotServer.set_session_background` applies the clamp and `silence_budget` is what the sweep asks. A backgrounded session wears a `B` in `status`. Any heartbeat clears the flag.

- **The announcement is reliable, the heartbeat beside it is not.** A dropped announcement costs the player their slot, and the client has no frames left to retry in.
- **The client flushes the peer itself** (`DotClientLink._flush_peer` calls `poll()` inside the listener), because `visibilitychange` arrives as a JavaScript-to-wasm call as the browser stops frames, and the poll that would send the queued message may never happen.
- **The grace is the server's number, never the client's**: it arrives as a request and is clamped, or a client could hold a slot on a full server indefinitely.
- **The ceiling is minutes, deliberately.** The server keeps sending to a hidden client and those bytes queue; the longer the grace, the bigger the burst on return. A game that wants long graces cheap gates its replication on `session.backgrounded`; only the game knows what is safe to stop sending.

## The signon revision: `DotSignon`

**Godot checksums a node's `@rpc` method names and refuses to confirm the path when two ends disagree.** A client and server with different RPC sets meet with "The rpc node checksum failed. Make sure to have the same methods on both nodes.", and the client then sits in `AUTHENTICATING` until it is timed out: neither end says "version mismatch", and the server reports a client that would not answer its challenge.

`DotSignon` makes that checkable, and none of it is written by hand. `DotSignon.revision([DotServer])` on a server and `DotSignon.revision([DotClientLink])` on a client hash the sorted `@rpc` method names out of `Script.get_rpc_config()`, the same declaration the engine checksums, so the two ends must produce the same twelve characters. `examples/signon_revision.tscn` asserts it, which fails on the commit rather than on the deployment.

Three things carry the revision, each for a different person:

- **The handshake challenge** carries `signon`, and `DotClientLink` refuses a mismatch with `CODE_UNSUPPORTED` and a sentence naming both revisions. This works because the challenge still arrives after the checksum has failed: the first call to a node goes out by full path, and what the checksum refuses is the path cache (measured with a probe).
- **`signon_timeout_sec` on the client**, for a break so severe the challenge never arrives, so the failure is reported on the client in the words of the likely cause instead of as the server's "Timed out while authenticating".
- **`info.signon` in the query response**, so a server browser or web loader can tell before connecting whether a build can join.

**An empty revision on either side is never a mismatch** (a server older than the class sends none). **Only method names are hashed**: two nodes whose methods differ only in transfer mode or channel talk fine, because the RPC id is an index into the sorted names. `signon` on the console prints the revision, the count and the names.

## The RPC surface is frozen: `DotEnvelope`

**`DotServer` and `DotClientLink` declare exactly six `@rpc` methods and nothing else in this addon declares any**: `_dot_down`, `_dot_down_unreliable`, `_dot_down_event` from the server and `_dot_up*` from the client, one per lane (reliable control, unreliable control, reliable event). Each carries a **kind** (a string) and a Dictionary. Everything that used to be a method is a kind: `signon.challenge`, `signon.credentials`, `signon.disconnect`, `content.sync`, `content.progress`, `content.ready`, `game.load`, `game.loaded`, `heartbeat`, `heartbeat.ack`, `ping`, `visibility`, `notice`, `chat.line`, `chat.submit`, `scoreboard`, `scoreboard.want`. `DotChatManager` and `DotClientChat` declare none.

**Why.** Every feature this addon grew as an RPC pair locked every shipped client out of every server built after it. The goal is the opposite: servers should run mismatched versions of the dot addons as long as the API is the same. The six names are what Godot checksums and `DotSignon` hashes, so the revision moves only if the envelope itself changes. `DotSignon.ENVELOPE` writes the six down (the one hand-written list, because it is the one thing that must not move), and `signon_revision` fails on a seventh `@rpc`, saying "add a kind".

**Each end advertises what it knows, and the server decides.** The challenge carries `kinds: {kinds, required}`; the credentials answer with the client's. A kind is known if an end handles or sends it.

- A kind the peer does not know is **not sent** (`send_kind` returns false, counted in `skipped_sends`, one DEBUG line per peer and kind).
- One that arrives with no handler is **dropped** (`dropped_arrivals`).
- A kind either end marks **required** that the other lacks **refuses the join at the credentials, before the password is looked at**, with `DotEnvelope.explain`'s sentence ("This server needs a newer game client." / "This server is older than this game client and cannot host it.") as `CODE_VERSION` in the `signon.disconnect` payload, so a shell can tell it from a kick. The server decides because it admits people and its log is the one an operator reads.
- The core kinds a join needs are required (`DotEnvelope.CORE_REQUIRED`); every feature (notices, chat, ping, visibility, progress, scoreboard) is optional, so an older peer loses the feature and keeps the game.

**Adding a feature** is `server.envelope.register(&"mything", handler, required)` plus `server.send_kind(peer, &"mything", {...}, lane)`, and the same on `link.envelope` / `link.send_kind`. **Payloads change only by adding a field**; every handler reads through `DotEnvelope.number` / `text` / `flag`, which default a field an older peer did not send and ignore a type a newer one changed. A change that cannot be an addition is a new kind. `DotSignon.PROTOCOL` (2) is for the one change names cannot express: a kind that keeps its name and changes its meaning, refused in the same words as a revision mismatch.

The envelope was the last coordinated protocol break: a client exported before it is sent kinds on RPCs it never declared and ends at its own signon watchdog. Since then, a new dot-server feature should not need a new client build.

## A reason reaches the client whoever sends it

`_close_peer` flushes and closes `CLOSE_GRACE_SEC` (0.25 s) later. Deferring the close by one call delivered a reason sent from inside an RPC handler and lost one sent from anywhere else (a module's kick, a game's netcode refusing a client), because the client read the data and the close in one poll and a closing connection drops what it has not handed up. The session is gone by then, so nothing the peer sends meanwhile is handled. `kick` takes the `DotError` it is for, so a client dropped for a mismatch reads `CODE_VERSION` rather than a moderator's kick.

## The challenge says which addons the server runs

`DotServer.addon_set` is an Array of `{dir, repo, id, version}` (`dir` under `res://addons/`, `id` the content id the addon's tag is published under). The host fills it (dot-server-deploy reads its `addons.lock`); when non-empty the challenge carries it as `addons`, with the server's `content_base_urls`. `DotClientLink.server_addons` is the client's copy, set before `server_info` fires, and the link adopts the bases into the registered cloud client.

- **The challenge**, because it is the first thing a client hears and arrives whatever else differs, and the point is to act before the join: a client with older addons fetches the newer ones as packs and restarts into them (dot-cloud's `DotCloudAddonSet`). Once a game is loaded the old addons have run and cannot be replaced in that process.
- **The bases ride with it** because a desktop client otherwise learns the content origin only from the first `content.sync`, after the challenge.
- Both are fields, so no revision moves; an empty list sends neither.

## The round trip is known as the join completes

`DotClientLink` sends a heartbeat the moment it is playing and three more a quarter of a second apart (`EARLY_HEARTBEATS`, `EARLY_HEARTBEAT_SEC`), then every `heartbeat_interval_sec`. Every game's netcode clock takes its input lead from the round trip; when the first heartbeat left two seconds after joining, the first seconds of commands arrived after their tick. `rtt_ms()` is the best figure the link has: ENet's own `PEER_ROUND_TRIP_TIME` on UDP, the heartbeat's otherwise, 0 before either. `signon_revision` asserts the round trip is known within a second of joining.

## The metered peer and net_stat

**The link's peer is metered**: `DotClientLink` wraps its multiplayer peer in dot-core's `DotMeteredPeer` (invisible to `SceneMultiplayer`), and `net_meter()` returns it. The `heartbeat.ack` carries `"sv": {fps, var_ms, tick}`, the server's own frame, as a new key in a Dictionary, so either end may be older. dot-menu's `DotMenuNetStat` (the `net_stat` overlay) reads `DotMeteredPeer.of(multiplayer.multiplayer_peer)` and never names dot-server.
