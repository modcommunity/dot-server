@tool
extends DotConfig

## The exported settings of DotServerConfig, in the order the inspector shows them.

@export_group("Identity")

## Name shown in server listings and `status`.
@export var hostname: String = "A dot server"

## Identifier this server is known by; the audience for dot-auth connect tickets, so it must match the issuer's [member DotAuthConfig.server_id].
@export var server_id: String = ""

## Free-form tags for listings.
@export var tags: PackedStringArray = PackedStringArray()

@export_group("Network")

## Port to listen on. 0 lets the OS pick one (tests, several instances per box); that requires an explicit [member rcon_port]
## and nothing told a fixed address can reach it.
@export_range(0, 65535, 1) var port: int = 27015

## Interface to bind. [code]*[/code] means every interface.
@export var bind_address: String = "*"

## Transport. When unset, [member transport_mode] builds one.
## [b]Most likely to be wrong[/b]: ENet alone cannot accept browsers and nothing looks misconfigured.
## Leave unset unless [member transport_mode] cannot describe what you need.
@export var transport: DotTransport = null

## What [method resolve_transport] builds when [member transport] is unset: [code]dual[/code] (WebSocket for browsers plus ENet
## on [method effective_enet_port], see [DotTransportDual]; WebSocket only where ENet or UDP is missing), [code]websocket[/code], or [code]enet[/code] (no browsers).
@export_enum("dual", "websocket", "enet") var transport_mode: String = "dual"

## UDP port native clients reach ENet on. 0: the game port's number (TCP and UDP are separate namespaces).
## Shared with A2S/DQP through [DotUdpDemux]; see [member enet_share_udp_port].
@export_range(0, 65535, 1) var enet_port: int = 0

## Interface ENet's UDP port binds. Empty: the query listeners' interface ([method effective_query_bind_address]),
## because a reverse-proxied server needs its UDP facing the world as its queries do; nginx cannot carry UDP.
@export var enet_bind_address: String = ""

## Share one UDP port between ENet and A2S/DQP on the same number. Off: ENet binds it itself and
## A2S/DQP must be moved ([member a2s_port], [member query_port]) or fail to bind.
@export var enet_share_udp_port: bool = true

@export_range(1, 4096, 1) var max_players: int = 32

## Slots kept for players with the [constant DotAdminFlags.RESERVATION] flag.
## Counted inside [member max_players]: 32 slots with 2 reserved fill up for the public at 30.
@export_range(0, 64, 1) var reserved_slots: int = 0

## Password clients must send. Empty means none.
@export var password: String = ""

## Server ticks per second. Higher costs server CPU and bandwidth and reduces input latency.
@export_range(10, 240, 1) var tickrate: int = 60

@export_group("Timeouts")

## Seconds a client may spend authenticating before it is dropped.
@export_range(5.0, 300.0, 5.0) var auth_timeout_sec: float = 60.0

## Seconds a client may spend in the PROFILE stage, held by a module, before it is dropped.
## Its own number: a profile store or first avatar can take minutes. Ceiling for a module that never releases.
@export_range(5.0, 1800.0, 5.0) var profile_timeout_sec: float = 300.0

## Seconds a client may spend downloading content. Generous: a timeout that fires on a working download is worse than none.
@export_range(30.0, 7200.0, 30.0) var download_timeout_sec: float = 1800.0

## Seconds a client may spend loading after content is present.
@export_range(5.0, 600.0, 5.0) var load_timeout_sec: float = 120.0

## Seconds without a packet before a spawned client is dropped.
@export_range(5.0, 600.0, 5.0) var client_timeout_sec: float = 60.0

## Seconds of silence allowed a client whose tab is in the background (a browser stops the main loop, socket open).
## The client asks for a budget and this is the ceiling; 0 refuses grace. [b]Keep it to minutes[/b]: sends keep queueing.
@export_range(0.0, 1800.0, 15.0) var background_grace_max_sec: float = 300.0

