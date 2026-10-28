@tool
extends DotConfig

## The exported settings of DotServerConfig, in the order the inspector shows them.

@export_group("Identity")

## Name shown in server listings and `status`.
@export var hostname: String = "A dot server"

## Identifier this server is known by.
##
## Used as the audience for dot-auth connect tickets, so it must match what the
## issuer mints for — see [member DotAuthConfig.server_id].
@export var server_id: String = ""

## Free-form tags for listings.
@export var tags: PackedStringArray = PackedStringArray()

@export_group("Network")

## Port to listen on.
##
## 0 lets the OS pick a free one, which is what you want for tests and for running
## several instances on one box without assigning ports by hand. A server on an
## ephemeral port cannot be found by anything that was told a fixed address, so it
## is not useful for a real deployment — and it requires an explicit
## [member rcon_port], since there is no fixed port to derive one from.
@export_range(0, 65535, 1) var port: int = 27015

## Interface to bind. [code]*[/code] means every interface.
@export var bind_address: String = "*"

## Transport. When unset, [member transport_mode] builds one.
##
## [b]This is the setting most likely to be wrong.[/b] A server that picks ENet
## alone cannot accept browser clients at all, and nothing about the server looks
## misconfigured when that happens. Leave it unset unless you need a transport
## [member transport_mode] cannot describe.
@export var transport: DotTransport = null

## What [method resolve_transport] builds when [member transport] is unset.
##
## [code]dual[/code] (the default): WebSocket on TCP [member port] for browsers AND
## ENet on UDP [method effective_enet_port] for native clients, in one match — see
## [DotTransportDual]. Falls back to WebSocket only where this build has no ENet or
## UDP. [code]websocket[/code]: every client on WebSocket, the behaviour before dual
## existed. [code]enet[/code]: native clients only, no browsers.
@export_enum("dual", "websocket", "enet") var transport_mode: String = "dual"

## UDP port native clients reach ENet on. 0: the game port's number — TCP and UDP
## are separate namespaces, so WebSocket and ENet share [member port] for free.
##
## When A2S or the dot query protocol answer on the same UDP port (the default),
## the port is shared through [DotUdpDemux]; see [member enet_share_udp_port].
@export_range(0, 65535, 1) var enet_port: int = 0

## Interface ENet's UDP port binds. Empty: the query listeners' interface
## ([method effective_query_bind_address]), because ENet shares their port by default
## and because a reverse-proxied server — WebSocket on loopback behind nginx — needs
## its UDP facing the world exactly as its queries do. nginx cannot carry UDP.
@export var enet_bind_address: String = ""

## Share one UDP port between ENet and A2S/DQP when they are configured onto the
## same number. Off: ENet binds its port itself and A2S/DQP must be moved
## ([member a2s_port], [member query_port]), or they fail to bind.
@export var enet_share_udp_port: bool = true

@export_range(1, 4096, 1) var max_players: int = 32

## Slots kept for players with the [constant DotAdminFlags.RESERVATION] flag.
##
## Counted inside [member max_players], as every server does it: a 32-slot server with 2
## reserved fills up for the public at 30.
@export_range(0, 64, 1) var reserved_slots: int = 0

## Password clients must send. Empty means none.
@export var password: String = ""

## Server ticks per second.
##
## The rate at which authoritative state is stepped and broadcast. Higher costs CPU
## and bandwidth on the server and reduces input latency for players.
@export_range(10, 240, 1) var tickrate: int = 60

@export_group("Timeouts")

## Seconds a client may spend authenticating before it is dropped.
@export_range(5.0, 300.0, 5.0) var auth_timeout_sec: float = 60.0

## Seconds a client may spend in the PROFILE stage, held by a module, before it is dropped.
## Its own number: a profile store or a first avatar can take minutes. It is the ceiling on a module
## that never releases, not the module's own deadline. Unused when no module holds.
@export_range(5.0, 1800.0, 5.0) var profile_timeout_sec: float = 300.0

