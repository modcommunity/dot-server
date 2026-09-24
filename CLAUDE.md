# dot-server

Dedicated server framework for Godot 4: console variables and commands,
RCON, flag-based admin permissions, moderation, votes, a game event bus, hot-loadable
modules, and dynamic game switching while players stay connected.

**The distributable is `addons/dot_server/`.** It requires [dot-core](../dot-core),
and optionally integrates with [dot-auth](../dot-auth), [dot-cloud](../dot-cloud) and
[dot-moderation](../dot-moderation) — all discovered at runtime, none imported.

```bash
# Local development setup — the dot-core symlink is gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core

# Optional, and the self-test wants it: the ban-source seam is run against a real
# dot-moderation rather than against a mock of one, and says so loudly when the link
# is missing rather than passing a section that ran nothing.
ln -s ../../dot-moderation/addons/dot_moderation addons/dot_moderation
```


## Startup-only cvars, and the two places they can be set

`FLAG_STARTUP_ONLY` is for what a live server cannot re-negotiate: the listen port,
the tickrate, the transport. Changing them at runtime would half-apply, so the console
refuses them once `set_server_running(true)` has been called.

That leaves exactly two places they *can* be set, and both are before the listener
opens:

- **`server.cfg`** (`DotServerConfig.startup_config`), exec'd before
  `_start_listening()` — which is the whole reason the ordering is what it is.
  `autoexec.cfg` runs *after* and has them refused, so a `sv_tickrate` in the wrong one
  of the two fails quietly.
- **the command line's cvar half**, `+sv_tickrate 128`.

The second used to fail. `execute_command_line()` ran in full *after*
`set_server_running(true)`, so every startup-only cvar was unsettable from the most
startup-ish input a server takes — the flag meant "settable nowhere but `server.cfg`",
and an operator with the muscle memory of any other server got one that ignored
them and said so only in a log line.

It now runs twice: `execute_command_line(true)` before the listener, which lets
through only statements naming a registered cvar, and the full pass afterwards for
everything else — because a `+changelevel` or a `+say` genuinely does need the server up
first.

`DotConfig`'s own layers (`--sv-tickrate=128`, `DOT_SERVER_TICKRATE=128`) are a
separate path and always worked: they are applied to the config object before any cvar
exists.

## Boot order is fixed and load-bearing

```
config resource -> JSON file -> env -> argv       (DotServerConfig layers)
  -> console created, cvars registered
  -> server.cfg executed                          <- FLAG_STARTUP_ONLY still settable
  -> cvars read back into config
  -> subsystems created (events, audit, admins, bans, chat, games, votes,
     modules, rcon)
  -> LISTENER OPENS                               <- FLAG_STARTUP_ONLY locks here
  -> RUNNING, then the query host is opened       <- dot-server-query, if attached
  -> autoexec.cfg executed
  -> +command arguments executed
```

`server.cfg` runs *before* the listener because that is the only window in which
`sv_tickrate` and the port can be set. `autoexec.cfg` runs after, so it can assume a
running server. `+command` arguments run last so a systemd unit can override a config
file without editing it.

## The one path everything else serves: joining

`DotClientSession.State` is a real state machine with checked transitions, not a
label:

```
CONNECTING -> AUTHENTICATING -> DOWNLOADING -> LOADING -> SPAWNED
     \              \               \             \
      ------------- REJECTED / DISCONNECTED -------------
```

Each stage has its own timeout (`auth_timeout_sec`, `download_timeout_sec`,
`load_timeout_sec`), because the right budget for "reply to a challenge" and
"download 400 MB" differ by three orders of magnitude. A client stuck in
`AUTHENTICATING` has a credential problem; one stuck in `DOWNLOADING` has a slow
connection. Collapsing these into "connecting" is what makes a server impossible to
support.

`SPAWNED -> DOWNLOADING` is a legal transition — that is the game change, and it is
the whole reason the family exists.

### A browser tab that is not on screen is not running

A `SPAWNED` client is judged on silence rather than on time in state: `sv_timeout` seconds without a packet and it is dropped. **A browser client that is not the front tab sends nothing at all, and its socket stays open and healthy while it does.** The main loop on web is driven by `requestAnimationFrame`, and a browser stops calling it for a hidden tab — which stops `_process`, every `Timer` and the multiplayer poll together. Nothing is sent, nothing is read, and from the server's side that is indistinguishable from a machine that died. A player who switched tabs was being dropped about a minute in.

The client therefore announces the switch on its way out, from a `visibilitychange` listener, and announces its return. `sv_background_grace` is the ceiling on what it gets; `DotServer.set_session_background` applies the clamp and `silence_budget` is what the sweep asks. A backgrounded session wears a `B` in `status`.

Three things about it are load-bearing and none of them errors:

- **The announcement is reliable and the heartbeat beside it is not.** A dropped heartbeat costs one ping sample. A dropped announcement costs the player their slot, and the client cannot retry — it has no frames left to retry in.
- **The client flushes the peer itself.** `visibilitychange` arrives as a JavaScript-to-wasm call, not as a frame callback, and it fires as the browser is stopping `requestAnimationFrame`. The poll that would ordinarily send what `rpc_id` queued may simply never happen again, so `DotClientLink._flush_peer` calls `poll()` inside the listener. An announcement that never leaves is the same as no announcement.
- **The grace is the server's number, never the client's.** It arrives as a request and is clamped. A client that named its own would be able to sit on a slot of a full server for as long as it liked.

Any heartbeat clears the flag, whatever the client last announced: a heartbeat is proof that the loop is running, and a session left flagged would keep a grace it no longer needs.

