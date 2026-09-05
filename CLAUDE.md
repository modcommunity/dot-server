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
everything else — because a `+map` or a `+say` genuinely does need the server up
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
     modules, rcon, query + a2s)
  -> LISTENER OPENS                               <- FLAG_STARTUP_ONLY locks here
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
four that can disagree. Commands opt into chat (`chat_allowed`, off by default) and
out of RCON (`rcon_allowed`).

## Permissions

Flags, not roles, because operators do not agree on what a "moderator" is. Strings,
not bits, so a game adds `"slay"` or `"noclip"` without coordinating with
`DotAdminFlags` or running out of bits. Unknown flags are **reported, not refused** —
they are legal for a game and also what a typo looks like.

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
and `whois` are all `chat_allowed`. They run through `DotConsole.execute` with the
speaker's own `DotCmdContext`, so the permission flag, the immunity check and the audit
entry are the same ones RCON gets — there is no second code path to keep in step.

Replies go to the speaker alone, and a listing from chat is **capped** (`_reply_capped`).
A `banlist` of nine hundred entries is nine hundred system messages, and the rate limiter
that stops a player flooding chat does not run on the server's own messages.

`users` is deliberately *not* chat-allowed: it has no permission flag and prints every
player's account id.

## Coupling: nothing is imported

dot-server works standalone. dot-auth and dot-cloud are found through `DotRegistry`
at runtime:

| Optional addon | Registry name | What happens without it |
| --- | --- | --- |
| dot-auth | `dot_auth_server` | Everyone is a guest with a per-device id. `DotGuestIdentity` provides the same duck-typed surface `DotAuthIdentity` does, so the rest of the server does not branch. |
| dot-cloud | `dot_cloud_client` | Games must ship inside the build (`manifest_url` empty). A server needing downloadable content refuses the client with a clear reason. |
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

## Game switching

`DotGameManager.change_game` is: fire a cancellable `game_changing` event → tell every
client to fetch the new content → wait for all of them (or the timeout) → free the old
scene → instantiate the new one → put everyone back through `LOADING`.

**None of that had ever run.** Every game in every suite in this family ships inside its
build, `manifest_url` is empty for all of them, and `change_game` skips the whole of
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

`DotGameDescriptor.client_scene_or_scene()` returns `""` when there is no
`manifest_url`, and that is not a convenience.

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

Found by `dot-2d-hungry`, whose sandbox is the first example anywhere in the family to
connect a client to a server running a real game scene.

## Server queries

Two protocols answering the same question, from the same `DotQuerySnapshot`, on the
same UDP socket. `addons/dot_server/query/PROTOCOL.md` is the wire spec; what follows
is why it is shaped that way.

**A2S is a compatibility shim and is off by default.** It is a packed byte layout
with positional fields, a multi-packet format that differs between engine branches,
no room for anything a game knows about itself, and — until 2020 — no defence against
being used as a DDoS amplifier. What it has is twenty years of tooling: every
server-list site, chat bot and uptime monitor speaks it and nothing else. That is
the whole case for it, and it is enough.

**DQP is the one to reach for**, and is on by default. JSON in a fixed 26-byte
envelope, sections requested à la carte, a revision that makes polling nearly free,
and — the part A2S can never have — a WebSocket variant, because a web page cannot
open a UDP socket and "click a link and play" needs a server list for the link to
come from.

**Both listen on the game port by default, and share one socket.** That is the only
port a tracker will try, and two listeners cannot bind one UDP port, so `DotQueryServer`
owns it and hands over anything starting `FF FF FF FF`. A UDP game transport (ENet)
already holds that port; the bind fails and says so.

### The controls, and what each one is for

- **An address-bound challenge, always, before any payload is built.** UDP source
  addresses are forged trivially and a query is a small request producing a large
  response — the exact shape of an amplifier. The cookie is
  `HMAC(secret, address|port|bucket|width)` and **nothing is stored**: a challenge
  table is itself a memory-exhaustion target. Same reasoning as a SYN cookie. The
  unchallenged reply is smaller than the request that provoked it.
- **The snapshot cache is a security control, not an optimisation.** Gathering one
  walks every session and every cvar. Per packet, that is the cheapest denial of
  service there is, and unlike a flood of game traffic it needs no connection.
- **An oversized response is refused, not truncated.** A body cut off mid-JSON
  reaches the querier as a parse failure they read as a broken server, and the fix —
  ask for fewer sections — is something only they can do.
- **A response arriving on the listening socket is never answered.** That is how two
  servers become a reflection loop.