## Seconds a client may spend downloading content.
##
## Generous: this covers a full content download on whatever connection the player
## has, and a timeout that fires on a working download is worse than no timeout.
@export_range(30.0, 7200.0, 30.0) var download_timeout_sec: float = 1800.0

## Seconds a client may spend loading after content is present.
@export_range(5.0, 600.0, 5.0) var load_timeout_sec: float = 120.0

## Seconds without a packet before a spawned client is dropped.
@export_range(5.0, 600.0, 5.0) var client_timeout_sec: float = 60.0

## Seconds of silence allowed a client that has announced its tab is in the background.
##
## A browser stops the main loop for a hidden tab: no heartbeat, no reads, socket open. The
## client asks for a budget and this is the ceiling; 0 refuses grace entirely.
## [b]Keep it to minutes[/b]: the server keeps queueing sends to a client that is not reading.
@export_range(0.0, 1800.0, 15.0) var background_grace_max_sec: float = 300.0

@export_group("Hibernation")

## Reduce tick processing when nobody is connected (cvar `sv_hibernate_when_empty`, live).
##
## [b]On (the default)[/b], an empty server ticks at [member hibernate_tickrate] and whatever
## follows [signal DotServer.hibernation_changed] (a map's time limit, a vote's clock) waits
## and restarts from its configured value when somebody joins.
## [b]Off[/b], its clocks run, and with nobody to vote dot-vote draws the next map at random
## ([code]DotVoteRules.empty_choice[/code]).
@export var hibernate_when_empty: bool = true

## Ticks per second while hibernating.
@export_range(1, 60, 1) var hibernate_tickrate: int = 5

@export_group("Threads")

## Worker threads each subsystem this server turns on may use (cvar [code]sv_worker_threads[/code], live).
## -1 is the processor count less one, at most eight; 0 sends every subsystem back to the main thread.
## Nothing is threaded until its own switch below is on. A server's settings, not the process's.
@export_range(-1, 64) var worker_threads: int = -1

## Build each player's snapshot on the workers (cvar [code]sv_threads_net[/code], live from the
## next snapshot). Off by default. The game's wiring copies [method net_snapshot_workers] into
## dot-net's [code]DotNetConfig.snapshot_workers[/code]; dot-net does not depend on this addon.
@export var threads_net: bool = false

## Run NPC decisions and path searches on the workers (cvar [code]sv_threads_npc[/code], live
## from the next tick), for the brains that say they can. Off by default; read through
## [method npc_workers].
@export var threads_npc: bool = false

## Build snapshots in dot-net's native core (cvar [code]net_native[/code], live from the next
## snapshot). On by default (the GDScript path costs about 9 times as much at 100 players); the game's wiring ORs it into [code]DotNetConfig.native[/code], and
## where the library cannot load dot-net falls back to GDScript and logs why.
@export var net_native: bool = true

## Also run the interest phase (relevance, scores, cap, budget) in the native core (cvar
## [code]net_native_interest[/code]; needs [member net_native]). On by default. A strategy the core
## cannot port exactly (a subclass, a grid, always-on tags) stays in GDScript.
@export var net_native_interest: bool = true

## Frames per second while hibernating, on a headless server. NOT the tickrate.
## Every socket is read once per frame, so at 5 fps a query answered up to 200 ms late made empty servers
## look worst in a browser. Measured hibernating: 0.1% of one core at 5 frames, 0.5% at 60, answers in 3 ms.
@export_range(1, 240, 1) var hibernate_frame_rate: int = 60

@export_group("RCON")

## Password for remote console. Empty disables RCON entirely.
##
## [b]Empty means disabled, not "no password".[/b] An RCON listener with no password
## is a remote shell, so there is no configuration that produces one.
@export var rcon_password: String = ""

## TCP port for RCON. 0 uses [member port] + 1.
@export var rcon_port: int = 0