**Adding an `@rpc` to this pair is a protocol break, and it announces itself badly.** Godot checksums a node's RPC methods and refuses to confirm a path when the two ends disagree, so a client built before `client_visibility` existed meets a server built after it with *"The rpc node checksum failed. Make sure to have the same methods on both nodes."* — and then sits in `AUTHENTICATING` until it is timed out, because the path it needs to reply on was never confirmed. Neither end says "version mismatch"; the server reports a client that would not answer its challenge. Observed while testing this change against a stale exported client. `DotServer` and `DotClientLink` must gain and lose RPC methods **together**, and every shipped client has to be rebuilt alongside the servers it will meet — which for this platform means re-exporting the web shell and the native builds, not only restarting the servers.

**`DotSignon` is that break made checkable, and none of it is written down by hand.** `DotSignon.revision([DotServer, DotChatManager])` on a server and `DotSignon.revision([DotClientLink, DotClientChat])` on a client hash the sorted `@rpc` method names out of `Script.get_rpc_config()` — the same declaration Godot itself checksums, so the answer cannot drift from the engine's. The two sides run different scripts and must produce the **same** twelve characters; `examples/signon_revision.tscn` asserts exactly that, which is the check that fails on the commit rather than on the deployment.

Three things carry it, and each answers a different person's question:

- **The handshake challenge** carries `signon`, and `DotClientLink` refuses a mismatch with `CODE_UNSUPPORTED` and a sentence naming both revisions. This works *because* the challenge still arrives after the checksum has failed: the first call to a node goes out by full path, and what the checksum refuses to confirm is the path **cache**. Measured, not assumed — a probe with an added method delivered its first RPC and then failed to confirm, on both ends.
- **`signon_timeout_sec` on the client**, for the break severe enough that the challenge never arrives at all. A connected socket that says nothing used to end as the server's "Timed out while authenticating", which blames the player's network for a build mismatch; it now ends on the client, in the words of the thing that is probably wrong.
- **`info.signon` in the query response**, so a server browser or a web loader can tell **before connecting** whether the build it is about to boot can join — which is what makes an "open the build this server needs" affordance possible at all.

An empty revision on either side is never a mismatch: a server older than this class sends none, and refusing it would break every client against every server already deployed — the same failure, reached from the other direction. `signon` on the console prints the revision, the count and the method names, because "revision differs" is only ever the first half of the question.

**What is hashed is method names and nothing else.** Two nodes whose methods differ only in transfer mode or channel talk perfectly — the RPC id is an index into the sorted names — so hashing the modes would report an incompatibility the engine does not have and send a player to an older build for nothing.

**The ceiling is deliberately measured in minutes.** While the tab is hidden the server goes on sending to a client that is not reading, and those bytes queue — in a game's own per-peer send, and then in the socket. The longer the grace, the bigger the burst that lands when the player comes back, and the more a parked tab costs everybody still playing. A game that wants to make long graces cheap should gate its replication on `session.backgrounded`; dot-server does not do that for it, because only the game knows what is safe to stop sending.

## Something for the HUD that is not chat: `DotNotice`

`DotServer.broadcast_notice(notice)` and `send_notice(session, notice)` put a line, a countdown and a sound on a playing client's HUD; `DotClientLink.notice_received` is where the client hears it. A `DotNotice` is a cue id (a dot-audio id, typically), an optional line of text, an optional countdown in seconds that the client runs itself, and an optional topic that says which HUD line it replaces — so "10… 9… 8…" is one line changing rather than ten, and a notice carrying a topic and nothing else takes that line down.

**It exists because the application had no way to be told anything but chat.** A client talks to a server over exactly two RPC sets, `DotClientLink`'s and `DotClientChat`'s, and until this the only thing either could carry that a player sees was a chat line. A game's own wire reaches the game, but a server-level vote for the next game is the server's: it outlives every game it changes to, the host running it names no game's classes, and the change it causes replaces the game's wire mid-sentence. So dot-server-deploy's game vote reached players as scrollback only — no countdown on screen, no sound when the ballot opened — and the reason written down beside it was that the fix is an `@rpc` pair here and a new signon revision.

**Generic on purpose, because the next one costs the same.** A cue, seconds, text and a topic cover a restart warning, an operator's announcement and a map vote a game did not wire itself as well as the game vote. A vote-shaped message would be the second pair somebody adds the next time, and every pair added is a revision every shipped client has to be rebuilt for.

**The payload is a dictionary and that is the protocol decision.** The engine's RPC checksum is over method names, so a field added to the dictionary later changes no revision and breaks no client, where a new argument or method breaks all of them. `DotNotice.from_wire` defaults, type-checks and bounds every field — a `Variant` off the wire compared against the wrong type is a runtime error in a client's RPC handler — and an unknown field is ignored rather than refused. A bare cue is one key; a countdown of zero is still a countdown, and "no countdown" is -1, because a HUD told "0 seconds" draws a line that has already run out.

**Playing sessions only**, the same audience as `broadcast_message`, and the peer list is asked before `rpc_id` for the reason `DotChatManager._can_reach` gives: a session whose player just left, or an adopted one with no peer, is an engine error and a backtrace per notice, which at one a second is a log nobody reads again. A client in `DOWNLOADING` has no HUD; a host that wants a late joiner to see a line that is still true resends it from `client_spawned`, which is where it knows what is still true. `notice_sent(notice, recipients)` fires even for zero recipients, so a host mirroring notices into a log hears the one it meant.

**It is on the event channel**, reliable and ordered like chat, and off the control channel so a HUD line never queues behind a content sync.

**Adding it moved the signon revision from `c5c1f679edb5` to `b202b914834e`** (2026-09-24). Nothing was bumped by hand — `DotSignon` derives it — and `PROTOCOL` stays 1, because no existing message changed meaning. A client exported before this meets a server built after it (or the other way round) and is refused at the challenge with *"This server needs a different build of the game client"*; a shell posts `tmc.build.mismatch` to its page. A client older than `DotSignon` itself (before 2026-09-14) has no such check and times out in `AUTHENTICATING` the old way. Rebuild the web and native shells alongside the servers.

## Console design

