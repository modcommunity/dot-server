@tool
extends Node

## The signals, enums, settings and state of [DotServer], kept apart so each file stays readable.

const Cvars := preload("dot_server_cvars.gd")
const CHANNEL := "server"
const SERVICE := &"dot_server"

## Registry name of an optional external ban list — dot-moderation registers under it.
##
## Whatever is registered here answers
## [code]check_admission(uid: String, address: String) -> DotResult[/code]. Neither
## addon imports the other, exactly as [code]dot_mute_source[/code] joins dot-moderation
## to dot-voice.
const BAN_SOURCE := &"dot_ban_source"

## Reported in `status`, in query responses and in the backbone stats report.
##
## One constant rather than the three string literals it used to be, because a
## version that disagrees with itself across three listings is worse than no
## version at all.
const VERSION := "0.1.0"

## Multiplayer channel used for the join handshake and console traffic.
const CHANNEL_CONTROL := DotTransport.Channel.CONTROL

## Multiplayer channel for [DotNotice]s: reliable and ordered, like chat, and off the
## control channel so a HUD line never waits behind a content sync.
const CHANNEL_EVENT := DotTransport.Channel.EVENT

## Seconds between telling a peer why it is being disconnected and closing its socket. See
## [method _close_peer].
const CLOSE_GRACE_SEC := 0.25

enum State {
	IDLE,
	BOOTING,
	RUNNING,
	## No players connected; ticking at a reduced rate.
	HIBERNATING,
	SHUTTING_DOWN,
	STOPPED,
}

signal state_changed(state: State)

## The server went into hibernation ([param hibernating] true) or came out of it.
##
## [b]The hook a game's clocks follow.[/b] [signal state_changed] says the same thing among
## five other states, and every listener would have to remember which two transitions mean
## "the room emptied" and "somebody is back" — and that leaving HIBERNATING for
## SHUTTING_DOWN is neither. A map's time limit, a vote's clock and a round timer stop
## counting on [code]true[/code] and start again from their configured values on
## [code]false[/code], so the first player to arrive gets the whole map rather than
## whatever an empty room left of it. dot-vote's and dot-map's [code]follow_hibernation[/code]
## connect to this by name, which is why it carries a plain bool.
signal hibernation_changed(hibernating: bool)

## [code]sv_tickrate[/code] was set while the server is up. Nothing has changed yet: the
## rate is held until the game reaches a boundary and calls
## [method apply_pending_tickrate], or the next game change applies it.
signal tickrate_pending(rate: int)

## The rate the server ticks at changed, at a boundary. A game re-steps its simulation and
## tells its clients here; see [method apply_pending_tickrate].
signal tickrate_changed(rate: int)

## A client finished the whole join flow.
signal client_spawned(session: DotClientSession)

## A client left, for any reason. [param reason] is empty on a clean disconnect.
signal client_disconnected(session: DotClientSession, reason: String)

## A client's signon state advanced.
signal client_state_changed(session: DotClientSession)

## Emitted before the game changes, so subsystems can prepare.
signal game_changing(from_key: String, to_key: String)

## A [DotNotice] went out. [param recipients] is how many clients it was put on the wire
## for, which is 0 on a server with nobody playing — and a notice nobody received is still
## one the server meant, so a host that logs or mirrors them hears it either way.
signal notice_sent(notice: DotNotice, recipients: int)

@export_group("Configuration")

@export var config: DotServerConfig = null

## JSON config layered over [member config]'s defaults.
@export var config_file: String = "user://cfg/server.json"

## Boot automatically on [method Node._ready].
##
## Off when a host project wants to configure subsystems first and call
## [method boot] itself.
@export var auto_boot: bool = true

@export_group("Subsystems")

## Where to find or create the console.
##
## Every subsystem ref defaults to creating a child, so a bare [DotServer] works.
## Point one at an existing node to share it — a listen server hosting and playing
## in one process wants one console, not two.
@export var console_ref: DotNodeRef = null
@export var admin_ref: DotNodeRef = null
@export var bans_ref: DotNodeRef = null
@export var audit_ref: DotNodeRef = null
@export var chat_ref: DotNodeRef = null
@export var rcon_ref: DotNodeRef = null
@export var stdin_ref: DotNodeRef = null
@export var games_ref: DotNodeRef = null
@export var votes_ref: DotNodeRef = null

@export var events_ref: DotNodeRef = null
@export var modules_ref: DotNodeRef = null

