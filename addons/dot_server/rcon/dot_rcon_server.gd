@tool
class_name DotRconServer
extends Node

## Remote console, speaking the classic RCON protocol.
##
## Wire-compatible with existing RCON tooling, which is the point: server operators
## already have clients, web panels and scripts that speak it, and inventing a
## protocol would mean none of them work.
##
## Also serves the same console over WebSocket when
## [member DotServerConfig.rcon_websocket] is on, because a browser cannot open a raw
## TCP socket and a browser-based admin panel is the thing most operators actually
## want.
##
## [b]RCON is a remote shell.[/b] Treat every control here as load-bearing:
##
## - No password means the listener does not open at all. There is no configuration
##   that produces an unauthenticated RCON.
## - Passwords are compared in constant time.
## - Failed attempts are counted per address and lock it out.
## - An allow-list, when set, is checked before the password — it is the control that
##   survives a leaked password.
## - The protocol is plaintext, as every implementation of it is. Run it over a
##   private network or a
##   tunnel; the WebSocket variant can at least have TLS in front of it.

const CHANNEL := "rcon"
const SERVICE := &"dot_rcon_server"

## RCON packet types.
const TYPE_RESPONSE := 0
const TYPE_AUTH_RESPONSE := 2
const TYPE_EXECCOMMAND := 2
const TYPE_AUTH := 3

## The protocol's limit is 4096; anything larger is not a real command.
const MAX_PACKET_BYTES := 4096

## Largest response body sent in one packet.
##
## Real clients handle multi-packet responses inconsistently, so long output is
## split at line boundaries into several complete packets rather than fragmented.
const MAX_RESPONSE_BYTES := 3500

signal authenticated(address: String)
signal auth_failed(address: String, attempts: int)
signal command_received(address: String, command: String)

var server: DotServer = null

var _tcp: TCPServer = null
var _ws: TCPServer = null

## Connected sessions: each is a dictionary of state per socket.
var _clients: Array[Dictionary] = []

## address -> failure count
var _failures: Dictionary = {}

## address -> unix seconds when the lockout lifts
var _lockouts: Dictionary = {}

var _limiter: DotRateLimiter = null
var _next_client_id: int = 1


func setup(p_server: DotServer) -> void:
	server = p_server
	DotRegistry.register(SERVICE, self)

	if server.config.rcon_password == "":
		DotLog.info(CHANNEL, "RCON disabled (no password)")
		return

	# Commands per address per minute. Generous for a human, and enough to stop a
	# script from using RCON to make the server do work.
	_limiter = DotRateLimiter.new(2.0, 20.0)

	var started := _start()
	if not started.ok:
		DotLog.error(
			CHANNEL,
			"could not start RCON",
			{"detail": started.error.message}
		)
		return

	set_process(true)


func _exit_tree() -> void:
	_close_all()
	DotRegistry.unregister_instance(SERVICE, self)


func _start() -> DotResult:
	if not DotPlatform.can_listen():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"This platform cannot listen for connections."
		)

	var port := server.config.effective_rcon_port()

	_tcp = TCPServer.new()
	var err := _tcp.listen(port, server.config.bind_address)
	if err != OK:
		return DotResult.failure(
			DotError.from_engine(err, "listening for RCON on port %d" % port)
		)

	DotLog.info(
		CHANNEL,
		"RCON listening",
		{
			"port": port,
			"allow_list": Array(server.config.rcon_allowed_addresses)
				if not server.config.rcon_allowed_addresses.is_empty() else "any",
		}
	)

	if server.config.rcon_websocket:
		var ws_port := server.config.effective_rcon_websocket_port()
		_ws = TCPServer.new()
		var ws_err := _ws.listen(ws_port, server.config.bind_address)
		if ws_err != OK:
			DotLog.warn(
				CHANNEL,
				"could not open the RCON WebSocket port",
				{"port": ws_port, "detail": error_string(ws_err)}
			)
			_ws = null
		else:
			DotLog.info(CHANNEL, "RCON WebSocket listening", {"port": ws_port})

	return DotResult.success(port)


func is_listening() -> bool:
	return _tcp != null


# --- Accept and poll ------------------------------------------------------

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return

	_accept_from(_tcp, false)
	_accept_from(_ws, true)
	_poll_clients()