## Read the server's own terminal and run what is typed into it.
##
## On, and harmless when there is nothing to read: [DotStdinConsole] checks
## [method OS.get_stdin_type] and reads only a terminal or a regular file, doing nothing
## for every unit file, every container started without `-i`, and every CI run. Turn it
## off for a server whose stdin carries something that is not commands.
@export var stdin_console_enabled: bool = true

## Read stdin even when it is a pipe (or a socket, or `/dev/null`).
## Off: the reader blocks in a read nothing can cancel, and a pipe whose writer never closes hangs the
## engine's exit. On for a supervisor that feeds commands down a pipe; see [member DotStdinConsole.read_pipes].
@export var stdin_console_pipes: bool = false

## Also serve RCON over WebSocket, for browser-based admin panels.
##
## Same authentication and rate limits; only the framing differs.
@export var rcon_websocket: bool = false

@export var rcon_websocket_port: int = 0

## Addresses allowed to use RCON. Empty allows any.
##
## Worth populating. It is the control that survives a leaked password.
@export var rcon_allowed_addresses: PackedStringArray = PackedStringArray()

## Failed RCON authentications before an address is locked out.
@export_range(1, 100, 1) var rcon_max_failures: int = 5

## Seconds an address is locked out for.
@export_range(10.0, 86400.0, 10.0) var rcon_lockout_sec: float = 600.0

@export_group("Query")

## Answer the dot query protocol.
##
## On by default, and safe on by default: every UDP query is answered with an
## address-bound challenge before any payload is built, so the listener cannot be
## used to attack somebody else, and it is rate limited per address on top of that.
## Read by dot-server-query's DQP listener, which is a separate addon; nothing
## here reads it.
##
## A server nobody can query is a server nobody can find.
@export var query_enabled: bool = true

## Interface the query listeners bind, when it is not [member bind_address].
##
## Empty — the default — means "the same interface the game does", which is right
## for every server that is reachable at its own address.
##
## It exists for the one that is not: a server behind a reverse proxy binds the
## game transport to loopback and lets nginx terminate TLS in front of it, and a
## reverse proxy can forward a WebSocket and [b]cannot forward UDP[/b]. Sharing
## one setting therefore made the query port unreachable from anywhere but the
## box itself — the server was listening, correctly, where nothing could ask it,
## and a tracker's silence is indistinguishable from a server that is down.
##
## Applies to the dot query socket, the query WebSocket and A2S. Deliberately
## NOT to RCON, which shares [member bind_address] and should never become
## easier to reach than the game it administers.
@export var query_bind_address: String = ""

## UDP port for queries. 0 uses [member a2s_port]'s effective value — which is
## [member port] — so both protocols share one socket and both answer where a
## tracker looks.
##
## They are told apart by their first four bytes. Set this only when a UDP game
## transport (ENet) already holds the game port.
@export var query_port: int = 0

## Also serve queries over WebSocket, as plain JSON.
##
## What an in-browser server browser needs: a web page cannot open a UDP socket,
## so it can never speak A2S, at any price. Off by default because it is a second
## listener, and a deployment with no web front end has no use for it.
@export var query_websocket: bool = false

## TCP port for the WebSocket query listener. 0 uses [member port] + 3.
@export var query_websocket_port: int = 0

## How much of the player list a query may see.
##
## [code]full[/code] adds userid, ping, bot and signon state to the name, score and
## duration A2S would give ([code]names[/code]). [code]count[/code] publishes the
## number but no list; [code]none[/code] refuses the section. Never includes an
## account uid at any setting — see dot-server-query.
@export_enum("full", "names", "count", "none")
var query_player_detail: String = "full"

## Publish server variables in the [code]rules[/code] section.
@export var query_rules: bool = true

## Extra cvars to publish beyond the notify/replicated ones.
##
## Protected and hidden cvars are refused here regardless — naming one does not
## make it publishable.
@export var query_extra_rules: PackedStringArray = PackedStringArray()

