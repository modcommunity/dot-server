@tool
extends "res://addons/dot_server/client/dot_client_link_loading.gd"

## Connecting, transport fallback and disconnecting of [DotClientLink].


## Connects to a server and runs the whole join flow.
## Returns when the client is playing, or with a failure naming the stage that went wrong.
func connect_to_server(address: String, password: String = "") -> DotResult:
	if _connected:
		disconnect_from_server()

	_password = password
	_last_address = address
	_set_phase(Phase.CONNECTING, "Connecting…")

	if transport != null:
		return await _connect_with(transport, address, transport.connect_timeout_sec)

	var udp := _udp_target(address)
	if udp != "":
		var enet := DotTransportENet.new()
		_trying_first = transport_preference != "udp"
		last_error = null
		var over_udp: DotResult = await _connect_with(
			enet, udp, udp_connect_timeout_sec if _trying_first else enet.connect_timeout_sec
		)
		_trying_first = false
		if over_udp.ok or transport_preference == "udp":
			return over_udp
		DotLog.info(
			CHANNEL,
			"UDP did not answer; falling back to WebSocket",
			{"udp": udp, "waited_sec": udp_connect_timeout_sec}
		)
		last_error = null
		_set_phase(Phase.CONNECTING, "Connecting…")

	var ws := DotTransportAuto.new()
	# A client must speak whatever the server listens on; WebSocket is the only
	# choice that works from a browser and also works natively.
	ws.require_web_clients = true

	if _tls_first(address):
		_trying_first = true
		last_error = null
		var secure: DotResult = await _connect_with(
			ws, "wss://" + address.strip_edges(), minf(ws.connect_timeout_sec, tls_connect_timeout_sec)
		)
		_trying_first = false
		if secure.ok:
			return secure
		DotLog.info(CHANNEL, "TLS did not answer; trying plain WebSocket", {"address": address})
		last_error = null
		_set_phase(Phase.CONNECTING, "Connecting…")
		ws = DotTransportAuto.new()
		ws.require_web_clients = true

	return await _connect_with(ws, address, ws.connect_timeout_sec)


## Whether a WebSocket join to [param address] tries [code]wss://[/code] before [code]ws://[/code].
## A public server's WebSocket port is behind TLS, so plain ws:// is answered "400 plain HTTP request"; a wrong guess costs [member tls_connect_timeout_sec].
## Only a bare host:port on native, never loopback or private (a LAN server is plain ws); an explicit scheme is obeyed.
func _tls_first(address: String) -> bool:
	if DotPlatform.is_web():
		return false
	var parts := DotTransport.normalise_address(address, 0)
	if str(parts["scheme"]) != "" or int(parts["port"]) <= 0:
		return false
	return not _is_local_host(str(parts["host"]))


static func _is_local_host(host: String) -> bool:
	var h := host.to_lower().trim_prefix("[").trim_suffix("]")
	if h == "" or h == "localhost" or h.ends_with(".local") or h.ends_with(".localhost"):
		return true
	# IPv6 literals only: a hostname may begin with "fc" or "fd" too.
	if h.contains(":"):
		return h == "::1" or h.begins_with("fe80:") or h.begins_with("fc") or h.begins_with("fd")
	if not h.is_valid_ip_address():
		return false
	var o := h.split(".")
	if o.size() != 4:
		return false
	var a := int(o[0])
	var b := int(o[1])
	return a == 127 or a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31) \
		or (a == 169 and b == 254) or (a == 100 and b >= 64 and b <= 127)