func _accept_from(listener: TCPServer, websocket: bool) -> void:
	if listener == null:
		return

	while listener.is_connection_available():
		var peer := listener.take_connection()
		if peer == null:
			continue

		var address := peer.get_connected_host()

		if not _address_allowed(address):
			DotLog.warn(
				CHANNEL,
				"RCON connection refused: address not allowed",
				{"from": address}
			)
			peer.disconnect_from_host()
			continue

		if _is_locked_out(address):
			DotLog.warn(
				CHANNEL,
				"RCON connection refused: address locked out",
				{"from": address}
			)
			peer.disconnect_from_host()
			continue

		var ws: WebSocketPeer = null

		if websocket:
			# WebSocketPeer.accept_stream() performs the HTTP handshake itself: it
			# reads the request off the stream and writes the 101 response. So the
			# stream must be handed over untouched. Reading the request here first
			# to inspect it — which is what this used to do — consumes the bytes the
			# peer is waiting for, and the upgrade then never completes at all.
			ws = WebSocketPeer.new()
			var ws_err := ws.accept_stream(peer)
			if ws_err != OK:
				DotLog.warn(
					CHANNEL,
					"WebSocket upgrade failed",
					{"from": address, "detail": error_string(ws_err)}
				)
				peer.disconnect_from_host()
				continue

		_clients.append({
			"id": _next_client_id,
			"tcp": peer,
			"ws": ws,
			"is_websocket": websocket,
			"authed": false,
			"address": address,
			"buffer": PackedByteArray(),
			"connected_at": Time.get_ticks_msec(),
		})
		_next_client_id += 1

		DotLog.debug(
			CHANNEL,
			"RCON client connected",
			{"from": address, "websocket": websocket}
		)


func _poll_clients() -> void:
	var still_open: Array[Dictionary] = []

	for client in _clients:
		if _poll_client(client):
			still_open.append(client)
		else:
			_close_client(client)

	_clients = still_open


## Polls one client. Returns false when it should be dropped.
func _poll_client(client: Dictionary) -> bool:
	var tcp: StreamPeerTCP = client["tcp"]

	# An unauthenticated socket that just sits there is a slot being held open.
	# This covers the WebSocket path too, including a handshake that never
	# completes: that port is meant to be reachable from a browser, so it is the
	# easier of the two to hold slots on.
	if not bool(client["authed"]) \
		and Time.get_ticks_msec() - int(client["connected_at"]) > 30_000:
		DotLog.debug(
			CHANNEL,
			"dropping an RCON client that never authenticated",
			{"from": client["address"]}
		)
		return false

	if client["is_websocket"]:
		if client["ws"] == null:
			return false

		var ws: WebSocketPeer = client["ws"]
		ws.poll()

		var ws_state := ws.get_ready_state()
		if ws_state == WebSocketPeer.STATE_CLOSED:
			return false
		if ws_state != WebSocketPeer.STATE_OPEN:
			return true

		while ws.get_available_packet_count() > 0:
			var packet := ws.get_packet()
			# A browser panel sends a plain command string rather than framing it
			# as a binary RCON packet; there is nothing to gain from making JavaScript
			# build binary packets.
			_handle_text_command(client, packet.get_string_from_utf8())

		return true

	tcp.poll()

	var status := tcp.get_status()
	if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		return false
	if status != StreamPeerTCP.STATUS_CONNECTED:
		return true

	var available := tcp.get_available_bytes()
	if available <= 0:
		return true

	var buffer: PackedByteArray = client["buffer"]
	buffer.append_array(tcp.get_data(available)[1])

	if buffer.size() > MAX_PACKET_BYTES * 4:
		# Well past any legitimate command. Either a broken client or an attempt to
		# make the server buffer indefinitely.
		DotLog.warn(
			CHANNEL,
			"dropping an RCON client that sent too much data",
			{"from": client["address"], "bytes": buffer.size()}
		)
		return false

	client["buffer"] = _consume_packets(client, buffer)
	return true


# --- The binary protocol --------------------------------------------------