@export_group("Hibernation")

## Reduce tick processing when nobody is connected (cvar `sv_hibernate_when_empty`, live).
## [b]On[/b]: ticks at [member hibernate_tickrate] and [signal DotServer.hibernation_changed] clocks wait for a joiner.
## [b]Off[/b]: clocks run, and with nobody to vote dot-vote draws the next map at random.
@export var hibernate_when_empty: bool = true

## Ticks per second while hibernating.
@export_range(1, 60, 1) var hibernate_tickrate: int = 5

@export_group("Threads")

## Worker threads each subsystem may use (cvar [code]sv_worker_threads[/code], live). -1: processors less one, at most eight; 0: main thread.
## Nothing is threaded until its own switch below is on.
@export_range(-1, 64) var worker_threads: int = -1

## Build each player's snapshot on the workers (cvar [code]sv_threads_net[/code]). Off by default.
## The game's wiring copies [method net_snapshot_workers] into [code]DotNetConfig.snapshot_workers[/code]; dot-net does not depend on this addon.
@export var threads_net: bool = false

## Run NPC decisions and path searches on the workers (cvar [code]sv_threads_npc[/code], live), for brains that
## say they can. Off by default; read through [method npc_workers].
@export var threads_npc: bool = false

## Build snapshots in dot-net's native core (cvar [code]net_native[/code], live). On by default (GDScript costs about 9 times as much at 100 players);
## the game's wiring ORs it into [code]DotNetConfig.native[/code], and dot-net falls back to GDScript and logs why where the library cannot load.
@export var net_native: bool = true

## Also run the interest phase in the native core (cvar [code]net_native_interest[/code]; needs [member net_native]). On by default.
## A strategy the core cannot port exactly (a subclass, a grid, always-on tags) stays in GDScript.
@export var net_native_interest: bool = true

## Frames per second while hibernating, on a headless server. NOT the tickrate.
## Sockets are read once per frame, so 5 fps answered queries up to 200 ms late and empty servers looked worst in a browser.
## Measured: 0.1% of one core at 5 frames, 0.5% at 60, answers in 3 ms.
@export_range(1, 240, 1) var hibernate_frame_rate: int = 60

@export_group("RCON")

## Password for remote console. [b]Empty disables RCON[/b], not "no password": a passwordless listener is a remote shell.
@export var rcon_password: String = ""

## TCP port for RCON. 0 uses [member port] + 1.
@export var rcon_port: int = 0

## Read the server's own terminal and run what is typed. Harmless with nothing to read: [DotStdinConsole] reads only a terminal
## or regular file. Turn off for a server whose stdin carries something that is not commands.
@export var stdin_console_enabled: bool = true

## Read stdin even when it is a pipe, socket or `/dev/null`. Off: the reader blocks in a read nothing can cancel and a pipe
## whose writer never closes hangs exit. On for a supervisor feeding commands down a pipe; see [member DotStdinConsole.read_pipes].
@export var stdin_console_pipes: bool = false

## Also serve RCON over WebSocket, for browser admin panels. Same authentication and rate limits.
@export var rcon_websocket: bool = false

@export var rcon_websocket_port: int = 0

## Addresses allowed to use RCON. Empty allows any. Worth populating: it survives a leaked password.
@export var rcon_allowed_addresses: PackedStringArray = PackedStringArray()

## Failed RCON authentications before an address is locked out.
@export_range(1, 100, 1) var rcon_max_failures: int = 5

## Seconds an address is locked out for.
@export_range(10.0, 86400.0, 10.0) var rcon_lockout_sec: float = 600.0

@export_group("Query")

## Answer the dot query protocol. Safe on by default: every UDP query gets an address-bound challenge before any payload,
## and it is rate limited per address. Read by dot-server-query's DQP listener, a separate addon.
@export var query_enabled: bool = true