## Seconds a challenge cookie stays valid. The real window is up to twice this.
@export_range(5.0, 300.0, 5.0) var query_challenge_ttl_sec: float = 30.0

## Queries answered per address per second, sustained.
@export_range(0.1, 100.0, 0.1) var query_rate_per_second: float = 2.0

## Queries an address may burst before the sustained rate applies.
@export_range(1.0, 200.0, 1.0) var query_rate_burst: float = 10.0

## Seconds a snapshot is reused before it is rebuilt.
##
## The control that stops a query flood costing CPU: a thousand queries in a second
## cost one walk of the session table, not a thousand.
@export_range(0.0, 60.0, 0.1) var query_cache_sec: float = 1.0

## Most players listed in one response.
@export_range(1, 4096, 1) var query_max_players_listed: int = 128

## Shared secret for signing query responses. Empty disables signing.
##
## For a listing service that must know this server really said this, rather than
## somebody forging a busy server to climb a list.
@export var query_secret: String = ""

@export_group("A2S")

## Answer the A2S query protocol as well.
##
## Off by default. A2S is a compatibility shim for twenty years of trackers,
## chat bots and uptime monitors that speak nothing else — worth having when
## being listed matters, and a strictly worse protocol otherwise. See
## dot-server-query's A2S listener, which is a separate addon.
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

## Reload the admin file when it changes on disk.
##
## Lets an operator promote somebody without restarting. Cheap: a modification-time
## check on a timer.
@export var admins_auto_reload: bool = true

@export_group("Logging")

## The level below which nothing is emitted: trace, debug, info, warn, error, fatal, off.
##
## [code]info[/code] is the level a server is meant to run at — everything at or above it
## is something an admin would want kept. [code]debug[/code] answers "why did it do that"
## and is not a level to leave on: it is per-decision, and on a busy server it is the
## difference between a log somebody reads and a log somebody greps in despair.
@export var log_level: String = "info"

## Per-channel overrides, as [code]channel=level[/code].
##
## The reason a global level is rarely the right tool: turning on DEBUG to diagnose one
## download also turns on every physics and RPC trace, and the lines you wanted scroll
## past. [code]--sv-log-channel-levels cloud=debug[/code] turns up one subsystem.
@export var log_channel_levels: PackedStringArray = PackedStringArray()

## The lowest level mirrored into the engine's own warning and error output.
##
## [b]error, and lowering it has a cost worth knowing.[/b] The engine appends an
## [code]at:[/code] line and a full GDScript backtrace to every [method push_warning] and
## [method push_error] in a debug build, and nothing suppresses that per call. At
## [code]warn[/code] every recoverable, expected warning — an optional profile lookup that
## was refused, a vote that cannot open yet — costs eight lines of stderr and reads like a
## crash to whoever is scanning the log. The one-line [code]WRN[/code] already carries the
## same message.
@export var log_mirror_min_level: String = "error"

## Write the log to a file as well as to stdout.
##
## On. stdout is captured by whatever supervises the process and is gone when that
## rotates or restarts; the file is the copy an admin can still read on Tuesday. It costs
## nothing when nothing is wrong and it is the only artefact when something is.
@export var log_file_enabled: bool = true

## Directory for log files.
@export var log_directory: String = "user://logs"

## Base name. A timestamp and [code].log[/code] are appended, so a directory listing is
## in chronological order without any renaming.
@export var log_basename: String = "server"

## One JSON object per line instead of the human format.
##
## Off: the primary reader is a person over SSH. On for a box where something else tails
## the file.
@export var log_json: bool = false

## Rotate once a file passes this size. 0 disables size rotation.
@export var log_max_file_bytes: int = 16 * 1024 * 1024

## Log files to keep, oldest deleted first. 0 keeps everything.
##
## [b]Not zero.[/b] An unbounded log directory is the most common way a game server fills
## a disk, and a full disk stops the server rather than the logging.
@export var log_max_files: int = 10