## Reads complete packets out of the buffer, leaving any partial tail.
##
## Framing is: int32 size (of everything after it), int32 id, int32 type, then the
## body and two NUL terminators. A short read is normal on a stream socket, so the
## remainder is kept rather than discarded.
func _consume_packets(
	client: Dictionary,
	buffer: PackedByteArray
) -> PackedByteArray:
	while buffer.size() >= 4:
		var size := buffer.decode_s32(0)

		if size < 10 or size > MAX_PACKET_BYTES:
			DotLog.warn(
				CHANNEL,
				"malformed RCON packet size",
				{"from": client["address"], "size": size}
			)
			return PackedByteArray()

		if buffer.size() < size + 4:
			# Wait for the rest.
			return buffer

		var packet_id := buffer.decode_s32(4)
		var packet_type := buffer.decode_s32(8)

		# Body is everything between the header and the two trailing NULs.
		var body_bytes := buffer.slice(12, size + 4 - 2)
		var body := body_bytes.get_string_from_utf8()

		buffer = buffer.slice(size + 4)

		_handle_packet(client, packet_id, packet_type, body)

	return buffer


func _handle_packet(
	client: Dictionary,
	packet_id: int,
	packet_type: int,
	body: String
) -> void:
	var address := str(client["address"])

	if packet_type == TYPE_AUTH:
		_handle_auth(client, packet_id, body)
		return

	if packet_type == TYPE_EXECCOMMAND:
		if not bool(client["authed"]):
			# The established behaviour: an unauthenticated command gets an auth failure
			# rather than an error, so existing clients handle it correctly.
			_send_packet(client, -1, TYPE_AUTH_RESPONSE, "")
			return

		_execute(client, packet_id, body)
		return

	DotLog.debug(
		CHANNEL,
		"ignoring an unknown RCON packet type",
		{"from": address, "type": packet_type}
	)


func _handle_auth(
	client: Dictionary,
	packet_id: int,
	password: String
) -> void:
	var address := str(client["address"])

	if _is_locked_out(address):
		_send_packet(client, -1, TYPE_AUTH_RESPONSE, "")
		return

	var expected := server.config.rcon_password

	# Constant time: comparing with == leaks how many leading characters matched,
	# which turns guessing a password into guessing it one character at a time.
	var ok := DotHash.constant_time_equal(
		password.to_utf8_buffer(), expected.to_utf8_buffer()
	)

	if not ok:
		var attempts := int(_failures.get(address, 0)) + 1
		_failures[address] = attempts

		DotLog.warn(
			CHANNEL,
			"RCON authentication failed",
			{"from": address, "attempts": attempts}
		)

		auth_failed.emit(address, attempts)

		if server.audit != null:
			server.audit.record(
				"rcon_auth_failed", address, "", {"attempts": attempts}
			)

		if attempts >= server.config.rcon_max_failures:
			_lockouts[address] = int(Time.get_unix_time_from_system()) + int(
				server.config.rcon_lockout_sec
			)
			DotLog.warn(
				CHANNEL,
				"RCON address locked out",
				{
					"from": address,
					"seconds": int(server.config.rcon_lockout_sec),
				}
			)

		# The protocol sends an empty response then an auth response with id -1 on
		# failure. Real clients depend on both.
		if not bool(client["is_websocket"]):
			_send_packet(client, packet_id, TYPE_RESPONSE, "")
		_send_packet(client, -1, TYPE_AUTH_RESPONSE, "")
		return

	client["authed"] = true
	_failures.erase(address)

	DotLog.info(CHANNEL, "RCON authenticated", {"from": address})
	authenticated.emit(address)

	if server.audit != null:
		server.audit.record("rcon_auth", address, "", {})

	if not bool(client["is_websocket"]):
		_send_packet(client, packet_id, TYPE_RESPONSE, "")
	_send_packet(client, packet_id, TYPE_AUTH_RESPONSE, "")


func _execute(
	client: Dictionary,
	packet_id: int,
	command_line: String
) -> void:
	var address := str(client["address"])

	if not _limiter.allow(address):
		_send_response(client, packet_id, "Rate limited. Slow down.")
		return

	var trimmed := command_line.strip_edges()
	if trimmed == "":
		_send_response(client, packet_id, "")
		return

	DotLog.info(CHANNEL, "rcon command", {"from": address, "cmd": trimmed})
	command_received.emit(address, trimmed)

	var lines := PackedStringArray()

	var ctx := DotCmdContext.new()
	ctx.source = DotCmdContext.Source.RCON
	ctx.address = address
	# An authenticated RCON session holds the RCON flag and everything else the
	# password implies. Whoever has the password can already do anything the
	# console can, so pretending to a finer granularity here would be theatre.
	ctx.permissions = PackedStringArray([DotAdminFlags.ROOT])
	ctx.immunity = DotAdminFlags.MAX_IMMUNITY
	ctx.reply_sink = func(line: String) -> void: lines.append(line)

	server.console.execute(trimmed, ctx)

	_send_response(client, packet_id, "\n".join(lines))