**Values are strings.** Every path a cvar value arrives through is textual (a `.cfg`
file, an RCON packet, a chat command, argv) and every path out is too. One
representation, one place parsing can fail, no class of bug where `800` and `800.0`
behave differently.

**Flags are what make a console safe to expose.** All enforced in
`DotConVar.set_value`, gated by a caller-supplied context rather than global state —
because a cvar set from a config file at boot legitimately bypasses checks that a
cvar set over RCON must not:

| Flag | Effect |
| --- | --- |
| `FLAG_CHEAT` | Refuses unless `sv_cheats` is on. Trusted callers (console, config) bypass — that is how `sv_cheats` itself gets set. |
| `FLAG_PROTECTED` | Never printed. Redacted in `cvarlist`, in `writeconfig`, and **in the log** — the log is the more commonly pasted artefact. |
| `FLAG_STARTUP_ONLY` | Refused once the listener is open. |
| `FLAG_ARCHIVE` | What `writeconfig` persists. |
| `FLAG_NEEDS_PERMISSION` | Requires the `cvar` flag (or `cheats` for cheat cvars). |

Out-of-range values are **clamped with a log line**, not refused. An operator typing
`sv_maxplayers 9999` should get the maximum, not an error they must look up the limit
to fix. Matches what an operator already expects.

**Every path into the server goes through `DotConsole.execute` with a
`DotCmdContext`** saying who is calling — local terminal, RCON, chat trigger, config
file, module. That is what makes one permission check cover all of them instead of
four that can disagree. Commands opt out of RCON (`rcon_allowed`) and say what they think of chat (`chat_policy`: `DEFAULT`, `ALLOWED`, `REFUSED`).

**Chat reaches every command by default, and `permission` is what refuses anybody.** `sv_chat_commands` (config: `chat_commands_open`) ships on: a line typed with one of `chat_command_prefixes` — `!` or `/` — runs whatever the speaker's flags allow, exactly as RCON does. Setting it to 0 restores the old behaviour, where only `with_chat()` commands were reachable by typing.

That default was the other way round for most of this family's life, and it was wrong in a specific way: the chat check ran *before* the permission check and never looked at who was asking, so an operator holding `changemap` typed `/map surf_beginner` into the chat box in front of them and was told the command cannot be run from chat. It read as a security boundary and was not one — the boundary is the flag, checked on the same line for every source. `.no_chat()` is what a command uses when the answer really is about the operation rather than the asker; `quit` is the only builtin that says it.

## Permissions

Flags, not roles, because operators do not agree on what a "moderator" is. Strings,
not bits, so a game adds `"give_weapon"` without coordinating with
`DotAdminFlags` or running out of bits. Unknown flags are **reported, not refused** —
they are legal for a game and also what a typo looks like.

`slay` and `teleport` began as exactly that kind of game flag and are `DotAdminFlags.SLAY` and `TELEPORT` now, because dot-moderation's live tools (`DotModToolCommands`) use them in every game and a flag every game shares is one a group file must be able to name without an "unknown flag" warning at boot. **`slay` is handling a person** — slay, slap, freeze, respawn, rename — and is a moderator's; **`cheats` is changing the game** — noclip, god, health, speed, gravity, give — and was already documented as "may turn on noclip"; `teleport` is moving people, separate because it is the power that looks most like cheating from outside. Those commands are registered by dot-moderation onto this console, duck-typed, and nothing here names them.

**Immunity is separate from flags** because "may kick" and "may be kicked" are
different questions. Equal immunity cannot act on equal, which is the rule every
long-lived admin system converges on: two admins at the same level kicking each
other in a loop has no correct resolution, so it is forbidden rather than raced.

Sources merge rather than first-match-wins: a player in a file entry and a site group
gets the union of both flags and the higher immunity. `DotAdminManager.add_source`
validates the duck-typed contract at registration, so a mistyped source is a startup
error rather than a silent absence of permissions later.

**A malformed `admins.json` is loud and keeps the previous state.** Silently meaning
"no admins" turns a typo into an unmoderated server. Same for `bans.json`.

## Security decisions worth not undoing

- **`rcon_password` empty means the listener does not open.** There is no
  configuration that produces an unauthenticated remote console.
- **RCON and server passwords compare in constant time.** Early-return comparison
  leaks how many leading characters matched, turning password guessing into one
  character at a time.
- **RCON locks out an address after `rcon_max_failures`**, and checks
  `rcon_allowed_addresses` *before* the password — the allow-list is the control that
  survives a leak. Matching is on **normalised** addresses on both sides, and an
  IPv4 client that a dual-stack listener reports mapped into IPv6
  (`::ffff:192.168.1.5`) matches an entry written either way — the two spellings
  are one address, and refusing the mapped one locks an operator out of their own
  console. A prefix entry must end in a dot; that is what anchors it to an octet
  boundary, so `192.16.` does not cover `192.168.1.1`. `DotServerConfig` warns
  about an entry shaped like a prefix that is missing its dot, because such an
  entry matches nothing and looks like it should.
- **`exec` refuses path traversal.** It is reachable over RCON, so its argument is
  attacker-controlled on a server whose password has leaked.
- **An authenticated player cannot override their display name**; only guests may
  name themselves. Otherwise any account can appear as "Administrator".
- **Chat is sanitised before anything else** — control characters, zero-width
  characters and bidirectional overrides are stripped, then whitespace collapsed,
  then truncated. Used to spoof names, hide text and reverse how a message renders.
- **`DotClientLink._resolve_scene` refuses absolute paths from the server** outside
  the content mount. Otherwise a malicious server could tell a client to load
  `res://addons/…` or any scene shipped in the build.
- **Admin chat is filtered server-side.** Asking clients to hide messages they are
  not entitled to see is not a control.
- **A client reporting the wrong content key is rejected**, not admitted into a world
  made of the wrong assets.

## Sharing a ban list across servers