## Interface the query listeners bind, when not [member bind_address]. Empty: the game's interface.
## A server behind a reverse proxy binds the game to loopback, and a proxy cannot forward UDP, so the query port
## would be unreachable. Applies to dot query, its WebSocket and A2S; deliberately not RCON.
@export var query_bind_address: String = ""

## UDP port for queries. 0 uses [member a2s_port]'s effective value ([member port]), so both protocols share a socket
## (told apart by their first four bytes). Set only when a UDP game transport (ENet) already holds the game port.
@export var query_port: int = 0

## Also serve queries over WebSocket, as plain JSON, for an in-browser server browser (a page cannot open UDP).
## Off by default: it is a second listener.
@export var query_websocket: bool = false

## TCP port for the WebSocket query listener. 0 uses [member port] + 3.
@export var query_websocket_port: int = 0

## How much of the player list a query may see. [code]full[/code] adds userid, ping, bot and signon state to A2S's
## name, score and duration ([code]names[/code]); [code]count[/code] gives the number only; [code]none[/code] refuses the section.
## Never an account uid; see dot-server-query.
@export_enum("full", "names", "count", "none")
var query_player_detail: String = "full"

## Publish server variables in the [code]rules[/code] section.
@export var query_rules: bool = true

## Extra cvars to publish beyond the notify/replicated ones. Protected and hidden cvars are refused regardless.
@export var query_extra_rules: PackedStringArray = PackedStringArray()

## Seconds a challenge cookie stays valid. The real window is up to twice this.
@export_range(5.0, 300.0, 5.0) var query_challenge_ttl_sec: float = 30.0

## Queries answered per address per second, sustained.
@export_range(0.1, 100.0, 0.1) var query_rate_per_second: float = 2.0

## Queries an address may burst before the sustained rate applies.
@export_range(1.0, 200.0, 1.0) var query_rate_burst: float = 10.0

## Seconds a snapshot is reused before it is rebuilt: a thousand queries in a second cost one walk of the session table.
@export_range(0.0, 60.0, 0.1) var query_cache_sec: float = 1.0

## Most players listed in one response.
@export_range(1, 4096, 1) var query_max_players_listed: int = 128

## Shared secret for signing query responses. Empty disables signing.
## For a listing service that must know this server really said it.
@export var query_secret: String = ""

@export_group("A2S")

## Answer the A2S query protocol as well. Off by default: a compatibility shim for old trackers, bots and uptime monitors,
## worth having when being listed matters. See dot-server-query's A2S listener, a separate addon.
@export var a2s_enabled: bool = false

## UDP port for A2S. 0 uses [member port], which is where every tracker looks.
@export var a2s_port: int = 0

## Application id reported in A2S_INFO. 0 for a game that has none.
@export var a2s_app_id: int = 0

## Short folder name, as A2S calls it. Slug-ish, and shown by some tools.
@export var a2s_game_folder: String = "dot"

## Game description shown in listings. Empty uses the current game's display name.
@export var a2s_game_description: String = ""

@export_group("Configuration files")

## Config executed at boot, before the listener opens.
@export var startup_config: String = "server.cfg"

## Config executed after the listener opens.
@export var autoexec_config: String = "autoexec.cfg"

## Config executed after each game change, for per-game overrides.
@export var game_config_prefix: String = "game_"

@export_group("Admin")

## File defining admins and groups.
@export var admins_path: String = "user://cfg/admins.json"

## Reload the admin file when it changes on disk, so an operator can promote somebody without a restart. A modification-time check on a timer.
@export var admins_auto_reload: bool = true

@export_group("Logging")

## The level below which nothing is emitted: trace, debug, info, warn, error, fatal, off.
## [code]info[/code] is the level a server is meant to run at; [code]debug[/code] is per-decision and not one to leave on.
@export var log_level: String = "info"

## Per-channel overrides, as [code]channel=level[/code]. A global level is rarely right: DEBUG for one download also turns on
## every physics and RPC trace. [code]--sv-log-channel-levels cloud=debug[/code] turns up one subsystem.
@export var log_channel_levels: PackedStringArray = PackedStringArray()