## Sends a response, split into several packets if it is long.
##
## Split at line boundaries rather than at byte offsets: a client that concatenates
## packets gets the same text, and one that does not at least gets whole lines.
func _send_response(
	client: Dictionary,
	packet_id: int,
	text: String
) -> void:
	# Measured in bytes, not characters. The limit the protocol imposes is on the
	# encoded packet, and one accented or CJK character is two to four bytes: a
	# response of 2400 characters can be 4800 bytes and overrun MAX_PACKET_BYTES,
	# which this server's own reader — and every real client — then rejects.
	if text.to_utf8_buffer().size() <= MAX_RESPONSE_BYTES:
		_send_packet(client, packet_id, TYPE_RESPONSE, text)
		return

	var chunk := ""
	var chunk_bytes := 0

	for line in text.split("\n"):
		# A single line can be longer than one packet on its own, in which case
		# there is no line boundary to split at and it is cut by bytes instead.
		for piece in _split_to_byte_limit(line + "\n"):
			var piece_bytes := piece.to_utf8_buffer().size()
			# Only flush a chunk that has something in it. Flushing an empty one
			# put a stray zero-length packet on the wire ahead of every over-long
			# line.
			if chunk_bytes > 0 and chunk_bytes + piece_bytes > MAX_RESPONSE_BYTES:
				_send_packet(client, packet_id, TYPE_RESPONSE, chunk)
				chunk = ""
				chunk_bytes = 0
			chunk += piece
			chunk_bytes += piece_bytes

	if chunk != "":
		_send_packet(client, packet_id, TYPE_RESPONSE, chunk)


## Cuts [param text] into pieces that each encode to at most
## [constant MAX_RESPONSE_BYTES] bytes, never splitting a character in half.
##
## Only reached by a line with no interior newline to break at, so the per-character
## walk costs nothing in the normal case.
static func _split_to_byte_limit(text: String) -> PackedStringArray:
	var out := PackedStringArray()

	if text.to_utf8_buffer().size() <= MAX_RESPONSE_BYTES:
		out.append(text)
		return out

	var piece := ""
	var piece_bytes := 0

	for i in text.length():
		var character := text[i]
		var character_bytes := character.to_utf8_buffer().size()
		if piece_bytes > 0 and piece_bytes + character_bytes > MAX_RESPONSE_BYTES:
			out.append(piece)
			piece = ""
			piece_bytes = 0
		piece += character
		piece_bytes += character_bytes

	if piece != "":
		out.append(piece)

	return out


func _send_packet(
	client: Dictionary,
	packet_id: int,
	packet_type: int,
	body: String
) -> void:
	if bool(client["is_websocket"]) and client["ws"] != null:
		var ws: WebSocketPeer = client["ws"]
		# The auth handshake is two packets, one of them always empty. Over a
		# WebSocket that framing does not exist, and _handle_text_command writes
		# its own wording instead, so the filler is suppressed here.
		if packet_type == TYPE_AUTH_RESPONSE:
			return
		# An empty body is not suppressed: plenty of commands succeed with no
		# output, and a panel that receives nothing cannot tell that apart from a
		# dead socket.
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			ws.send_text(body)
		return

	var body_bytes := body.to_utf8_buffer()

	var packet := PackedByteArray()
	packet.resize(4)
	# Size covers id, type, body and both terminators — everything after the size
	# field itself.
	packet.encode_s32(0, 4 + 4 + body_bytes.size() + 2)

	var header := PackedByteArray()
	header.resize(8)
	header.encode_s32(0, packet_id)
	header.encode_s32(4, packet_type)

	packet.append_array(header)
	packet.append_array(body_bytes)
	packet.append(0)
	packet.append(0)

	var tcp: StreamPeerTCP = client["tcp"]
	tcp.put_data(packet)


# --- WebSocket ------------------------------------------------------------

## Handles a command sent as plain text over WebSocket.
##
## The first message must be the password; everything after it is a command. Simpler
## than the binary framing because a browser panel has no reason to reproduce it.
func _handle_text_command(client: Dictionary, text: String) -> void:
	var trimmed := text.strip_edges()

	if not bool(client["authed"]):
		_handle_auth(client, 1, trimmed)
		if bool(client["authed"]):
			_send_packet(client, 1, TYPE_RESPONSE, "Authenticated.\n")
		else:
			_send_packet(client, 1, TYPE_RESPONSE, "Authentication failed.\n")
		return

	_execute(client, 1, trimmed)


