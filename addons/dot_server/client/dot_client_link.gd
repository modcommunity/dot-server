@tool
class_name DotClientLink
extends Node

## The client's half of the connection to a [DotServer].
##
## Mirrors the server's handshake RPCs, drives content sync through dot-cloud, loads
## the game scene the server names, and exposes chat. A game's own replication sits
## on top of this; the link handles getting the player from "typed an address" to
## "in the world".
##
## [b]Six RPCs, the same six as [DotServer], and they do not change.[/b] Everything the
## two ends say is a named kind inside them -- see [DotEnvelope] for why, and
## [member envelope] for how a game or an addon adds one without breaking every client
## already shipped.
##
## [codeblock]
## var link := DotClientLink.new()
## add_child(link)
##
## link.phase_changed.connect(func(_p, text): status.text = text)
## link.spawned.connect(func(): ui.show_game())
##
## var res := await link.connect_to_server("wss://play.example.com/game")
## [/codeblock]

const CHANNEL := "client"
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

## The server put something on this player's HUD: a line, a countdown, a sound, or the
## end of one of those. See [DotNotice] for what each field means to a client.
##
## [b]The one message the server sends to the APPLICATION rather than to the game on
## screen.[/b] A game's own wire is the game's and is replaced when the game changes; this
## is dot-server's, and is how something that outlives a game — a vote for the next one, a
## restart warning — reaches a player as anything but chat.
signal notice_received(notice: DotNotice)

## The browser tab was hidden or shown. Never fires off-web.
##
## Emitted from a JavaScript listener rather than from a frame, so a handler must be
## synchronous — see [member background_keepalive] for why there is no next frame to
## [code]await[/code] on the way out.
signal page_visibility_changed(visible: bool)

## Server details from the handshake challenge.
signal server_info(info: Dictionary)

## The server told this client which game to load.
##
## Fires on the first load and on every change afterwards — [code]SPAWNED ->
## DOWNLOADING[/code] is a legal transition and it is what changing the game *is*. A host
## that builds its own scene for a game shipped inside its build has to hear about the
## second one as well as the first, and until this existed there was nothing to hear: the
## payload carried the game's id all along and the link discarded it.
##
## Emitted before [signal spawned], so a listener can decide what to build and then build
## it in one pass rather than reacting to two signals in an order it has to know.
signal game_changed(game_id: String, content_id: String, display_name: String)

@export_group("Identity")

## Name to request. Honoured for guests; an authenticated account uses its own.
@export var player_name: String = "Player"

## Where to find a [code]DotAuthClient[/code], when dot-auth is installed.
##
## Resolved through [DotRegistry] rather than a hard reference, so this addon has no
## dependency on dot-auth.
@export var auth_service: StringName = &"dot_auth_client"

## Where to find a [code]DotCloudClient[/code], when dot-cloud is installed.
@export var cloud_service: StringName = &"dot_cloud_client"

@export_group("Transport")

## Transport used to connect. Should match the server's.
@export var transport: DotTransport = null

@export_group("Behaviour")

## Where the game scene is added. Defaults to a child of this node.
@export var game_root_ref: DotNodeRef = null

## Seconds between heartbeats, which also measure ping.
@export_range(0.5, 30.0, 0.5) var heartbeat_interval_sec: float = 2.0

## Seconds to wait for the server's challenge before deciding it is never coming.
##
## [b]A client that is never challenged is the OTHER half of an RPC mismatch, and it is
## the half no message can reach.[/b] [DotSignon] rides on the challenge and catches a
## server whose revision differs -- but a break severe enough that the challenge itself
## does not arrive leaves this end with a connected socket and silence, until the server
## times the session out and closes it with "Timed out while authenticating". That
## sentence blames the player's network for a build mismatch.
##
## Shorter than the server's `sv_auth_timeout` on purpose, so the answer comes from the
## end that can name the likely cause rather than from the end that cannot.
@export_range(2.0, 120.0, 1.0) var signon_timeout_sec: float = 15.0

## Tell the server before this client's browser tab goes silent, and ask it to wait.
##
## [b]A browser stops the Godot main loop for a hidden tab.[/b] It stops calling
## [code]requestAnimationFrame[/code] altogether, which stops [code]_process[/code],
## every [Timer] and the multiplayer poll together — so no heartbeat is sent, nothing
## is read, and the socket sits open and idle. To the server that is indistinguishable
## from a machine that died, and [code]sv_timeout[/code] drops the player about a
## minute into a tab switch.
##
## With this on, the client announces the switch on the way out, while the page is
## still live, and announces its return. The server holds the slot for up to
## [code]sv_background_grace[/code].
##
## [b]It is a request, not a guarantee.[/b] The server clamps what it grants and may
## grant nothing; the announcement can also be lost, in which case the ordinary
## timeout applies and the behaviour is what it was before this existed.
##
## No effect off-web, where a window that is not on screen still runs its frames.
@export var background_keepalive: bool = true