## The lowest level mirrored into the engine's own warning and error output. [b]error, and lowering it has a cost[/b]:
## the engine appends a full GDScript backtrace to every push_warning and push_error in a debug build, so at [code]warn[/code]
## expected warnings read like a crash. The one-line [code]WRN[/code] carries the same message.
@export var log_mirror_min_level: String = "error"

## Write the log to a file as well as stdout: stdout is gone when the supervisor rotates or restarts, the file is not.
@export var log_file_enabled: bool = true

## Directory for log files.
@export var log_directory: String = "user://logs"

## Base name. A timestamp and [code].log[/code] are appended, so a directory listing is in chronological order.
@export var log_basename: String = "server"

## One JSON object per line instead of the human format. Off: the reader is a person over SSH. On for a box where something tails the file.
@export var log_json: bool = false

## Rotate once a file passes this size. 0 disables size rotation.
@export var log_max_file_bytes: int = 16 * 1024 * 1024

## Log files to keep, oldest deleted first. 0 keeps everything. [b]Not zero[/b]: an unbounded log directory is the usual way a game server fills a disk.
@export var log_max_files: int = 10

@export_group("Moderation")

@export var bans_path: String = "user://cfg/bans.json"

## Audit log of every administrative action. Separate from the general log because moderation disputes are resolved from it.
@export var audit_log_path: String = "user://logs/audit.jsonl"

## Announce administrative actions in chat. On by default: visible moderation deters, and players who see a cheater removed stop reporting.
@export var announce_admin_actions: bool = true

## Most simultaneous connections from one address. 0 removes the limit. Neither a ban nor the connect rate limiter covers a slow
## trickle that fills a small server. See [DotAddressGuard] for why the default is off (households, universities, CGNAT).
@export_range(0, 64, 1) var max_connections_per_ip: int = 0

## Addresses the per-address limit never applies to, on top of loopback (a LAN party, an office, a known NAT).
@export var connection_limit_exempt_addresses: PackedStringArray = PackedStringArray()

@export_group("Chat")

## Prefixes that turn a chat message into a command.
@export var chat_command_prefixes: PackedStringArray = PackedStringArray(["!", "/"])

## Whether a prefixed chat message reaches commands that have not said either way. [b]On[/b]: chat runs the same permission
## check as the console. Off narrows chat to commands marked `with_chat()`. The cvar is `sv_chat_commands`.
@export var chat_commands_open: bool = true

## Chat messages allowed per player per minute.
@export_range(1, 240, 1) var chat_rate_per_minute: int = 20

## Longest chat message accepted, in characters.
@export_range(16, 2048, 16) var chat_max_length: int = 256

@export_group("Content")

## Manifest URL for the game clients should load on connect. Empty means none.
@export var content_manifest_url: String = ""

## Where a client should fetch this server's content from, best first; sent to every client at the handshake, because a shipped
## build can only guess the page's origin, wrong for content on a CDN. Clients try their own bases first. Nothing here is trusted:
## a manifest still needs a signature from a key the CLIENT trusts. The host sets it from the same setting as its content client.
@export var content_base_urls: PackedStringArray = PackedStringArray()

## Let clients fetch content over the game connection when they cannot reach the content host. Costs bandwidth; see [DotCloudSourceNetchan].
@export var allow_netchan_content: bool = true

## Bytes per in-band content chunk.
@export_range(1024, 262144, 1024) var netchan_chunk_bytes: int = 65536

## In-band content chunks a client may request per second, so a download cannot starve gameplay or amplify bandwidth.
## [b]Reserved[/b]: the server does not serve chunks yet (CLAUDE.md, "Things deliberately not here"); this and [member netchan_chunk_bytes] are enforced by nothing.
@export_range(1, 512, 1) var netchan_chunks_per_second: int = 32
