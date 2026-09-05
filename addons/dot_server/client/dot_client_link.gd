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
## [b]The RPC method names and channels must match [DotServer] exactly.[/b] Godot
## routes RPCs by name, so a rename on one side silently stops the other from being
## called — which presents as a connection that establishes and then never
## progresses.
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

var phase: Phase = Phase.IDLE

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

var _game_root: Node = null
var _scene_instance: Node = null
var _heartbeat: Timer = null
var _ping_sent_ms: int = 0
var _ping_ms: int = -1
var _password: String = ""
var _connected: bool = false

## The cloud progress subscription, kept so it is only ever made once.
var _progress_handler: Callable = Callable()


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


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


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
	_unload_scene()
	_set_phase(Phase.IDLE, "")

	if reason != "":
		disconnected.emit(reason)


func _on_connected() -> void:
	_connected = true
	_set_phase(Phase.AUTHENTICATING, "Signing in…")
	DotLog.info(CHANNEL, "transport connected")


func _on_connection_failed() -> void:
	_fail(DotError.make(
		DotError.CODE_NETWORK,
		"Could not reach the server.",
		"the address may be wrong, or the server may be using a different transport"
	))


func _on_server_disconnected() -> void:
	DotLog.info(CHANNEL, "server closed the connection")
	_connected = false
	_heartbeat.stop()
	_unload_scene()
	_set_phase(Phase.IDLE, "")
	disconnected.emit("Connection to the server was lost.")


# --- Handshake -------------------------------------------------------------

## The server asking us to identify ourselves.
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _request_credentials(challenge: Dictionary) -> void:
	server_hostname = str(challenge.get("hostname", ""))
	server_id = str(challenge.get("server_id", ""))

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
	}

	if bool(challenge.get("needs_password", false)):
		payload["password"] = _password

	var strategy := str(challenge.get("auth", "none")).to_lower()
	await _attach_credential(payload, strategy)

	DotServer_submit_credentials(payload)


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


## Sends the credential payload to the server.
##
## Named to make the target obvious: it calls [code]submit_credentials[/code] on the
## server's [DotServer], which is a different node from this one.
func DotServer_submit_credentials(payload: Dictionary) -> void:
	submit_credentials.rpc_id(1, payload)


@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func submit_credentials(_payload: Dictionary) -> void:
	pass


static func _device_id() -> String:
	var unique := OS.get_unique_id()
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
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _begin_content_sync(info: Dictionary) -> void:
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

	DotLog.info(
		CHANNEL, "syncing content", {"content": content_key, "url": manifest_url}
	)

	var groups := PackedStringArray()
	for group in info.get("content_groups", []):
		groups.append(str(group))
	var res: Variant = await cloud.call("acquire", manifest_url, groups)

	if not (res is DotResult) or not (res as DotResult).ok:
		var err := (res as DotResult).error if res is DotResult else DotError.make(
			DotError.CODE_INTERNAL, "Content download failed."
		)
		_fail(err)
		return

	report_content_ready.rpc_id(1, content_key)


func _on_cloud_progress(p: Dictionary) -> void:
	var fraction := float(p.get("fraction", 0.0))
	report_content_progress.rpc_id(1, fraction)
	download_progress.emit(fraction, _progress_text(p))


static func _progress_text(p: Dictionary) -> String:
	var done := int(p.get("done_bytes", 0))
	var total := int(p.get("total_bytes", 0))
	if total <= 0:
		return "Downloading…"
	return "Downloading %s of %s" % [
		DotPaths.format_bytes(done), DotPaths.format_bytes(total)
	]


@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func report_content_progress(_fraction: float) -> void:
	pass


@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func report_content_ready(_content_key: String) -> void:
	pass


# --- Loading ---------------------------------------------------------------

## The server telling us which scene to load.
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _load_game(info: Dictionary) -> void:
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
		report_loaded.rpc_id(1)
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

	report_loaded.rpc_id(1)
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


@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func report_loaded() -> void:
	pass


# --- Heartbeat -------------------------------------------------------------

func _send_heartbeat() -> void:
	if not _connected:
		return
	_ping_sent_ms = Time.get_ticks_msec()
	heartbeat.rpc_id(1, _ping_sent_ms)


@rpc("any_peer", "unreliable", "call_remote", CHANNEL_CONTROL)
func heartbeat(_client_time_ms: int) -> void:
	pass


## The server's reply, which is how ping is measured.
@rpc("authority", "unreliable", "call_remote", CHANNEL_CONTROL)
func _heartbeat_ack(client_time_ms: int) -> void:
	# Round trip measured from our own timestamp echoed back, so no clock
	# synchronisation is needed.
	_ping_ms = Time.get_ticks_msec() - client_time_ms
	report_ping.rpc_id(1, _ping_ms)


@rpc("any_peer", "unreliable", "call_remote", CHANNEL_CONTROL)
func report_ping(_ping: int) -> void:
	pass


func ping_ms() -> int:
	return _ping_ms


# --- Chat ------------------------------------------------------------------

## Sends a chat message, or a chat command when it starts with a prefix.
func send_chat(text: String, team_only: bool = false) -> void:
	if not _connected or _chat == null:
		return
	_chat.send(text, team_only)


## The chat RPCs live on a child node, not here. See [DotClientChat].
##
## Briefly: Godot refuses an RPC unless both ends declare the same set of
## [code]@rpc[/code] methods, and the server's chat methods are on a different node.
## Declaring them here made every RPC between client and server fail, handshake
## included.
var _chat: DotClientChat = null


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


# --- Disconnection ---------------------------------------------------------

## The server explaining why it is about to close the connection.
##
## Sent before the socket closes, which is the only way a player learns they were
## banned rather than merely disconnected.
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _disconnected(reason: String) -> void:
	DotLog.info(CHANNEL, "disconnected by server", {"reason": reason})
	last_error = DotError.make(DotError.CODE_FORBIDDEN, reason)
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
	}