## Where the log goes, over and above stdout.
##
## Resolve it to a [DotLogSink] for a rotating file, or to a **dot-log**
## [code]DotLogRouter[/code] for the whole sink layer — a file, a ring in memory the
## console can read back, syslog, a database table, a hosted collector. Either is
## recognised by duck typing; dot-server names neither, because only dot-core may be a
## hard dependency here.
##
## Leave it null and the server makes its own [DotLogSink] from
## [member DotServerConfig.log_file_enabled], so a server has a log file without anybody
## having configured one. That default exists because a dedicated server whose only record
## is stdout has no record at all the moment its supervisor rotates or restarts.
@export var log_sink_ref: DotNodeRef = null

## Where the log is going, if anywhere: a [DotLogSink], a dot-log router, or null.
var log_node: Node = null

## Whether [member log_node] is a router rather than a plain sink. Duck-typed.
var log_is_router: bool = false

var console: DotConsole = null
var admins: DotAdminManager = null
var bans: DotBanManager = null
var audit: DotAuditLog = null
var chat: DotChatManager = null
var rcon: DotRconServer = null
## The server's own terminal, when there is one to read.
var stdin_console: DotStdinConsole = null
var games: DotGameManager = null

## Most player rows one scoreboard carries. Bounds a payload sent twice a second.
const SCOREBOARD_MAX_ROWS := 256

## Seconds between scoreboards sent to a client holding its board open.
var scoreboard_interval_sec: float = 0.5

## `func(session: DotClientSession) -> Dictionary`: a game's own columns for one player
## (kills, team, points), merged into its row of [method scoreboard_snapshot].
var scoreboard_fields: Callable = Callable()

## `func() -> Dictionary`: anything else on the board — `"teams"`, a `"header"` of the
## round's state, `"rows"` for players that are not sessions. Added beside the core keys,
## never over them.
var scoreboard_extra: Callable = Callable()

## The addon versions this server runs, as a client can fetch them: one
## `{dir, repo, id, version}` per addon -- `dir` under `res://addons/`, `id` the content id
## its pack is published under. Empty says nothing, which is every server before this.
##
## [b]It rides the signon challenge[/b] because that is the first thing a client hears and
## the one message that arrives whatever else differs. A client whose build is older than
## this list can fetch the newer addons as packs and restart into them (dot-cloud's
## `DotCloudAddonSet`) instead of waiting for a new client build. The host fills it: only
## the host knows which repositories its addons came from.
var addon_set: Array = []

var _scoreboard_accum: float = 0.0
var votes: DotVoteManager = null
var events: DotEventBus = null
var modules: DotModuleHost = null
## The query responder, when dot-server-query is installed and plugged in.
##
## [b]Duck-typed, and that addon is named nowhere in dot-server.[/b] Answering a
## query is a whole protocol's worth of concern that most servers in this family
## never switch on, so it lives in its own repository — and a script mentioning a
## [code]class_name[/code] the project does not have fails to parse and takes
## every script referencing it down with it. Naming [code]DotQueryHost[/code] here
## would make an optional addon mandatory for anything that so much as boots a
## server.
##
## The hook is [method attach_query_host]. Everything below is filled in by the
## host once it has attached, and stays null when nothing does.
var query_host: Object = null

## The snapshot builder, set by the query host. See [method attach_query_host].
##
## Read by [method DotModule.add_query_provider] and by the builtin query
## commands, both of which check it for null first — which on a server with no
## query addon is always.
var query_source: Object = null

## The dot query protocol listener, set by the query host.
var query: Object = null

## The A2S listener, set by the query host.
var a2s: Object = null

var state: State = State.IDLE

## peer_id -> DotClientSession
var _sessions: Dictionary = {}

## userid -> peer_id, so `kickid` can find a session.
var _by_userid: Dictionary = {}

var _next_userid: int = 1
var _peer: MultiplayerPeer = null
var _transport: DotTransport = null
var _started_at: int = 0

## Cvars this node owns and reads on hot paths.
var _cv_hostname: DotConVar
var _cv_password: DotConVar
var _cv_allow_web: DotConVar
var _cv_allow_desktop: DotConVar
var _cv_allow_mobile: DotConVar
var _cv_single_seat: DotConVar
var _cv_maxplayers: DotConVar
var _cv_cheats: DotConVar
var _cv_tickrate: DotConVar
var _pending_tickrate: int = -1
var _cv_timeout: DotConVar
var _cv_background_grace: DotConVar

var _connect_limiter: DotRateLimiter = null
var _warned_about_ban_source: bool = false

## How many clients one address may hold at once. See [DotAddressGuard].
var address_guard: DotAddressGuard = null

var _sweep_accum: float = 0.0

## The server's frame time, smoothed, and how far frames stray from it, in milliseconds.
## Sent back on every heartbeat (see [method _on_heartbeat]) so a client's net_stat can
## tell "the network is slow" from "the server is": both feel like lag, and only one of
## them is the player's connection.
var _frame_ms: float = 0.0
var _frame_dev_ms: float = 0.0