`DotBanManager.store` is a `DotBanStore`. The default keeps bans in a JSON file on
that server, which is correct for one server and the reason it works unconfigured.
A community running eight servers wants one list — a player banned on one should not
walk into the next — so subclass it and point at a database or an HTTP service.

- **Loads may be slow; checks are not.** The loaded set is held in memory and every
  connection is answered from it, so a remote store is queried at startup and on
  writes, never on the join path.
- **A failed load keeps whatever is already in force.** Silently starting with an
  empty list readmits everyone who was ever removed.
- **`_writable() == false`** is a legitimate configuration: a server that enforces a
  centrally-managed list. `ban` then reports that rather than appearing to work and
  vanishing on the next refresh.
- **Writes are awaited before the in-memory set changes**, so a store that refuses
  does not leave a ban that exists only locally.
- **Expiry sweeping is local only.** A shared store owns its own expiry; expired bans
  are refused on read regardless.

Because writes now await, `ban_uid`, `ban_address`, `ban_session` and `unban` are
coroutines. Note that `await bans.unban(x).ok` binds the await to the property, not
the call — assign the result first.

## Somebody else's ban list: `dot_ban_source`

A deployment can keep its punishments somewhere other than `DotBanManager` —
dot-moderation is the one in this family, where a ban is the same record a mute is,
stored, expiring, scoped and revocable. Whatever registers under `dot_ban_source`
answers one method:

```gdscript
check_admission(uid: String, address: String) -> DotResult
```

`DotServer.check_address_admission` asks it with the address alone before a client has
said who it is, and `check_identity_admission` asks again with both once it has. Same
shape as `dot_mute_source`, which is how dot-moderation already meets dot-voice: one
registry name, one method, neither addon naming the other.

**A registration that cannot answer is reported once, loudly, and then ignored.** Four
call sites in this family have found a service that did not speak the method they
called, in every case with no error at all — dot-map calling `ensure` on a cloud client
that only had `acquire` is the canonical one. Ignoring it admits everybody, which is the
wrong answer; refusing everybody would take the server down, which is worse. The error
line is the fix.

**The seam is read-only, deliberately.** `ban`, `banid` and `banip` write to
`DotBanManager` — this server's own list — and `dot_ban_source` is only ever asked. A
deployment that wants dot-moderation to *be* the ban list issues bans through it
(`ban_uid` / `ban_address`, or its own console commands) and leaves `DotBanManager` empty;
a deployment on `DotBanManager` registers no source. Running both as write targets is the
two-lists problem dot-moderation's own README warns about, and a `banlist` that shows half
the bans is worse than either list alone.

**`enforce_bans()` is the other half.** A ban issued against somebody already connected
— by address, by account, or in a shared store by another server — otherwise takes
effect the next time they connect, which from the moderator's seat is indistinguishable
from the ban not working. `ban`, `banid` and `banip` all call it, which is also how an
address ban removes the other people behind that address.

## Limiting connections from one address

`sv_max_connections_per_ip` (`DotServerConfig.max_connections_per_ip`, `DotAddressGuard`),
0 by default.

**It is not a ban and not a rate limit, and neither of those covers it.** A ban answers
"may this person be here"; the connect rate limiter answers "how fast may they try".
Neither stops one machine holding twelve slots on a sixteen-slot server: the connections
arrive slowly, from nobody banned, and the server fills up with one person's clients. A
loop with a five-second sleep does it.

Three decisions in the guard that are not obvious:

- **It holds no count of its own.** It is told the addresses currently in use and counts
  them. A counter maintained by hand drifts the first time a path forgets to decrement it
  — a rejected peer, a kick, a transport that closes without a signal — and the symptom is
  a server refusing everybody from an address nobody is connected from.
- **Loopback is never limited**, or the first thing the limit does is lock the operator
  out of their own listen server, and out of every headless test.
- **An address the transport could not report is never limited.** `_address_of` returns
  `"unknown"` when the peer cannot be asked, and limiting that would put every such client
  in one bucket: a server that refuses its fourth player while looking empty.

Live rather than startup-only, because an operator turns it on while the thing it stops
is happening, and a limit that needs a restart arrives after the server has been filled.

## Naming a player

`find_sessions` is what every admin command resolves through, and the order matters:

```
#12              userid, the id `kickid` takes
12               userid
@me              the caller, when a session is asking
ip:203.0.113.9   everybody at that address — several matches on purpose
Player One       display name, exact (case-insensitive)
playerone        username from their account
backbone:abc123  account id
play             display name, substring — the only ambiguous form
```

**Every exact form is matched before the substring one**, which is what makes a player
whose whole name is another player's prefix reachable at all: naming them exactly would
otherwise match two people and be refused as ambiguous.

**`ip:` deliberately returns everybody behind the address.** An address is a household.
A command that acted on one of the three people at it without saying so is how the wrong
player gets banned, so `resolve_target` refuses the ambiguity and `banip` — which acts on
all of them by design — checks immunity against *every* session there. Without that last
check a junior admin removes a senior one by naming their housemate.

`whois` exists because an appeal, a report or a ticket names a player by their username
or their account id, and `status` shows neither.

## Moderation from chat

`ban`, `banid`, `banip`, `unban`, `banlist`, `kick`, `kickid`, `mute`, `gag`, `unmute`
and `whois` are all marked `with_chat()`, so they stay typable even on a server that set `sv_chat_commands 0`. They run through `DotConsole.execute` with the
speaker's own `DotCmdContext`, so the permission flag, the immunity check and the audit
entry are the same ones RCON gets — there is no second code path to keep in step.

Replies go to the speaker alone, and a listing from chat is **capped** (`_reply_capped`).
A `banlist` of nine hundred entries is nine hundred system messages, and the rate limiter
that stops a player flooding chat does not run on the server's own messages.

`users` is deliberately *not* chat-allowed: it has no permission flag and prints every
player's account id.

## Telling a joining client what is carrying chat

`DotChatManager.greet(session)` sends `{kind: "state", relay: bool}` to a client as it starts playing, **before** the join announcement. `announce_state()` sends it to everybody when the answer changes mid-match.