## The ENet address to try first, or "" to go straight to WebSocket.
func _udp_target(address: String) -> String:
	if transport_preference == "ws" or _secure_rejoin:
		return ""
	if DotPlatform.is_web() or not DotPlatform.has_udp() \
			or not ClassDB.class_exists("ENetMultiplayerPeer"):
		return ""
	if udp_address.strip_edges() != "":
		return udp_address.strip_edges()

	var parts := DotTransport.normalise_address(address, 0)
	var scheme := str(parts["scheme"])
	if scheme == "udp" or scheme == "enet":
		parts["scheme"] = ""
		return DotTransport.format_address(parts, false)
	if scheme != "" or str(parts["path"]) != "" or int(parts["port"]) <= 0:
		return ""
	return DotTransport.format_address(parts, false)


func _connect_with(t: DotTransport, address: String, timeout_sec: float) -> DotResult:
	var created := t.create_client(address)
	if not created.ok:
		if _trying_first:
			return DotResult.failure(created.error)
		return _fail(created.error)

	# Behind a meter, so a client can draw what its connection is doing (net_stat) on
	# either transport: WebSocket keeps no counts of its own, and a browser is a
	# WebSocket client. Invisible to SceneMultiplayer; see DotMeteredPeer.
	multiplayer.multiplayer_peer = DotMeteredPeer.wrap(created.value)

	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)

	var used := "enet" if t.scheme() == "udp" else "websocket"
	# Set here, not once the loop below sees the connect: the server's challenge can
	# arrive in the same frame as the connect, and the credential check reads this.
	transport_used = used
	DotLog.info(CHANNEL, "connecting", {"address": address, "transport": used})

	# The transport reports success or failure through signals rather than a return
	# value, so the connect is awaited with a timeout rather than checked.
	var deadline := Time.get_ticks_msec() + int(timeout_sec * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if _connected:
			DotLog.info(CHANNEL, "connected", {"transport": used})
			return DotResult.success(true)
		if phase == Phase.FAILED or (_trying_first and last_error != null):
			if _trying_first:
				multiplayer.multiplayer_peer.close()
				multiplayer.multiplayer_peer = null
			return DotResult.failure(
				last_error if last_error != null
				else DotError.make(DotError.CODE_NETWORK, "Could not connect.")
			)
		await get_tree().process_frame

	if _trying_first:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
		return DotResult.fail(DotError.CODE_TIMEOUT, "UDP did not answer.", address)

	multiplayer.multiplayer_peer = null
	return _fail(DotError.make(
		DotError.CODE_TIMEOUT,
		"The server did not respond.",
		address
	))


func disconnect_from_server(reason: String = "") -> void:
	_load_gen += 1
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

	_connected = false
	_heartbeat.stop()

	if _signon_watchdog != null:
		_signon_watchdog.stop()
	_unload_scene()

	# A failure survives the disconnect that reports it: every legible refusal is _fail() then a disconnect,
	# and an unconditional IDLE here wiped FAILED a frame later, so a watcher of the phase saw a blank idle screen.
	# A later connect_to_server sets CONNECTING first, so a lingering FAILED cannot pass for a new attempt.
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
	# A failed first attempt (UDP, or TLS) is not the join failing: the fallback is tried
	# next, and an ERROR line and a FAILED phase for it would be a lie the player sees.
	if _trying_first:
		last_error = DotError.make(DotError.CODE_NETWORK, "The first connect attempt failed.")
		return
	_fail(DotError.make(
		DotError.CODE_NETWORK,
		"Could not reach the server.",
		"the address may be wrong, or the server may be using a different transport"
	))


## The server accepted a socket and then never said anything.
## Most often a server built against a different addon version (the @rpc sets differ, so Godot never confirms the path); other causes look the same, so the message says "probably".
## The message names the fix a player can act on; the detail names the operator's.
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
## Shares the teardown with [method disconnect_from_server]: both endings must leave the same state, or a closed peer stays assigned.
## Clearing the peer from inside the poll that reported the drop is supported by [MultiplayerAPI].
func _on_server_disconnected() -> void:
	DotLog.info(CHANNEL, "server closed the connection")
	# No reason, so it does not emit; this function owns the reason it reports.
	disconnect_from_server()
	disconnected.emit("Connection to the server was lost.")