@export_group("Moderation")

@export var bans_path: String = "user://cfg/bans.json"

## Audit log of every administrative action.
##
## Separate from the general log because it is the record a moderation dispute is
## resolved from, and it must not be rotated away with routine noise.
@export var audit_log_path: String = "user://logs/audit.jsonl"

## Announce administrative actions in chat.
##
## On by default: visible moderation is a deterrent, and players who see a cheater
## removed stop reporting them.
@export var announce_admin_actions: bool = true

## Most simultaneous connections allowed from one address. 0 removes the limit.
##
## Neither a ban nor the connect rate limiter covers this: connections that arrive
## slowly, from nobody banned, still let one machine hold every slot on a small server.
## See [DotAddressGuard], which also explains why the default is off — a household, a
## university and everybody behind CGNAT are each one address.
@export_range(0, 64, 1) var max_connections_per_ip: int = 0

## Addresses the per-address limit never applies to, on top of loopback.
##
## For a LAN party, an office, or a known NAT everybody plays from.
@export var connection_limit_exempt_addresses: PackedStringArray = PackedStringArray()

@export_group("Chat")

## Prefixes that turn a chat message into a command.
@export var chat_command_prefixes: PackedStringArray = PackedStringArray(["!", "/"])

## Whether a prefixed chat message reaches commands that have not said either way.
##
## [b]On.[/b] The console is the console: typing `/map surf_beginner` there needs no prefix
## and typing it in chat needs one, and past that the two are the same line running the
## same permission check. Off narrows chat to commands explicitly marked `with_chat()`,
## which is what this family did by default until it turned out to be a refusal aimed at
## operators rather than a boundary against anybody.
##
## The cvar is `sv_chat_commands`, so `server.cfg` and a running server can both change it.
@export var chat_commands_open: bool = true

## Chat messages allowed per player per minute.
@export_range(1, 240, 1) var chat_rate_per_minute: int = 20

## Longest chat message accepted, in characters.
@export_range(16, 2048, 16) var chat_max_length: int = 256

@export_group("Content")

## Manifest URL for the game clients should load on connect. Empty means none.
@export var content_manifest_url: String = ""

## Where a client should fetch this server's content from, best first.
##
## [b]Sent to every client at the handshake, because otherwise nobody knows.[/b] The
## server is told where its content lives and downloads maps from there; the client was
## left to guess, and the only guess a shipped build can make is "the origin the page
## came from" -- which is right for a self-hosted deployment and wrong for every one
## that puts content on a CDN. A map the server fetched, mounted and is running would
## then fail to download on the client with a 404 from a host that has nothing to do
## with it.
##
## A client tries its own configured bases first and these after, so a LAN mirror or a
## developer's local tree still wins. Nothing here is trusted: a manifest still has to
## carry a signature from a key the CLIENT already trusts, so the worst a hostile
## address can do is serve bytes that fail verification.
##
## The host sets this from the same setting it gives its own content client, so the two
## halves cannot disagree about where the content is.
@export var content_base_urls: PackedStringArray = PackedStringArray()

## Let clients fetch content over the game connection when they cannot reach the
## content host.
##
## Costs this server's bandwidth. See [DotCloudSourceNetchan].
@export var allow_netchan_content: bool = true

## Bytes per in-band content chunk.
@export_range(1024, 262144, 1024) var netchan_chunk_bytes: int = 65536

## In-band content chunks a client may request per second.
##
## The limit that stops an in-band download from starving gameplay traffic, and
## stops a client from using the content channel as a bandwidth amplifier.
##
## [b]Reserved.[/b] The server does not serve chunks yet — see "Things deliberately
## not here" in CLAUDE.md — so this and [member netchan_chunk_bytes] are sent to
## clients and enforced by nothing. Declared honestly rather than quietly ignored.
@export_range(1, 512, 1) var netchan_chunks_per_second: int = 32