**Why a client is told at all.** A player whose lines already reach a web page they are looking at does not need a second chat box in front of the game; a player whose lines reach nothing but this server needs one badly. Only the server knows which of those is true, so only the server can say. What the client then *does* with the answer is the client's — every game here resolves it against a three-way setting of the player's own, because "the site has a chat box" and "I am looking at the site" are not the same sentence.

**`relay_fn` is a callable and `watch_relay` is duck-typed**, because dot-server must not name `DotChatRelay`: dot-chat is an optional addon and a script that mentions the class fails to compile without it. The contract is one method, `is_carrying() -> bool`, written down on `watch_relay` so five games do not each write their own version of `chat.relay_fn = relay.is_carrying`. Unset means no, which is the honest default for a server nobody told.

**It rides the chat signal rather than the handshake**, which is worth naming because the handshake looks like the obvious place. The challenge is built before a session is playing and before any module has loaded, so a relay that starts with the game would not exist yet — and the answer has to be re-sendable when a relay comes up or goes down, which a handshake is not. The cost is that a client listening on `chat_received` now sees one payload that is not a line: two games' sandbox suites assert that dot-server's own chat path delivers **nothing** beside their own wire, and both separate this one out by `kind` rather than counting it.

## Coupling: nothing is imported

dot-server works standalone. dot-auth and dot-cloud are found through `DotRegistry`
at runtime:

| Optional addon | Registry name | What happens without it |
| --- | --- | --- |
| dot-auth | `dot_auth_server` | Everyone is a guest with a per-device id. `DotGuestIdentity` provides the same duck-typed surface `DotAuthIdentity` does, so the rest of the server does not branch. |
| dot-cloud | `dot_cloud_client` | Games must ship inside the build (an absolute `scene`). A server needing downloadable content refuses the client with a clear reason. |
| dot-auth admin source | duck-typed `lookup()` / `source_name()` | File-based admins only. |
| dot-moderation | `dot_ban_source` | `DotBanManager`'s own list is the whole ban list. |

**Keep it this way.** A hard dependency in either direction makes both harder to
adopt.

## Subsystems are `DotNodeRef`s, not hardcoded children

Every subsystem on `DotServer` is an exported `DotNodeRef` defaulting to
`of_created(...)`. A bare `DotServer` works; a host project can place its own nodes,
or point two servers at one console. Nothing here hardcodes a scene path.

Note that created nodes have already run `_ready()` by the time `DotServer` sets their
`config`, so loads are triggered explicitly (`admins.load_admins()`) rather than
relying on `_ready` ordering.

## `map` was given back to dot-map

`changelevel`, `game` and `gamechange` switch the **game**. There is no `map` command here any more.

It was an alias for `changelevel` for as long as this addon had no notion of a map — every other server calls the thing that swaps what is running `map`, so operators typed both and got the right answer. dot-map exists now, and the two are not the same operation at all: **changing a game replaces the module, the netcode and the client's scene and puts everybody through signon; changing a map replaces the world and nothing else**, and happens every few minutes. An operator typing `map de_dust2` on a server running one game and a hundred maps meant the second one every time, and got a refusal naming games.

`DotMapCommands` (dot-map, `integrations/`) registers `map`, `maps` and `mapinfo` on any host with `add_command` or `command`. A deployment with no dot-map installed simply has no `map`, which is honest: there is nothing for it to change.

**This is a breaking change for an operator's muscle memory and for any script that typed `map <game_id>`.** `game` is the alias that means what `map` used to mean here, and it is marked `with_chat()` and completed from the game list exactly as `changelevel` is.

## Game switching

`DotGameManager.change_game` is: fire a cancellable `game_changing` event → tell every
client to fetch the new content → wait for all of them (or the timeout) → free the old
scene → instantiate the new one → put everyone back through `LOADING`.

**None of that had ever run.** Every game in every suite in this family ships inside its
build, none of them is delivered, and `change_game` skips the whole of
`_sync_clients` when it is — so the announce, the download, the readiness wait, the
timeout and the re-load were four hundred lines nothing had executed.
`examples/content_switch.tscn` publishes a real signed pack, boots a server with one
builtin game and one delivered one, connects a real client over a real socket and
switches between them three times. It found six, all parse-clean:

- **The server never fetched its own content.** It announced the pack, waited for every
  client to download it, then loaded `res://dot_cloud/<id>/<version>/<scene>` — a path
  that exists only because something mounted the pack, and nothing here ever did. A
  delivered game could not be loaded at all; the swap failed with "the game scene is
  missing" and restored the previous game, which reads as a typo'd scene name.
  `_acquire_content` now runs **before** the clients are told, so a server that cannot
  get the content abandons the change while nobody has been disturbed.
- **Every client was kicked the moment it did the right thing.** `report_content_ready`
  compared the key a client reported against `games.current_content_key()` — and for the
  whole of a sync that is deliberately the OLD game, because the point of the sync is
  that clients get the new content *before* the server swaps. The correct answer looked
  wrong and the client was dropped with "Your game content does not match the server's."
  `pending_content_key()` is now accepted too.
- **`LOADING -> DOWNLOADING` was not a legal transition.** A `changelevel` does not wait
  for a client to finish joining, so one that connected a second earlier is in `LOADING`
  when it arrives. The transition was refused with a single warning line, the session
  was then counted as neither ready nor waiting, the server decided everyone was synced,
  and it swapped **without ever telling that client** — which sat in the game everybody
  else had left. `SPAWNED -> DOWNLOADING` had been legal since the beginning; this is the
  same thing one step earlier.
- **A stale content key made a client look ready before it had been told.**
  `session.content_key` was never cleared when a sync began, so changing back to a game
  a client had already played matched on the first pass of the wait loop — before the
  RPC telling it to download had been processed — and the swap went out to clients still
  mid-`acquire`. On a loopback the download finishes inside the first half second and it
  looks like it worked.