# --- Access control ------------------------------------------------------

func _address_allowed(address: String) -> bool:
	return address_matches(address, server.config.rcon_allowed_addresses)


## Whether [param address] is covered by [param allow].
##
## Static and free of any socket so a self-test can drive it directly. The
## allow-list is the control that survives a leaked password, so both directions
## matter: an address it wrongly admits is a hole, and an address it wrongly
## refuses locks an operator out of their own console.
##
## An empty list allows everything, which is what "no allow-list configured"
## means. [method DotServerConfig.warn_about_risky_settings] says so out loud.
static func address_matches(address: String, allow: PackedStringArray) -> bool:
	if allow.is_empty():
		return true

	var forms := _address_forms(address)

	for entry in allow:
		# Normalised on both sides. The exact comparison always was; the prefix
		# comparison used the raw entry, so an entry carrying a scheme, a port or
		# stray whitespace silently matched nothing at all.
		var candidate := DotBanManager.normalise_address(entry)
		if candidate == "":
			continue

		# Prefix matching, so "192.168." covers a subnet without needing CIDR
		# parsing. Coarse, and enough for the "my LAN" case this is usually for.
		# The trailing dot is what anchors it to an octet boundary, so "192.16."
		# does not cover 192.168.1.1.
		var is_prefix := candidate.ends_with(".")

		for form in forms:
			if form == candidate:
				return true
			if is_prefix and form.begins_with(candidate):
				return true

	return false


## The IPv4-mapped IPv6 prefix.
##
## A listener bound to a dual-stack socket reports a connecting IPv4 client as
## "::ffff:192.168.1.5". That is the same address written differently, so an
## allow-list holding either spelling has to cover the other — otherwise an
## operator who allowed 127.0.0.1 is refused by their own server the moment it
## binds IPv6, with a log line that says only that the address was not allowed.
const V4_MAPPED_PREFIX := "::ffff:"


## Every spelling of [param address] an allow-list entry could reasonably use.
static func _address_forms(address: String) -> PackedStringArray:
	var host := DotBanManager.normalise_address(address)
	var forms := PackedStringArray([host])

	if host.to_lower().begins_with(V4_MAPPED_PREFIX):
		var bare := host.substr(V4_MAPPED_PREFIX.length())
		if bare.count(".") == 3:
			forms.append(bare)
	elif host.count(".") == 3 and not host.contains(":"):
		forms.append(V4_MAPPED_PREFIX + host)

	return forms


func _is_locked_out(address: String) -> bool:
	var host := DotBanManager.normalise_address(address)
	if not _lockouts.has(host):
		return false

	if int(Time.get_unix_time_from_system()) >= int(_lockouts[host]):
		_lockouts.erase(host)
		_failures.erase(host)
		return false

	return true


## Clears a lockout, for an operator who locked themselves out.
func clear_lockout(address: String) -> void:
	var host := DotBanManager.normalise_address(address)
	_lockouts.erase(host)
	_failures.erase(host)


# --- Teardown ------------------------------------------------------------

func _close_client(client: Dictionary) -> void:
	if client["ws"] != null:
		(client["ws"] as WebSocketPeer).close()
	var tcp: StreamPeerTCP = client["tcp"]
	if tcp != null:
		tcp.disconnect_from_host()


func _close_all() -> void:
	for client in _clients:
		_close_client(client)
	_clients.clear()

	if _tcp != null:
		_tcp.stop()
		_tcp = null
	if _ws != null:
		_ws.stop()
		_ws = null


func client_count() -> int:
	return _clients.size()


func authenticated_count() -> int:
	var n := 0
	for client in _clients:
		if bool(client["authed"]):
			n += 1
	return n


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if _tcp == null:
		out.append("rcon disabled")
		return out

	out.append("port        %d" % server.config.effective_rcon_port())
	if _ws != null:
		out.append("websocket   %d" % server.config.effective_rcon_websocket_port())
	out.append("clients     %d (%d authenticated)" % [
		_clients.size(), authenticated_count()
	])
	out.append("lockouts    %d" % _lockouts.size())

	for client in _clients:
		out.append("  %-24s %s" % [
			str(client["address"]),
			"authenticated" if bool(client["authed"]) else "unauthenticated",
		])

	return out