## Seconds to ask for. 0 asks for whatever the server allows.
##
## Worth setting below the server's ceiling rather than above it: while the tab is
## hidden the server goes on sending to a client that is not reading, and those bytes
## queue up for the burst that arrives when the player comes back.
@export_range(0.0, 1800.0, 15.0) var background_grace_sec: float = 0.0

var phase: Phase = Phase.IDLE

## The server's signon revision, from the handshake. Empty for a server too old to
## send one, which is not an error -- see [DotSignon].
var server_signon: String = ""

## Set from the handshake, so a client knows which server it is talking to.
var server_id: String = ""
var server_hostname: String = ""

## The game the server is currently running, as [DotGameManager.load_info] reported it.
##
## Empty before the first load. [b]A game that ships inside a client's own build names no
## scene[/b] — [method DotGameDescriptor.client_scene_or_scene] returns the empty string,
## because [method _resolve_scene] refuses every absolute path outside dot-cloud's mount —
## so the id is the only thing telling that client which of its built-in games it is
## supposed to be showing. Without it a multi-game client can only guess, and the guess is
## wrong the moment an operator changes the game.
var server_game_id: String = ""
var server_game_name: String = ""

## What the current game is made of, as opposed to what this server calls it.
##
## [b]This is the one to key a table of built-in clients on, not [member server_game_id].[/b]
## The game id is the operator's: it is what they type at the console and, on a server that
## scans a directory for its games, it is a directory name they chose. Two servers running
## the same game can call it different things, and one operator renaming a directory would
## leave every client unable to find a scene for a game it has.
##
## Defaults to the game id when a game does not set one, so a server that has never heard
## of this distinction behaves exactly as it did.
var server_content_id: String = ""

var last_error: DotError = null

## The last [DotNotice] the server sent, for [method describe] and for a HUD built after
## it arrived. Null until one has.
var last_notice: DotNotice = null

var _game_root: Node = null
var _scene_instance: Node = null
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

## The kinds this client knows, and what the server it is talking to knows. See
## [DotEnvelope]. A kind this client does not handle is dropped with a DEBUG line; one the
## server does not know is not sent to it.
var envelope: DotEnvelope = _make_envelope()


func _ready() -> void:
	_ensure_chat()

	if Engine.is_editor_hint():
		return

	DotRegistry.register(SERVICE, self)

	if game_root_ref == null:
		game_root_ref = DotNodeRef.of_created(&"GameRoot", Node)
	_game_root = game_root_ref.resolve_or_null(self, CHANNEL)

	_heartbeat = Timer.new()
	_heartbeat.wait_time = heartbeat_interval_sec
	_heartbeat.timeout.connect(_send_heartbeat)
	add_child(_heartbeat)

	_signon_watchdog = Timer.new()
	_signon_watchdog.one_shot = true
	_signon_watchdog.timeout.connect(_on_signon_timeout)
	add_child(_signon_watchdog)

	_watch_page_visibility()


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)

	if _visibility_key != "":
		DotWeb.unwatch_visibility(_visibility_key)
		_visibility_key = ""


# --- Connecting ------------------------------------------------------------

## Connects to a server and runs the whole join flow.
##
## Returns when the client is playing, or with a failure describing which stage
## went wrong.
func connect_to_server(address: String, password: String = "") -> DotResult:
	if _connected:
		disconnect_from_server()

	_password = password
	_set_phase(Phase.CONNECTING, "Connecting…")

	if transport == null:
		var auto := DotTransportAuto.new()
		# A client must speak whatever the server listens on; WebSocket is the
		# only choice that works from a browser and also works natively.
		auto.require_web_clients = true
		transport = auto

	var created := transport.create_client(address)
	if not created.ok:
		return _fail(created.error)

	multiplayer.multiplayer_peer = created.value

	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)

	DotLog.info(CHANNEL, "connecting", {"address": address})

	# The transport reports success or failure through signals rather than a return
	# value, so the connect is awaited with a timeout rather than checked.
	var deadline := Time.get_ticks_msec() + int(
		transport.connect_timeout_sec * 1000.0
	)

	while Time.get_ticks_msec() < deadline:
		if _connected:
			return DotResult.success(true)
		if phase == Phase.FAILED:
			return DotResult.failure(
				last_error if last_error != null
				else DotError.make(DotError.CODE_NETWORK, "Could not connect.")
			)
		await get_tree().process_frame

	multiplayer.multiplayer_peer = null
	return _fail(DotError.make(
		DotError.CODE_TIMEOUT,
		"The server did not respond.",
		address
	))