- **The first client to finish downloading was told to load the old game.**
  `report_content_ready` called `_send_load_game`, and `load_info()` describes the game
  the server is *running*, which during a sync is deliberately the previous one. On a
  change between two delivered games that is a scene out of content it is about to stop
  holding.
- **The download-progress subscription was made again on every change.** A fresh lambda
  is a fresh `Callable`, so the `is_connected` guard never matched its own handler; after
  ten changes a client sent ten identical progress RPCs per tick with nothing reporting
  an error.

And one setting that decided nothing: **`swap_when_all_ready` was tested one line below
an unconditional `return` on the same condition.** The family's most repeated bug.

**`DotGameDescriptor.cvars` was the same bug one field along.** Documented as "cvars
applied when this game loads", exported, read from a descriptor by every host that
builds one — and the identifier occurred exactly once in this repository. A `cvars:`
block in a game descriptor set nothing, silently, leaving the previous game's rules
running under the new game's name.

Applying it needs two passes, and that is not an implementation detail. **dot-server
does not load a module for a game** — it changes the scene and tells whatever modules
are already loaded, deliberately, because a game with no server-side behaviour is
legitimate. So a host that ties one module to one game (`TmcHost` does) registers that
module's cvars in response to `game_loaded`, which is *after* the descriptor's cvars
would run: `sv_airaccelerate` belongs to g2gfast's module and does not exist yet on the
first pass. `_apply_descriptor_cvars` therefore treats an unregistered name as deferred
rather than wrong, reports it once as a count, and `reapply_descriptor_cvars()` is the
second pass a host makes once its module is up — where an unknown name IS wrong and is
warned about. A value that is registered and refuses its value is a warning on both
passes: no later pass makes a bad value good.

`client_state_changed` is now emitted when a change moves a session, too — the join path
emitted it at every step and the game change, which moves everybody at once, emitted
nothing, so anything reacting to the signal never saw a game change happen.

- Clients still downloading when `sync_timeout_sec` expires are **kicked** by default.
  The players who did get the content should not be denied the map change by the ones
  who could not.
- A failed change **restores the previous game**. A server with no game running is
  worse than a server on the old map.
- The old scene is `free()`d, not `queue_free()`d — the next scene is added in the same
  call, and two games in the tree means duplicate nodes, groups and physics for a
  frame.
- Releasing old content calls dot-cloud's `release()`. Godot cannot unmount a resource
  pack; version-namespaced mount paths are what make that sufficient. See dot-cloud's
  CLAUDE.md.

## A game that ships inside its build has no client scene to name

`DotGameDescriptor.client_scene_or_scene()` returns `""` for a game that is not
delivered, and that is not a convenience.

`DotClientLink._resolve_scene` refuses every absolute path that is not already inside
dot-cloud's mount prefix — correctly, because a server that could name one could ask
every client to load any scene in their build. So for a game with no downloadable
content, falling back to the server's own absolute `scene` could produce nothing but a
refusal: the client failed signon, sat in `LOADING`, sent no heartbeats and was timed
out. **A game shipped with its own client could not be joined at all.**

The empty string is the documented "you already have it" path — `report_loaded`, then
`PLAYING` — which is the shape every game shipped alongside its client actually wants.
The application then loads whatever its own build says the client is. A game delivered
through dot-cloud sets a *relative* `client_scene` instead and gets the mounted one.

**Delivered is `needs_delivered_content()`, not "has a `manifest_url`".** That was the
marker for most of this addon's life and it forced every delivered game to carry an
address — a per-deployment fact written into a per-game descriptor, re-edited on every
version bump. A relative scene path can only ever resolve against a mount, so a
descriptor carrying one has already said what it is; the id and the version say *which*
content, and `DotCloudClient.ensure` finds it against whatever bases that client has.
`manifest_url` is still honoured and still wins, for content whose client has no base
for it.

The same rule had to reach `content_key()` and `client_scene_or_scene()`, which both
read `manifest_url == ""` and both returned the empty string for a delivered game with
no URL. An empty content key is not a missing label: it is what a client reports back,
what `report_content_ready` checks, and what `DotClientLink._resolve_scene` splits to
build the mount path — so the client was told to download something with no name and
refused signon with "This server asked for content without saying what it is".

**And the client `ensure`s rather than `acquire`s.** `acquire` mounts whatever is at an
address; `ensure` is told the id and version too, so a manifest that answers to neither
is refused rather than mounted. The server is the party naming that address, so the check
is not a formality: without it a server could point a client at any published pack and
have it mount under the key the client was told to expect.

Found by `dot-2d-hungry`, whose sandbox is the first example anywhere in the family to
connect a client to a server running a real game scene.

## Server queries live in dot-server-query now

**This addon no longer answers a query, and names nothing that does.** Both
protocols, the snapshot they read from, the challenge, the provider API and the two
console commands moved to [dot-server-query](../dot-server-query) — with their whole
self-test, which is why this suite counts 224 checks where it used to count 319.

What is left here is one hook:

```gdscript
func attach_query_host(host: Object) -> DotResult
```

`DotQueryHost` calls it; `DotServer` opens it once the server is `RUNNING`, or
immediately if it is already. `query_host`, `query_source`, `query` and `a2s` are all
typed `Object` and reached with `.call(...)`, exactly as `watch_relay` reaches
dot-chat and `dot_ban_source` reaches dot-moderation.

**Why it had to be duck-typed rather than merely optional.** A script that mentions a
`class_name` the project does not have fails to parse *and takes every script
referencing it down with it*. `DotQueryHost` named anywhere in this addon would make
an optional repository mandatory for anything that so much as boots a server — the
same reasoning written down on `DotChatRelay` and `DotWeaponLoadoutBridge`.