- **`FLAG_PROTECTED` and `FLAG_HIDDEN` cvars are never published**, including when an
  operator names one in `query_extra_rules`. The flag exists precisely because that
  value must not leave the server.
- **No player detail setting ever emits an account uid.** dot-user's point is that an
  operator cannot correlate their players across servers; publishing the identifier
  to anyone who sends a datagram would undo that from the other direction.

### Bugs the first run found, both parse-clean

- **One flag bit with two meanings.** `FLAG_GZIP` meant "I accept gzip" on a request
  and "this is gzipped" on a response, on the reasoning that a request is never
  compressed so the bit was free. It made the header un-parseable without already
  knowing which direction the packet was going: the parser reads the header to find
  that out, so it tried to gunzip a plaintext request body and failed. Every query
  was silently dropped. `FLAG_ACCEPT_GZIP` is now its own bit.
- **A fragment is not independently decodable.** `parse()` gunzipped and
  JSON-parsed whatever payload it was handed, so reading a fragment's header — which
  is exactly what reassembly does first — logged two engine errors on a completely
  normal path. Nothing failed; it just looked broken in every log it appeared in.

### Where a game plugs in

`DotQueryProvider`, registered with `DotQuerySource.add_provider` — or
`DotModule.add_query_provider`, which removes it on unload, because a provider left
behind by an unloaded module is called on the next query with `self` pointing at a
freed object.

**The bot count is the case that proves it.** Nothing in dot-server can know it — a
bot is a game concept and the server never sees one connect — so it reaches A2S's bot
byte, DQP's `info.bots` *and* the backbone stats report only through a provider.
`to_stats_report()` no longer hardcodes zero.

## Modules

`DotModule`'s `add_command` / `add_cvar` / `hook_pre` / `hook_post` helpers exist for
one reason: **a module that registers a command and is then unloaded leaves a handler
pointing at a freed object, and the console calls it.** Every helper records what it
registered so `_cleanup_registrations()` can undo it. Register through them, not
directly.

`unload_module` also calls `events.unhook_all(module)` as a backstop for modules that
hooked directly, and `reload_module` calls `GDScript.reload()` because the engine
caches scripts by path.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# 303 checks. Exits non-zero on any failure.
godot --headless --path . res://examples/dedicated_server.tscn

# 41 checks. A real client, a real socket, and a game that is actually DELIVERED:
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

**Both query protocols are covered end to end without a socket.** `handle_datagram`
takes a datagram and returns the datagrams to send back, so the self-test drives the
whole of DQP and A2S — challenge binding, fragmentation, gzip, conditional polling,
reflection refusal, rate limiting, and every A2S response read back field by field by
a reader that behaves like a real client. Both bugs above were found by that, and
neither produced a parse error. The listeners still bind for real in the example
(A2S on 27056, DQP sharing it), so the shared-socket path is exercised too.

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
  admin/
    dot_admin_flags.gd       Flags + immunity. Why flags, not roles.
    dot_admin_manager.gd     Resolution, merging, pluggable sources.
  moderation/
    dot_ban_manager.gd       Account and address bans, durations, expiry-on-read.
    dot_address_guard.gd     How many clients one address may hold at once.
    dot_audit_log.gd         JSONL, flushed per entry.
  rcon/
    dot_rcon_server.gd       Classic RCON protocol + WebSocket. Read the class doc.
  query/
    PROTOCOL.md              The wire spec. Enough to write a client in any language.
    dot_query_challenge.gd   Stateless address-bound cookies. The anti-amplifier.
    dot_query_protocol.gd    DQP framing: header, flags, fragments, gzip.
    dot_query_snapshot.gd    What the server looks like from outside, at one moment.
    dot_query_source.gd      Builds and caches it; where providers are registered.
    dot_query_provider.gd    Where a game contributes its own state.
    dot_query_server.gd      DQP over UDP, and over WebSocket for browsers.
    dot_a2s_server.gd        A2S. Compatibility, and off by default.
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
  announces this server anywhere; a tracker has to be told the address. Both query
  protocols answer once it has been.
- **A query client.** dot-server answers queries and does not ask them, so there is
  no server browser here — `PROTOCOL.md` has enough to write one, and `dot-ui` is
  where the screen would live.
- **Delta responses.** `if_rev` answers "unchanged" or resends the whole thing. A
  patch between two revisions would be smaller again and is not worth the complexity
  until something is polling enough servers to notice.
- **A listen server helper.** Running `DotServer` and `DotClientLink` in one process
  works — that is why there are no autoloads — but nothing wraps the pattern up.