func disconnect_from_server(reason: String = "") -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

	_connected = false
	_heartbeat.stop()

	if _signon_watchdog != null:
		_signon_watchdog.stop()
	_unload_scene()

	# [b]A failure survives the disconnect that reports it.[/b] Every legible refusal in
	# this class is `_fail(...)` followed by a disconnect -- a signon revision that
	# cannot match, a server that never challenged us -- and an unconditional IDLE here
	# wiped the FAILED phase a frame after setting it. `last_error` stayed, so anything
	# reading the error still worked and anything watching the PHASE showed the player a
	# blank idle screen for a join that was refused with a reason. Found by a suite that
	# asserted the phase rather than the error.
	#
	# A later `connect_to_server` sets CONNECTING before anything reads this, so a
	# lingering FAILED cannot be mistaken for the state of a new attempt.
	if phase != Phase.FAILED:
		_set_phase(Phase.IDLE, "")

	if reason != "":
		disconnected.emit(reason)


func _on_connected() -> void:
	_connected = true
	_set_phase(Phase.AUTHENTICATING, "Signing in…")
	DotLog.info(CHANNEL, "transport connected")

	# The socket is open, so every remaining failure is a protocol failure. Nothing else
	# in this client is watching for one.
	if _signon_watchdog != null:
		_signon_watchdog.start(signon_timeout_sec)


func _on_connection_failed() -> void:
	_fail(DotError.make(
		DotError.CODE_NETWORK,
		"Could not reach the server.",
		"the address may be wrong, or the server may be using a different transport"
	))


## The server accepted a socket and then never said anything.
##
## [b]There is exactly one common cause and it is worth naming even when it is a
## guess.[/b] A server that is listening, accepting and silent has almost always been
## built against a different version of this addon: Godot compares the `@rpc` method
## sets, refuses to confirm the path, and the challenge never leaves the server -- and
## because that refusal is printed by the engine on whichever end noticed, and says
## nothing about versions, nobody reads it as one. The alternative causes -- a server
## wedged mid-boot, a proxy that completed a handshake it is not forwarding -- leave the
## same silence, so this says "probably" rather than "is".
##
## The message names the fix a player can act on. The detail names the one an operator
## can.
func _on_signon_timeout() -> void:
	if phase != Phase.AUTHENTICATING:
		return

	DotLog.error(CHANNEL, "the server never sent a challenge", {
		"host": server_hostname,
		"seconds": signon_timeout_sec,
		"client_signon": DotSignon.revision([DotClientLink]),
	})

	var err := DotError.make(
		DotError.CODE_TIMEOUT,
		"This server accepted the connection and then said nothing.",
		"it is probably built against a different version of the game -- this client's "
		+ "signon revision is %s; try an older build, or ask the operator which one "
		% DotSignon.revision([DotClientLink])
		+ "this server was built with"
	)

	_fail(err)
	disconnect_from_server(err.message)


## The transport reported that the connection is gone.
##
## [b]Shares the teardown with [method disconnect_from_server] rather than repeating it.[/b]
## The two ways a connection ends have to leave the same state behind and they did not:
## this one left the closed peer assigned, so `multiplayer.has_multiplayer_peer()` stayed
## true and everything downstream went on believing it was on a network. Clearing it from
## inside the poll that reported the drop is supported -- [MultiplayerAPI] re-checks the
## peer after polling for exactly this case.
func _on_server_disconnected() -> void:
	DotLog.info(CHANNEL, "server closed the connection")
	# No reason, so it does not emit; this function owns the reason it reports.
	disconnect_from_server()
	disconnected.emit("Connection to the server was lost.")


# --- The envelope ---------------------------------------------------------

func _make_envelope() -> DotEnvelope:
	var env := DotEnvelope.new()
	env.register_core()
	env.handle(DotEnvelope.CHALLENGE, _on_challenge)
	env.handle(DotEnvelope.CONTENT_SYNC, _on_content_sync)
	env.handle(DotEnvelope.LOAD_GAME, _on_load_game)
	env.handle(DotEnvelope.HEARTBEAT_ACK, _on_heartbeat_ack)
	env.handle(DotEnvelope.NOTICE, _on_notice)
	env.handle(DotEnvelope.DISCONNECT, _on_disconnect_notice)
	env.handle(DotEnvelope.CHAT_LINE, _on_chat_line)
	return env


## Sends a kind to the server. False when it was not sent: not connected, or a server
## that does not know the kind -- which is what an older server looks like, and is not an
## error. See [DotEnvelope].
func send_kind(
	kind: StringName,
	payload: Dictionary = {},
	lane: DotEnvelope.Lane = DotEnvelope.Lane.CONTROL
) -> bool:
	if multiplayer == null or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	if not envelope.should_send(1, kind):
		return false

	match lane:
		DotEnvelope.Lane.UNRELIABLE:
			_dot_up_unreliable.rpc_id(1, String(kind), payload)
		DotEnvelope.Lane.EVENT:
			_dot_up_event.rpc_id(1, String(kind), payload)
		_:
			_dot_up.rpc_id(1, String(kind), payload)
	return true