**The configuration stayed.** `query_enabled`, `a2s_enabled`, `query_port`,
`a2s_port`, `query_bind_address`, `query_player_detail` and the rest are still
`DotServerConfig` fields, and `sv_query`, `sv_a2s` and `sv_query_players` are still
registered here before `server.cfg` runs. They are plain bools, ints and strings that
name no class, so an operator's `server.yml` keeps working unchanged and the layering
promise is unbroken — and a server with the addon absent simply has settings that
nothing reads. Moving them would have broken every deployment's config file to no
purpose.

**What a server without the addon does:** boots, runs, and answers nothing on the
query port. That is a supported configuration. `DotModule.add_query_provider` returns
a failed `DotResult` naming it, `to_stats_report()` reports 0 bots, and no
`query_status` command exists to answer "there is no query listener".

**`to_stats_report()`'s bot count still comes from a provider**, through
`_bot_count()`, which is duck-typed the same way. Nothing in dot-server can know how
many of a game's entities are bots — it never sees one connect — so zero without a
provider is honest rather than wrong.

## An addon's commands reach a dedicated server's console now

`DotConsole.add_source(source, permission, chat)` registers every name a **duck-typed**
command object claims, each as a real `DotConCommand`. `remove_source` takes them back.

```gdscript
# in the host, with dot-log installed:
server.console.add_source(DotLogCommands.new(router), DotAdminFlags.GENERIC)
```

The shape is `names()` and `execute(line)` required, `help_for(name)` and
`complete(partial, limit)` used when present — which is exactly the shape dot-console's
`DotConsoleBridge` already duck-types. That matters more than it looks: an addon implements
it **once** and reaches a client console *and* a server console, and neither console is
named in it.

**The alternative was the one this family keeps refusing.** An addon whose commands only
existed on a client is one whose whole operator surface is missing from the deployment it
was written for — dot-log shipped `log status`, `log tail`, `log targets` and `log test`,
and not one of them could be typed on a dedicated server, which is the only kind of process
that has a log worth tailing. The other way out is for each such addon to take a hard
dependency on dot-server so it can name `DotConCommand`, and then dot-log — whose only
dependency is dot-core — is unusable in a project without a server in it.

**It is not a second dispatch path**, and that is the point of wrapping rather than
forwarding. A name registered this way gets the permission check, the RCON gate, the chat
gate, the audit line, `cmdlist`, `help`, aliases, `find` and completion, because it *is* a
command. A source that claims a name somebody already has is warned and skipped rather than
overwriting: two objects answering one word is a console that runs a different command
depending on registration order, which is the bug you cannot reproduce.

**The whole line is handed over, command word included.** Every source of this shape parses
its own first word — dot-log's refuses a line that does not begin with `log` — so passing
only the arguments makes every one of them answer "not a log command".

### And it found that no argument completer had ever run

`DotConCommand.completer` is set by seven builtins — `kick`, `ban`, `gag`, `mute`, `unban`
and both game commands — each with a completer that offers connected player names or game
ids. The only thing that read it was `complete_argument`, and **`complete_argument` had no
callers anywhere in this family.** `DotConsole.complete()` matched the partial against
command names, cvar names and aliases, so `kick Bo` matched nothing and tab offered nothing
on a server that knew exactly who was connected.

`complete()` now delegates once the partial contains a space: it tokenizes, finds the
command (following an alias to what it stands for), asks its completer for the position
being completed, and puts the answer back together as a **whole line**. Whole lines because
that is the contract the callers already had — dot-console's panel replaces the input box
with the candidate it picked, so a candidate that was only the argument would delete the
command word with it. A bare word still completes names, so nothing that completed before
completes differently.

The other half of the same seam was in dot-console and is fixed there: its panel returned
early from `_complete()` on any space at all, so even a source that *did* complete arguments
was never asked. Two halves of one feature, each correct, never introduced.

The trailing space is the whole of the parsing and it is worth stating: `kick ` is argument
0 with an empty prefix, `kick Bo` is argument 0 with the prefix `Bo`. Backwards, it offers
the second argument's candidates while the first is being typed, which reads as a broken
completer rather than an off-by-one.

## Modules

`DotModule`'s `add_command` / `add_cvar` / `hook_pre` / `hook_post` helpers exist for
one reason: **a module that registers a command and is then unloaded leaves a handler
pointing at a freed object, and the console calls it.** Every helper records what it
registered so `_cleanup_registrations()` can undo it. Register through them, not
directly.

`unload_module` also calls `events.unhook_all(module)` as a backstop for modules that
hooked directly, and `reload_module` calls `GDScript.reload()` because the engine
caches scripts by path.

## Permissions for somebody who is not connected

Two questions that look like one, and the server answers both about a **uid** rather than
a session — because the thing asking may have no session to offer.

`DotAdminManager.uid_permissions(uid)` returns `{flags, immunity}` from the admin file,
merging the entry's own flags with every group it names and taking the **higher** of the
two immunities — a group is a floor an entry cannot demote below, an entry is a promotion
a group cannot cap. `uid_has_permission` now reads it rather than walking the entry a
second time; the group merge is the fiddly half and two copies of it is the shape that has
cost this tree a stale list four times.

It answers for the **local file only**, deliberately. A connected player's permissions are
the union of the file and every source, and a source such as dot-auth's needs an identity
to look anything up with — which is something only a connection carries. The file half is
the half that *can* be answered about somebody who is not here.

`DotServer.run_command_as_uid(uid, command, args, source)` is the other half: it runs a
console command as that person and hands back the reply lines. RCON has the same problem
and solves it by building a `DotCmdContext` by hand; this is that, with the difference
that matters — **the permissions on the context are the uid's own, not RCON's `ROOT`.** A
command relayed from a website, a Discord bridge or a scheduled job can therefore do
exactly what that person could do standing in the server and nothing more, and an operator
who has not made somebody an admin has not accidentally made them one by turning a relay
on. It defaults to `Source.CHAT`, which this console already documents as the least
trusted path.

## `admin_add` took a flag list where an operator types a group

