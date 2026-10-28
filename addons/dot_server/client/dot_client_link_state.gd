@tool
extends Node

## State, signals and phase helpers of [DotClientLink].

const CHANNEL := "client"
const Credentials := preload("dot_client_credentials.gd")
const SERVICE := &"dot_client_link"
const CHANNEL_CONTROL := DotTransport.Channel.CONTROL
const CHANNEL_EVENT := DotTransport.Channel.EVENT

## Mirrors the server's view of the join, for loading-screen text.
enum Phase {
	IDLE,
	CONNECTING,
	AUTHENTICATING,
	DOWNLOADING,
	LOADING,
	PLAYING,
	FAILED,
}

signal phase_changed(phase: Phase, text: String)

## Content download progress, 0..1.
signal download_progress(fraction: float, text: String)

## In the game.
signal spawned()

## The server closed the connection. [param reason] is what it said, when it said
## anything — which is why the server sends a reason before closing rather than just
## dropping the socket.
signal disconnected(reason: String)

signal chat_received(payload: Dictionary)

## The server put something on this player's HUD: a line, a countdown, a sound, or the end of one. See [DotNotice].
## The one message sent to the APPLICATION rather than the game on screen: a game's wire is replaced when the game changes,
## this is dot-server's, so something that outlives a game (a next-game vote, a restart warning) reaches a player as more than chat.
signal notice_received(notice: DotNotice)

## The browser tab was hidden or shown. Never fires off-web.
## Emitted from a JavaScript listener, not a frame, so a handler must be synchronous; see [member background_keepalive].
signal page_visibility_changed(visible: bool)

## Server details from the handshake challenge.
signal server_info(info: Dictionary)

## The roster, while this client holds its scoreboard open. See [method want_scoreboard] and
## [method DotServer.scoreboard_snapshot] for the shape.
signal scoreboard_received(snapshot: Dictionary)

## The server told this client which game to load.
## Fires on the first load and on every change ([code]SPAWNED -> DOWNLOADING[/code] is legal), so a host building its own scene hears each.
## Emitted before [signal spawned], so a listener can decide what to build and build it in one pass.
signal game_changed(game_id: String, content_id: String, display_name: String)

## A replicated cvar's value arrived or changed (FLAG_REPLICATED cvars, see [member replicated_cvars]).
## Fires once per name whose value is new, not per message. Duck-typed followers
## (dot-combat's [code]DotCombatManager.follow_cvars[/code]) connect here by name.
signal replicated_cvar_changed(cvar_name: String, value: String)

@export_group("Identity")

## Name to request. Honoured for guests; an authenticated account uses its own.
@export var player_name: String = "Player"

## Where to find a [code]DotAuthClient[/code], when dot-auth is installed.
## Resolved through [DotRegistry], so this addon has no dependency on dot-auth.
@export var auth_service: StringName = &"dot_auth_client"

## Where to find a [code]DotCloudClient[/code], when dot-cloud is installed.
@export var cloud_service: StringName = &"dot_cloud_client"

@export_group("Transport")

## Transport for connecting. When set, it is the only one tried. When unset (the
## usual case) the link chooses: see [member transport_preference].
@export var transport: DotTransport = null

## [code]auto[/code]: native tries ENet over UDP for [member udp_connect_timeout_sec], then WebSocket (browsers always WebSocket).
## [code]udp[/code]: ENet only. [code]ws[/code]: WebSocket only.
@export_enum("auto", "udp", "ws") var transport_preference: String = "auto"

## Where ENet is, as host:port. Empty: derived from a plain host:port connect address (dual-stack servers share the number).
## A ws:// or wss:// address names a proxy, so nothing is derived from it; only an explicit value
## (the server's advertised [code]enet_port[/code]) makes the link try UDP.
@export var udp_address: String = ""

## How long the UDP attempt gets before WebSocket is tried. Short on purpose: it
## is the wait a player behind a UDP-blocking firewall pays on every join.
@export_range(0.5, 15.0, 0.5) var udp_connect_timeout_sec: float = 2.5

## The longest a native WebSocket join waits on [code]wss://[/code] before plain [code]ws://[/code] at a public bare host:port (see [method _tls_first]).
## A plain server pays it in full: its listener does not answer a TLS ClientHello and waits for an HTTP header.
## 2.5 s covers TCP connect, TLS 1.3 handshake and upgrade at ~300 ms RTT, twice.
@export_range(0.5, 15.0, 0.5) var tls_connect_timeout_sec: float = 2.5

## "enet" or "websocket": what the current (or last) connection uses.
var transport_used: String = ""
## True while an attempt that has a fallback is running (UDP before WebSocket, TLS before
## plain): its failure is quiet, because the join has not failed yet.
var _trying_first: bool = false
## The address of the join in progress, for the secure rejoin.
var _last_address: String = ""
## Set while rejoining over WebSocket because the server asked for a secret.
var _secure_rejoin: bool = false

@export_group("Behaviour")

## Where the game scene is added. Defaults to a child of this node.
@export var game_root_ref: DotNodeRef = null

## Seconds between heartbeats, which also measure ping.
@export_range(0.5, 30.0, 0.5) var heartbeat_interval_sec: float = 2.0

## Seconds to wait for the server's challenge before deciding it is never coming.
## A challenge that never arrives is the half of an RPC mismatch [DotSignon] cannot report, and the server's "Timed out while authenticating" blames the network;
## shorter than `sv_auth_timeout` so the end that can name the likely cause answers.
@export_range(2.0, 120.0, 1.0) var signon_timeout_sec: float = 15.0

## Tell the server before this client's browser tab goes silent, and ask it to wait.
## A hidden tab stops requestAnimationFrame, hence _process, timers and the poll: no heartbeat, and `sv_timeout` drops the player about a minute in.
## The client announces the switch while the page is live and its return; the server holds the slot up to `sv_background_grace`. A request, not a guarantee; no effect off-web.
@export var background_keepalive: bool = true