## The same six as [DotServer]'s, by name -- the names are the checksum. See the note
## there before adding one: the answer is a kind, never a seventh method.
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _dot_down(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(1, kind, payload)


@rpc("authority", "unreliable", "call_remote", CHANNEL_CONTROL)
func _dot_down_unreliable(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(1, kind, payload)


@rpc("authority", "reliable", "call_remote", CHANNEL_EVENT)
func _dot_down_event(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(1, kind, payload)


@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func _dot_up(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("any_peer", "unreliable", "call_remote", CHANNEL_CONTROL)
func _dot_up_unreliable(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("any_peer", "reliable", "call_remote", CHANNEL_EVENT)
func _dot_up_event(_kind: Variant, _payload: Variant) -> void:
	pass


# --- Handshake -------------------------------------------------------------

## The server asking us to identify ourselves.
func _on_challenge(_peer_id: int, challenge: Dictionary) -> void:
	server_hostname = str(challenge.get("hostname", ""))
	server_id = str(challenge.get("server_id", ""))

	# [b]Before anything else, because everything else is about to stop working
	# quietly.[/b] If this server declares a different set of `@rpc` methods than this
	# build does, Godot has already refused to confirm the path cache -- this very call
	# got through only because a first call goes out by full path -- and every message
	# after it goes nowhere. What the player would otherwise see is a spinner, then
	# "Timed out", for a reason no one could guess from either end.
	#
	# An older server sends no revision and is not refused: see [method
	# DotSignon.compatible].
	var ours := DotSignon.revision([DotClientLink])
	var theirs := str(challenge.get("signon", ""))

	# [b]Kept BEFORE the refusal, not after it.[/b] It was assigned past the early
	# return, so the one case anything downstream needs it for -- a shell telling the
	# page which build the server wants -- was the one case it was empty. The value is
	# the server's claim about itself either way; refusing to talk to that server does
	# not make the claim less true.
	server_signon = theirs

	if not DotSignon.compatible(ours, theirs):
		var mismatch := DotSignon.explain(ours, theirs)
		DotLog.error(CHANNEL, "signon revision mismatch", {
			"server": theirs, "client": ours, "host": server_hostname
		})
		_fail(mismatch)
		disconnect_from_server(mismatch.message)
		return

	# The one change the envelope's names cannot express: a kind that kept its name and
	# changed its meaning. See [constant DotSignon.PROTOCOL].
	var protocol := int(DotEnvelope.number(challenge, "protocol", DotSignon.PROTOCOL))
	if protocol != DotSignon.PROTOCOL:
		var differs := DotSignon.explain_protocol(DotSignon.PROTOCOL, protocol)
		DotLog.error(CHANNEL, "signon protocol mismatch", {
			"server": protocol, "client": DotSignon.PROTOCOL, "host": server_hostname
		})
		_fail(differs)
		disconnect_from_server(differs.message)
		return

	# What the server knows, so nothing it has never heard of is sent to it. Not a
	# refusal from here: the SERVER compares both adverts when the credentials arrive and
	# refuses a pair that cannot play, in words, and in the log an operator reads. A
	# client that refused on its own would leave the server with nothing but a socket
	# that closed.
	var adopted := envelope.adopt(1, challenge.get("kinds"), false)
	if not adopted.ok:
		DotLog.debug(CHANNEL, "the server's kinds do not cover this client's", {
			"why": adopted.error.message, "detail": adopted.error.detail,
		})

	# Challenged, so the connection is a conversation rather than a socket. Whatever
	# fails after this has a stage of its own to be reported against.
	if _signon_watchdog != null:
		_signon_watchdog.stop()

	server_info.emit(challenge)

	DotLog.info(
		CHANNEL,
		"server challenge",
		{
			"hostname": server_hostname,
			"auth": str(challenge.get("auth", "none")),
			"password": bool(challenge.get("needs_password", false)),
		}
	)

	var payload := {
		"name": player_name,
		# Stable per install, so a guest can be muted or kicked for a session
		# without anything that survives a reinstall.
		"device_id": _device_id(),
		# What this client can say and hear. The server decides from it whether the two
		# can play; see [DotEnvelope].
		"kinds": envelope.advert(),
	}

	if bool(challenge.get("needs_password", false)):
		payload["password"] = _password

	var strategy := str(challenge.get("auth", "none")).to_lower()
	await _attach_credential(payload, strategy)

	send_kind(DotEnvelope.CREDENTIALS, payload)


## Adds whatever credential the server's strategy asks for.
##
## Deliberately sends only what was asked. A client that volunteers its access token
## to a server requesting a ticket would defeat the point of tickets — see
## dot-auth's CLAUDE.md.
func _attach_credential(payload: Dictionary, strategy: String) -> void:
	var auth := DotRegistry.get_service(auth_service)

	if auth == null:
		if strategy != "none" and strategy != "anonymous":
			DotLog.warn(
				CHANNEL,
				"this server wants authentication but dot-auth is not installed",
				{"strategy": strategy}
			)
		return

	match strategy:
		"ticket":
			if server_id == "":
				DotLog.warn(
					CHANNEL,
					"the server asked for a ticket but named no server_id"
				)
				return

			if not auth.has_method("request_ticket"):
				return

			# The issuer URL is a client-side setting: it is the publisher's
			# service, not the game server's, so the game server must not be able
			# to name it.
			var issuer := _issuer_url()
			if issuer == "":
				DotLog.warn(
					CHANNEL,
					"no ticket issuer is configured; cannot authenticate"
				)
				return

			var ticket: Variant = await auth.call(
				"request_ticket", issuer, server_id
			)
			if ticket is DotResult and (ticket as DotResult).ok:
				payload["ticket"] = str((ticket as DotResult).value)

		"introspect":
			if not auth.has_method("valid_access_token"):
				return
			var token: Variant = await auth.call("valid_access_token")
			if token is DotResult and (token as DotResult).ok:
				payload["access_token"] = str((token as DotResult).value)

		"local":
			# Username and password for a LOCAL-strategy server come from a UI this
			# node does not own; a game sets them before connecting.
			pass


func _issuer_url() -> String:
	var auth := DotRegistry.get_service(auth_service)
	if auth == null:
		return ""
	var config: Variant = auth.get("config")
	if config == null:
		return ""
	var url: Variant = config.get("ticket_issuer_url")
	return str(url) if url != null else ""


static func _device_id() -> String:
	# Asked of DotPlatform rather than of the OS. `OS.get_unique_id()` does not fail
	# quietly on web and iOS -- it pushes an engine error and THEN returns "" -- so the
	# emptiness check below, which is correct, still printed a red line on the page of
	# every browser client before taking the branch it was written for.
	var unique := DotPlatform.unique_id()
	if unique != "":
		return unique
	# Web and some sandboxes have no unique id. A stored random value is stable
	# enough for the session-scoped uses this has.
	var path := "user://dot_device_id"
	if FileAccess.file_exists(path):
		var read := DotPaths.read_text(path)
		if read.ok and str(read.value) != "":
			return str(read.value)
	var generated := DotHash.random_hex(16)
	DotPaths.write_text(path, generated)
	return generated


# --- Content ---------------------------------------------------------------

## The server telling us to fetch content before we can play.
func _on_content_sync(_peer_id: int, info: Dictionary) -> void:
	var manifest_url := str(info.get("manifest_url", ""))
	var content_key := str(info.get("content_key", ""))

	_set_phase(Phase.DOWNLOADING, "Downloading game content…")

	var cloud := DotRegistry.get_service(cloud_service)

	if cloud == null:
		# Without dot-cloud there is no way to fetch content, and pretending to be
		# ready would put the player in a world made of missing assets.
		DotLog.error(
			CHANNEL,
			"this server requires downloadable content but dot-cloud is not installed"
		)
		_fail(DotError.make(
			DotError.CODE_UNSUPPORTED,
			"This server needs downloadable content, which this build cannot fetch."
		))
		return

	# [b]Connected once, and the Callable is kept.[/b] A fresh lambda is a fresh
	# [Callable] every time this runs, and `is_connected` compares Callables — so the
	# guard never matched its own handler and every game change added another
	# subscriber. After ten changes a client sent the server ten progress RPCs per
	# tick, all with the same number, and nothing anywhere reported an error. This is
	# the path a game change takes, so it grows for exactly the deployment the whole
	# addon exists for.
	if cloud.has_signal("progress_changed"):
		if _progress_handler.is_null():
			_progress_handler = _on_cloud_progress
		if not cloud.is_connected("progress_changed", _progress_handler):
			cloud.connect("progress_changed", _progress_handler)

	_adopt_content_bases(cloud, info.get("content_base_urls", []))

	DotLog.info(
		CHANNEL, "syncing content", {"content": content_key, "url": manifest_url}
	)

	var groups := PackedStringArray()
	for group in info.get("content_groups", []):
		groups.append(str(group))

	# [b]By id and version, with the server's URL as an override rather than as the
	# instruction.[/b] `acquire` mounts whatever is at an address; `ensure` is told what
	# the content is supposed to BE, so a manifest that answers to a different id or
	# version is refused instead of mounted. The server is the party naming the address
	# here, so that check is not a formality: without it a server could point a client at
	# any published pack and have it mount under the key the client was told to expect,
	# and every path the client then resolved would be somebody else's file.
	#
	# It is also what lets a server run a delivered game without writing an address into
	# its descriptor at all: the client has `content_base_urls` from the payload above.
	var parts := content_key.split("@", true, 1)
	var want_id := parts[0] if parts.size() > 0 else ""
	var want_version := parts[1] if parts.size() > 1 else ""

	if want_id == "":
		# No key to check against, so there is nothing to resolve by either. A server
		# that sent a URL and no content key is old or broken; mounting blind is how the
		# confusion above happens, so this refuses rather than falling back.
		_fail(DotError.make(
			DotError.CODE_INVALID,
			"This server asked for content without saying what it is."
		))
		return

	var res: Variant = await cloud.call(
		"ensure", want_id, want_version, groups, manifest_url
	)

	if not (res is DotResult) or not (res as DotResult).ok:
		var err := (res as DotResult).error if res is DotResult else DotError.make(
			DotError.CODE_INTERNAL, "Content download failed."
		)
		_fail(err)
		return

	send_kind(DotEnvelope.CONTENT_READY, {"content_key": content_key})


## Adds the server's content addresses to the ones this client already had.
##
## [b]A client cannot know where a server keeps its maps, and it was left guessing.[/b]
## The server is configured with the address and fetches from it; the client had only
## whatever its own build was compiled with -- for a browser build, the page's own
## origin -- so a deployment serving content from a CDN worked on the server and failed
## on every client, with a 404 from a host that has nothing to do with the content.
##
## ADDED, never substituted, and added AFTER: a client that was given its own base
## meant it, and a LAN mirror or a developer's local tree should still win a race
## against the public one. This is a fallback that is always correct, not an override.
##
## [b]Nothing about this trusts the server.[/b] An address is only ever somewhere to
## ask; the manifest that comes back still has to carry a signature from a key the
## client already holds, or [DotCloudClient] refuses it. So the worst a hostile server
## can do here is name a host that serves bytes which fail verification.
##
## Duck-typed like every other call into dot-cloud from this addon -- dot-server does
## not depend on it, and a build without it has no property to set.
func _adopt_content_bases(cloud: Object, urls: Variant) -> void:
	# [b]`PackedStringArray is Array` is FALSE, and this silently dropped everything
	# the server sent.[/b] The packed arrays are their own Variant types rather than
	# specialisations of [Array], so a `urls is Array` guard rejects exactly the value
	# the config holds and the RPC carries -- no error, no warning, just a client that
	# never learns the address. Found by the check below failing with "it had []" on a
	# payload that was demonstrably being sent.
	var list: Array = []
	if urls is PackedStringArray:
		list = Array(urls as PackedStringArray)
	elif urls is Array:
		list = urls as Array

	if list.is_empty():
		return
	if not (cloud.get("http_base_urls") is PackedStringArray):
		return

	var bases: PackedStringArray = cloud.get("http_base_urls")
	var added := PackedStringArray()

	for u in list:
		var one := str(u).strip_edges()
		# Re-sent on every game change, so without this the list grows by the same
		# addresses each time and every miss costs one more request than the last.
		if one != "" and not bases.has(one):
			bases.append(one)
			added.append(one)

	if added.is_empty():
		return

	cloud.set("http_base_urls", bases)
	DotLog.info(
		CHANNEL,
		"the server said where its content is",
		{"added": ", ".join(added)}
	)


func _on_cloud_progress(p: Dictionary) -> void:
	var fraction := float(p.get("fraction", 0.0))
	send_kind(DotEnvelope.CONTENT_PROGRESS, {"fraction": fraction})
	download_progress.emit(fraction, _progress_text(p))


static func _progress_text(p: Dictionary) -> String:
	var done := int(p.get("done_bytes", 0))
	var total := int(p.get("total_bytes", 0))
	if total <= 0:
		return "Downloading…"
	return "Downloading %s of %s" % [
		DotPaths.format_bytes(done), DotPaths.format_bytes(total)
	]


# --- Loading ---------------------------------------------------------------

## The server telling us which scene to load.
func _on_load_game(_peer_id: int, info: Dictionary) -> void:
	_set_phase(Phase.LOADING, "Loading…")

	var scene_path := str(info.get("scene", ""))
	var content_key := str(info.get("content_key", ""))

	server_game_id = str(info.get("game_id", ""))
	server_content_id = str(info.get("content_id", ""))
	server_game_name = str(info.get("display_name", server_game_id))

	if server_content_id == "":
		server_content_id = server_game_id

	# Before anything is loaded or freed, so a host that supplies its own scene for a
	# built-in game knows which one to supply — including on a change, where it also has to
	# take the previous one down. `_unload_scene` below only frees a scene *this* node
	# built, which for a built-in game is nothing.
	game_changed.emit(server_game_id, server_content_id, server_game_name)

	if scene_path == "":
		# A server with no scene is legitimate for a lobby, and the join has to
		# complete exactly as it does with one: tell the server we are ready, then
		# enter PLAYING and start the heartbeat.
		#
		# Reporting ready and returning was not enough. The server spawned the
		# session and the client sat in LOADING for ever, sending no heartbeats, so
		# it was eventually timed out for being idle — a server with no game scene
		# could not be joined at all. Nothing caught it because it needs a client and
		# a server at once, and only on a server with no game configured.
		send_kind(DotEnvelope.LOADED)
		_enter_playing()
		return

	var resolved := _resolve_scene(scene_path, info)

	if resolved == "":
		_fail(DotError.make(
			DotError.CODE_INVALID,
			"The server asked for a scene this client will not load.",
			scene_path
		))
		return

	if not ResourceLoader.exists(resolved):
		_fail(DotError.make(
			DotError.CODE_IO,
			"The game scene is missing from the downloaded content.",
			resolved
		))
		return

	_unload_scene()

	var packed := load(resolved)
	if not (packed is PackedScene):
		_fail(DotError.make(
			DotError.CODE_INVALID, "The game scene is not loadable.", resolved
		))
		return

	_scene_instance = (packed as PackedScene).instantiate()

	if _game_root == null:
		_game_root = game_root_ref.resolve_or_null(self, CHANNEL)

	_game_root.add_child(_scene_instance)

	DotLog.info(
		CHANNEL, "game loaded", {"scene": resolved, "content": content_key}
	)

	send_kind(DotEnvelope.LOADED)
	_enter_playing()


## Everything that has to happen once the join is complete.
##
## Factored out because there are two ways to finish loading — with a scene and
## without one — and they have to agree. They did not: the no-scene path skipped all
## three steps, which is a bug that only exists on a server with no game configured.
func _enter_playing() -> void:
	_set_phase(Phase.PLAYING, "")
	_heartbeat.start()
	spawned.emit()


## Turns the server's scene path into one this client will load.
##
## [b]The server does not get to name an absolute path.[/b] A relative path resolves
## under dot-cloud's mount prefix for the content the server named; an absolute
## [code]res://[/code] path is accepted only when it is already inside a mount
## prefix. Otherwise a malicious server could ask a client to load
## [code]res://addons/…[/code] or any scene shipped in the build.
func _resolve_scene(scene_path: String, info: Dictionary) -> String:
	if not scene_path.contains("://"):
		var safe := DotPaths.safe_relative(scene_path)
		if not safe.ok:
			DotLog.warn(
				CHANNEL,
				"refusing an unsafe scene path from the server",
				{"path": scene_path}
			)
			return ""

		var content_key := str(info.get("content_key", ""))
		if content_key == "":
			# No content, so a relative path has nothing to resolve against.
			return ""

		var parts := content_key.split("@", true, 1)
		var content_id := parts[0]
		var version := parts[1] if parts.size() > 1 else "0.0.0"

		return "res://dot_cloud/%s/%s/%s" % [content_id, version, safe.value]

	if scene_path.begins_with("res://dot_cloud/"):
		return scene_path

	DotLog.warn(
		CHANNEL,
		"refusing an absolute scene path outside the content mount",
		{"path": scene_path}
	)
	return ""


func _unload_scene() -> void:
	if _scene_instance == null:
		return
	if is_instance_valid(_scene_instance):
		_game_root.remove_child(_scene_instance)
		_scene_instance.free()
	_scene_instance = null


# --- Heartbeat -------------------------------------------------------------

func _send_heartbeat() -> void:
	if not _connected:
		return
	_ping_sent_ms = Time.get_ticks_msec()
	send_kind(DotEnvelope.HEARTBEAT, {"t": _ping_sent_ms}, DotEnvelope.Lane.UNRELIABLE)


## The server's reply, which is how ping is measured.
func _on_heartbeat_ack(_peer_id: int, payload: Dictionary) -> void:
	# Round trip measured from our own timestamp echoed back, so no clock
	# synchronisation is needed.
	var sent_ms := int(DotEnvelope.number(payload, "t", -1))
	if sent_ms < 0:
		return
	_ping_ms = Time.get_ticks_msec() - sent_ms
	send_kind(DotEnvelope.PING, {"ms": _ping_ms}, DotEnvelope.Lane.UNRELIABLE)


func ping_ms() -> int:
	return _ping_ms


# --- Background tabs -------------------------------------------------------

## Subscribes to the browser's visibility events. No-op off-web.
##
## Deliberately not gated on [member background_keepalive]: that is an exported
## property a host can change at runtime, and a listener installed once in
## [method _ready] could not honour a later change to it. The flag is checked where it
## is acted on instead. Listening costs nothing off-web, where
## [method DotWeb.watch_visibility] installs nothing at all — and
## [signal page_visibility_changed] is about the page rather than about the keepalive,
## so a game that wants to pause or mute on a tab switch gets it either way.
func _watch_page_visibility() -> void:
	# Keyed by instance rather than by class: two links in one process would
	# otherwise root their listeners under the same name, and the second would
	# silently replace the first.
	var key := "dot_client_link_visibility_%d" % get_instance_id()
	if DotWeb.watch_visibility(
		key, func(visible: bool) -> void: _on_page_visibility(visible)
	):
		_visibility_key = key


func _on_page_visibility(visible: bool) -> void:
	page_visibility_changed.emit(visible)

	if not background_keepalive or not _connected:
		return

	DotLog.debug(
		CHANNEL,
		"page visibility changed",
		{"visible": visible, "grace": background_grace_sec}
	)

	send_kind(DotEnvelope.VISIBILITY, {"visible": visible, "grace": background_grace_sec})

	if visible:
		# Coming back, the heartbeat timer resumes on its own — but its next tick is
		# up to heartbeat_interval_sec away, and the server has been counting silence
		# for the whole time the tab was hidden. Say something now rather than spend
		# any more of a budget that is already nearly gone.
		_send_heartbeat()

	_flush_peer()


## Pushes what [code]rpc_id[/code] queued out of the socket without waiting for a
## frame.
##
## [b]The announcement above has no frame to wait for.[/b] `visibilitychange` arrives
## as a JavaScript-to-wasm call, not as a frame callback, and it fires as the browser
## is stopping [code]requestAnimationFrame[/code] — so the poll that would ordinarily
## do the sending may never happen again. An announcement that never leaves is the
## same as no announcement, and costs the player the slot it was asking to keep.
func _flush_peer() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer == null:
		return
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	peer.poll()


# --- Chat ------------------------------------------------------------------

## Sends a chat message, or a chat command when it starts with a prefix.
func send_chat(text: String, team_only: bool = false) -> void:
	if not _connected or _chat == null:
		return
	_chat.send(text, team_only)


## The client's chat node. It declares no RPCs any more -- chat is two kinds on the
## envelope -- and is kept because games reach chat through it by name.
var _chat: DotClientChat = null


## A chat line, or chat's state, from the server. Handed to whoever listens on
## [signal chat_received], exactly as the RPC it replaced did.
func _on_chat_line(_peer_id: int, payload: Dictionary) -> void:
	chat_received.emit(payload)


## Creates the child that mirrors the server's chat node.
##
## Named to match [DotServer]'s [code]chat_ref[/code] default, because the name is
## the routing.
func _ensure_chat() -> void:
	if _chat != null and is_instance_valid(_chat):
		return

	_chat = DotClientChat.new()
	_chat.name = "Chat"
	_chat.link = self
	add_child(_chat)


# --- Notices ---------------------------------------------------------------

## The server's HUD line, countdown or cue. See [signal notice_received].
##
## Decoded through [method DotNotice.from_wire], which defaults and bounds every field:
## this is a Variant off the wire, and a server one build older or newer may send a shape
## this one has never seen. A payload that decodes to nothing is dropped here rather than
## handed to a HUD that would have to ask.
func _on_notice(_peer_id: int, payload: Dictionary) -> void:
	var notice := DotNotice.from_wire(payload)

	if notice.is_empty():
		return

	last_notice = notice
	DotLog.debug(CHANNEL, "notice", notice.describe())
	notice_received.emit(notice)


# --- Disconnection ---------------------------------------------------------

## The server explaining why it is about to close the connection.
##
## Sent before the socket closes, which is the only way a player learns they were
## banned rather than merely disconnected.
##
## A refusal for a protocol mismatch carries its code and detail, so a shell can tell
## "this build cannot play here" from a kick.
func _on_disconnect_notice(_peer_id: int, payload: Dictionary) -> void:
	var reason := DotEnvelope.text(payload, "reason")
	var code := DotEnvelope.text(payload, "code", DotError.CODE_FORBIDDEN)
	DotLog.info(CHANNEL, "disconnected by server", {"reason": reason, "code": code})
	last_error = DotError.make(code, reason, DotEnvelope.text(payload, "detail"))
	_set_phase(Phase.FAILED, reason)
	disconnected.emit(reason)


# --- State -----------------------------------------------------------------

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
	}