The admin file has had groups since it was written — the template ships `moderator`,
`admin` and `owner` — and `set_admin` has always taken a group array. `admin_add` passed
an **empty one**, so the one word somebody would actually type was parsed as a flag.

Nothing errored, which is the whole problem. `DotAdminFlags.parse` accepts any token and
`_warn_about_unknown_flags` only warns — deliberately, because a game defines its own
flags — so `admin_add <uid> moderator` created an admin holding a flag called
"moderator" that grants nothing at all, and the only trace was a log line that reads like
a typo nobody made. Worse, `admin` is *both* a real flag and a group name in the shipped
template, so that spelling silently meant something quite different from what the file
would have meant by it.

It resolves a group first and falls back to flags, and refuses a single token matching
neither — listing the groups it does know. The refusal cannot be "unknown flag", because
an unknown flag is legal here; it is "this is not a group and not any flag I ship", which
is a misspelled group far more often than it is a new one.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# 287 checks. Exits non-zero on any failure. (Was 319 before the query
# protocols and their 95 checks moved to dot-server-query.)
godot --headless --path . res://examples/dedicated_server.tscn

# 40 checks. The two RPC sets match, the revision is derived, a real join carries it,
# a DotNotice crosses a real socket whole, and a mismatch is refused in words.
godot --headless --path . res://examples/signon_revision.tscn

# 46 checks, the last of which compares the total. A real client, a real socket, and a game that is actually DELIVERED:
# publish a signed pack, changelevel into it, back out, and in again.
godot --headless --path . res://examples/content_switch.tscn

# Run it as an actual server instead of self-testing:
godot --headless --path . res://examples/dedicated_server.tscn -- --serve
```

**`content_switch` is the one that reaches the content path**, and it is separate from
the self-test because it needs two `MultiplayerAPI` instances, a socket and dot-cloud.
The self-test covers console parsing (quoting, semicolons, aliases, suggestions),
every cvar flag, permission and immunity enforcement, chat-source gating, config
execution including traversal refusal, the command buffer and `wait`, ban durations
and expiry, admin flag parsing, event cancel/rewrite, module load *and clean unload*,
and the audit trail. It does not cover the client handshake — that needs two
processes.

**The query protocols are covered in dot-server-query's own suite**, not here — 164
checks, including the hook in both directions: a host that attaches before the server
has booted and one that attaches after it is already running.

**The example set `startup_config = ""`** on purpose: the addon ships a default
`server.cfg` that the search path finds, which is correct layering but would make the
test assert against whatever that file contains. That mismatch is what the first run
caught.

## File map

```
addons/dot_server/
  console/
    dot_convar.gd            Values as strings; flags enforced here.
    dot_concommand.gd        Permission, arg bounds, rcon/chat opt-in.
    dot_cmd_context.gd       Who is calling, and where replies go.
    dot_console.gd           Registry, buffer, cfg execution, completion.
    dot_builtin_commands.gd  The whole command surface, in one readable list.
  server/
    dot_server_config.gd     Boot config. validate() enforces the invariants.
    dot_client_session.gd    The signon state machine. Read this one.
    dot_guest_identity.gd    Stand-in identity when dot-auth is absent.
    dot_server.gd            Lifecycle, sessions, handshake RPCs, timeouts, tick.
  client/
    dot_client_link.gd       The client's half. RPC names must match the server.
    dot_client_chat.gd       The client's chat node, mirroring DotChatManager.
  net/
    dot_signon.gd            The RPC set as twelve characters both ends compare.
    dot_notice.gd            A HUD line, a countdown, a cue. The wire form is here.
  admin/
    dot_admin_flags.gd       Flags + immunity. Why flags, not roles.
    dot_admin_manager.gd     Resolution, merging, pluggable sources.
  moderation/
    dot_ban_manager.gd       Account and address bans, durations, expiry-on-read.
    dot_address_guard.gd     How many clients one address may hold at once.
    dot_audit_log.gd         JSONL, flushed per entry.
  rcon/
    dot_rcon_server.gd       Classic RCON protocol + WebSocket. Read the class doc.
  chat/
    dot_chat_manager.gd      Routing, flood control, sanitising, chat triggers.
  game/
    dot_game_descriptor.gd   One game. Scene paths resolve under the mount prefix.
    dot_game_manager.gd      The change flow.
  vote/
    dot_vote_manager.gd      Quorum, thresholds, per-player cooldowns.
  events/
    dot_event.gd             One event; pre-hooks may rewrite or cancel it.
    dot_event_bus.gd         Hooks, flood guard, declared event list.
  modules/
    dot_module.gd            Base class. The helpers are not optional.
    dot_module_host.gd       Load, unload, reload.
  cfg/
    server.cfg               Shipped defaults. Copy to user://cfg and edit that.
    autoexec.cfg
```

## Things deliberately not here

- **Serving content in-band.** dot-cloud's `DotCloudSourceNetchan` is the client half
  and expects a server exposing `cloud_chunk_size()` / `cloud_request_chunk()`; nothing
  here does. `allow_netchan_content`, `netchan_chunk_bytes` and
  `netchan_chunks_per_second` are declared, sent to clients, and enforced by nothing —
  their docs say so. When it lands, the rate limit is the security control.
- **State replication.** dot-server gets a player from "typed an address" to "in the
  world" and hands over. Snapshots, interpolation, prediction and lag compensation are
  a game's own concern, and a framework opinion there would be wrong for most games.
  `DotTransport.Channel.STATE` is reserved for it.
- **Master-server heartbeat.** `sv_lan` exists and does nothing yet. Nothing
  announces this server anywhere; a tracker has to be told the address. With
  dot-server-query installed, both protocols answer once it has been.
- **Answering a query at all.** dot-server-query does that, and dot-browser asks.
- **A listen server helper.** Running `DotServer` and `DotClientLink` in one process
  works — that is why there are no autoloads — but nothing wraps the pattern up.