## Seconds to ask for. 0 asks for whatever the server allows.
## Set below the server's ceiling: a hidden tab keeps receiving, and those bytes queue for the burst on return.
@export_range(0.0, 1800.0, 15.0) var background_grace_sec: float = 0.0

var phase: Phase = Phase.IDLE

## The server's signon revision, from the handshake. Empty for a server too old to
## send one, which is not an error -- see [DotSignon].
var server_signon: String = ""

## Set from the handshake, so a client knows which server it is talking to.
var server_id: String = ""
var server_hostname: String = ""

## The backbone target an INTROSPECT server says a join token must name
## (`server:<id>`), from the handshake. Empty for a server that does not say.
var server_join_audience: String = ""
var _ticket_nonce := ""

## The addon versions the server runs, from the handshake: `{dir, repo, id, version}` per addon (see [member DotServer.addon_set]). Empty if none sent.
## Read before the join completes, so a shell can fetch newer addons and restart into them.
var server_addons: Array = []

## The game the server is currently running, as [DotGameManager.load_info] reported it. Empty before the first load.
## A game shipped inside a client's build names no scene ([method _resolve_scene] refuses absolute paths outside the mount),
## so the id is the only thing telling a multi-game client which built-in game to show.
var server_game_id: String = ""
var server_game_name: String = ""

## What the current game is made of, as opposed to what this server calls it.
## Key a table of built-in clients on this, not [member server_game_id]: the id is the operator's (a directory name they chose), so renaming it would orphan the client's scene.
## Defaults to the game id when a game sets none.
var server_content_id: String = ""

## The extra packs (`content_extra`, `<id>@<version>` keys) the server last told this client to fetch.
## What the client was ASKED for: a mount is process-wide, so "is it mounted" cannot say which side wanted it in a process holding a server too. Server-only packs never appear.
var content_extra: PackedStringArray = PackedStringArray()

var last_error: DotError = null

## The last [DotNotice] the server sent, for [method describe] and for a HUD built after
## it arrived. Null until one has.
var last_notice: DotNotice = null

## The server's replicated cvars, name -> value as a string, as last told. Empty against a
## server older than the [constant DotEnvelope.CVARS] kind: a reader keeps its own default.
var replicated_cvars: Dictionary = {}

## Most replicated cvars a server may name, and the longest name and value kept. Bounds a
## table somebody else sent.
const MAX_REPLICATED_CVARS := 512
const MAX_CVAR_NAME_BYTES := 64
const MAX_CVAR_VALUE_BYTES := 1024

var _game_root: Node = null
var _scene_instance: Node = null
## Bumped by every new load, disconnect and exit from the tree. [method _on_load_game] awaits,
## and whatever it was doing when the world changed under it must not add a scene or say
## LOADED. Compare after every await.
var _load_gen: int = 0

## How long the last game's nodes under this link outlive it. See [method _free_game_children].
const RETIRED_SECONDS := 10.0
var _heartbeat: Timer = null

## Started when the transport connects, stopped by the server's challenge. See
## [member signon_timeout_sec].
var _signon_watchdog: Timer = null
var _ping_sent_ms: int = 0
var _ping_ms: int = -1
var _password: String = ""
var _connected: bool = false

## Name the visibility listener is rooted under, unique per link.
var _visibility_key: String = ""

## The cloud progress subscription, kept so it is only ever made once.
var _progress_handler: Callable = Callable()

var _creds := Credentials.new(self)

## The kinds this client knows, and what the server it is talking to knows. See
## [DotEnvelope]. A kind this client does not handle is dropped with a DEBUG line; one the
## server does not know is not sent to it.
var envelope: DotEnvelope = _make_envelope()


## Heartbeats sent quickly as a join completes. See [method _enter_playing].
const EARLY_HEARTBEATS := 4


const EARLY_HEARTBEAT_SEC := 0.25


var _early_heartbeats := 0


## The last roster the server sent. Empty until a board has been held open.
var scoreboard: Dictionary = {}


## Whether this client's board is held open, as [method want_scoreboard] last said.
var _scoreboard_held: bool = false


## The client's chat node. It declares no RPCs any more -- chat is two kinds on the
## envelope -- and is kept because games reach chat through it by name.
var _chat: DotClientChat = null


## Built by [DotClientLink], which owns the handlers.
func _make_envelope() -> DotEnvelope:
	return DotEnvelope.new()


## Sends a kind to the server; implemented by [DotClientLink], which declares the RPCs it rides on.
func send_kind(
	_kind: StringName,
	_payload: Dictionary = {},
	_lane: DotEnvelope.Lane = DotEnvelope.Lane.CONTROL
) -> bool:
	return false


func _set_phase(new_phase: Phase, text: String) -> void:
	if phase == new_phase:
		return
	phase = new_phase
	phase_changed.emit(new_phase, text)


func _fail(error: DotError) -> DotResult:
	last_error = error
	_set_phase(Phase.FAILED, error.message)
	DotLog.error(
		CHANNEL, error.message, {"code": error.code, "detail": error.detail}
	)
	return DotResult.failure(error)


func is_connected_to_server() -> bool:
	return _connected


func is_playing() -> bool:
	return phase == Phase.PLAYING


static func phase_name(p: Phase) -> String:
	return Phase.keys()[p]


func describe() -> Dictionary:
	return {
		"phase": phase_name(phase),
		"connected": _connected,
		"server": server_hostname,
		"server_id": server_id,
		"ping": _ping_ms,
		"last_notice": last_notice.describe() if last_notice != null else {},
		"replicated_cvars": replicated_cvars.size(),
	}
