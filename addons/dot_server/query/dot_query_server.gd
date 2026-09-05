@tool
class_name DotQueryServer
extends Node

## The dot query protocol: what a server browser should have been able to ask.
##
## A2S answers four fixed questions. This answers whatever the server and the game
## know, in a document that can grow, over a transport a browser can actually reach.
## See [DotQueryProtocol] for the wire format and [DotA2SServer] for the
## compatibility shim that runs beside it.
##
## What it does that A2S cannot:
##
## [b]It is safe by construction.[/b] Every UDP query is challenged with an
## address-bound cookie before a single byte of payload is built, so the protocol
## cannot be used to attack a third party. A2S ran for fifteen years without that.
##
## [b]It says more than four things.[/b] Sections are requested à la carte — info,
## players, rules, and whatever the game contributes through a [DotQueryProvider].
## Round numbers, team scores, the next map and a lobby's ready count are fields
## rather than substrings smuggled into the keywords.
##
## [b]It tells the truth about a join in progress.[/b] Clients that are connected
## but still downloading are counted separately, which is the difference between
## "empty server" and "server nobody can finish joining".
##
## [b]Polling it is nearly free.[/b] Every response carries a revision that changes
## only when something meaningful did. A tracker sends the revision it holds and
## gets forty bytes back when nothing moved. A list of a thousand servers refreshed
## every thirty seconds costs almost nothing on either end.
##
## [b]A browser can use it.[/b] With [member DotServerConfig.query_websocket] on,
## the same protocol is served over WebSocket as plain JSON. A web page cannot open
## a UDP socket, so an in-browser server browser is not possible over A2S at any
## price — and "click a link and play" needs a server list the link can come from.
##
## Registered as [code]dot_query_server[/code] in [DotRegistry].

const CHANNEL := "query"
const SERVICE := &"dot_query_server"

## Most a single querier may ask for in one request.
const MAX_SECTIONS := 8

## Simultaneous WebSocket queriers.
##
## A query connection exists to ask a question and go away; a limit this low is
## generous for that and stops the listener being a way to hold file descriptors.
const MAX_WEBSOCKET_CLIENTS := 32

## Seconds a WebSocket querier may sit idle before it is dropped.
const WEBSOCKET_IDLE_MS := 30_000

## Largest text frame accepted from a WebSocket querier.
const MAX_WEBSOCKET_REQUEST_BYTES := 4096

signal query_answered(address: String, sections: PackedStringArray)

var server: DotServer = null
var source: DotQuerySource = null
var challenge: DotQueryChallenge = null

var _udp: PacketPeerUDP = null
var _tcp: TCPServer = null
var _ws_clients: Array[Dictionary] = []

## The A2S responder sharing this socket, when both are on the same port.
var _a2s: DotA2SServer = null

var _limiter: DotRateLimiter = null
var _next_response_id: int = 1

var _answered: int = 0
var _unchanged: int = 0
var _challenged: int = 0
var _refused: int = 0


func setup(p_server: DotServer, p_source: DotQuerySource) -> void:
	server = p_server
	source = p_source
	challenge = DotQueryChallenge.new(server.config.query_challenge_ttl_sec)

	_limiter = DotRateLimiter.new(
		server.config.query_rate_per_second, server.config.query_rate_burst
	)

	DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	close()
	DotRegistry.unregister_instance(SERVICE, self)


# --- Listening -------------------------------------------------------------

func open() -> DotResult:
	if not DotPlatform.can_listen():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "This platform cannot listen for connections."
		)

	var config := server.config
	var port := config.effective_query_port()

	_udp = PacketPeerUDP.new()
	var err := _udp.bind(port, config.bind_address)

	if err != OK:
		_udp = null
		return DotResult.failure(DotError.from_engine(
			err, "binding the query port %d" % port
		)).wrap(
			"Could not open the dot query listener on UDP %d. A UDP transport "
			% port + "(ENet) already holds that port; set query_port to a free one."
		)

	DotLog.info(CHANNEL, "query listening", {"port": port})

	if config.query_websocket:
		_open_websocket()

	set_process(true)
	return DotResult.success(port)


func _open_websocket() -> void:
	var port := server.config.effective_query_websocket_port()

	_tcp = TCPServer.new()
	var err := _tcp.listen(port, server.config.bind_address)

	if err != OK:
		_tcp = null
		DotLog.warn(
			CHANNEL,
			"could not open the query WebSocket port",
			{"port": port, "detail": error_string(err)}
		)
		return

	DotLog.info(CHANNEL, "query WebSocket listening", {"port": port})


## Hands A2S datagrams arriving on this socket to the A2S responder.
##
## The two protocols are told apart by their first four bytes, so sharing one port
## costs a comparison — and sharing it is what lets a server answer both on the
## game port, which is the only port a tracker will look at.
func attach_a2s(a2s: DotA2SServer) -> void:
	_a2s = a2s
	# One secret for both, so an operator reading `query_status` sees one challenge
	# window rather than two that expire at different times.
	a2s.challenge = challenge
	DotLog.info(
		CHANNEL,
		"A2S sharing the query socket",
		{"port": server.config.effective_query_port()}
	)


func close() -> void:
	for client in _ws_clients:
		_close_ws_client(client)
	_ws_clients.clear()

	if _udp != null:
		_udp.close()
		_udp = null
	if _tcp != null:
		_tcp.stop()
		_tcp = null


func is_listening() -> bool:
	return _udp != null


## Whether queries are being answered right now.
##
## Separate from [method is_listening]: `sv_query 0` stops answering without
## closing the socket, so an operator riding out a flood can turn it back on
## without a restart and without the port changing under whatever was polling it.
func is_answering() -> bool:
	if server == null or server.console == null:
		return true
	return server.console.get_bool("sv_query", true)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return

	_poll_udp()
	_poll_websocket()


func _poll_udp() -> void:
	if _udp == null:
		return

	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		var address := _udp.get_packet_ip()
		var port := _udp.get_packet_port()

		for reply in handle_datagram(data, address, port):
			_udp.set_dest_address(address, port)
			_udp.put_packet(reply)


# --- UDP protocol ----------------------------------------------------------

## Answers one datagram. Returns the datagrams to send back, possibly none.
##
## Socket-free, so the self-test drives the entire protocol without binding a port
## — which also means the protocol is tested on a machine where binding is refused.
func handle_datagram(
	data: PackedByteArray, address: String, port: int
) -> Array[PackedByteArray]:
	var none: Array[PackedByteArray] = []

	if _a2s != null and DotA2SServer.looks_like_a2s(data):
		return _a2s.handle_datagram(data, address, port)

	if not is_answering():
		return none

	if data.size() > DotQueryProtocol.MAX_REQUEST_BYTES:
		_refused += 1
		return none

	if not DotQueryProtocol.looks_like_dqp(data):
		# Silence rather than an error reply. Answering an unrecognised datagram
		# tells a scanner something and gives a spoofer a response to aim.
		return none

	if not _limiter.allow(DotBanManager.normalise_address(address)):
		_refused += 1
		return none

	var parsed := DotQueryProtocol.parse(data)
	if not parsed.ok:
		return none

	var packet: Dictionary = parsed.value
	var checked := DotQueryProtocol.check_request(packet)
	if not checked.ok:
		return none

	var txn := int(packet["txn"])

	match int(packet["type"]):
		DotQueryProtocol.TYPE_PING:
			return DotQueryProtocol.build(
				DotQueryProtocol.TYPE_PONG, txn, 0, PackedByteArray()
			)

		DotQueryProtocol.TYPE_CHALLENGE_REQUEST:
			_challenged += 1
			return DotQueryProtocol.build_challenge(
				txn, challenge.issue(address, port)
			)

		DotQueryProtocol.TYPE_QUERY:
			if not challenge.verify(address, port, int(packet["challenge"])):
				# The whole anti-amplification control: an unchallenged query is
				# answered with a cookie and nothing else, and that reply is
				# smaller than the request that asked for it.
				_challenged += 1
				return DotQueryProtocol.build_challenge(
					txn, challenge.issue(address, port)
				)

			return _answer(packet, address, txn)

	return none


func _answer(
	packet: Dictionary, address: String, txn: int
) -> Array[PackedByteArray]:
	var request: Dictionary = packet.get("body", {})
	var sections := _requested_sections(request)

	var body := _build_body(request, sections)

	var accepts_gzip := bool(
		int(packet.get("flags", 0)) & DotQueryProtocol.FLAG_ACCEPT_GZIP
	)
	var encoded := DotQueryProtocol.encode_body(body, accepts_gzip)

	var payload: PackedByteArray = encoded[0]
	if payload.size() > DotQueryProtocol.MAX_RESPONSE_BYTES:
		# Refused rather than truncated. A body cut off mid-JSON reaches the
		# querier as a parse failure they will read as a broken server, and the
		# fix — ask for fewer sections — is something only they can do.
		_refused += 1
		return DotQueryProtocol.build_error(
			txn,
			DotError.CODE_QUOTA,
			"Response too large (%d bytes, limit %d). Ask for fewer sections."
				% [payload.size(), DotQueryProtocol.MAX_RESPONSE_BYTES]
		)

	var response_id := _next_response_id
	_next_response_id += 1

	_answered += 1
	query_answered.emit(address, sections)

	return DotQueryProtocol.build(
		DotQueryProtocol.TYPE_RESULT,
		txn,
		int(packet.get("challenge", 0)),
		payload,
		int(encoded[1]),
		response_id
	)


## The body of a result, shared by the UDP and WebSocket paths.
func _build_body(request: Dictionary, sections: PackedStringArray) -> Dictionary:
	var snap := source.snapshot()

	# Conditional query. A tracker that already holds this revision gets told so
	# and nothing else — the difference between a few dozen bytes and a few
	# kilobytes, multiplied by every server in a list and every refresh.
	var if_rev := int(request.get("if_rev", 0))
	if if_rev > 0 and if_rev == snap.rev:
		_unchanged += 1
		return source.sign(snap.to_unchanged_dict())

	return source.sign(snap.to_dict(sections))


## Which sections a request asked for, refusing anything unreasonable.
static func _requested_sections(request: Dictionary) -> PackedStringArray:
	var raw: Variant = request.get("sections")

	if raw == null or typeof(raw) != TYPE_ARRAY:
		return PackedStringArray([DotQuerySnapshot.SECTION_INFO])

	var out := PackedStringArray()
	for entry in (raw as Array):
		if out.size() >= MAX_SECTIONS:
			break
		var name := str(entry)
		if not out.has(name):
			out.append(name)

	if out.is_empty():
		return PackedStringArray([DotQuerySnapshot.SECTION_INFO])

	return out


# --- WebSocket -------------------------------------------------------------

## The same protocol as plain JSON, for queriers that cannot send a datagram.
##
## [b]No challenge here, and that is not an oversight.[/b] The cookie exists to
## prove a UDP source address is real. A WebSocket has already completed a TCP
## handshake and an HTTP upgrade, so the address is proven by the transport, and
## the response goes back down the same connection where it cannot be aimed at
## anybody else. Requiring a cookie as well would be ritual.
func _poll_websocket() -> void:
	if _tcp == null:
		return

	while _tcp.is_connection_available():
		var peer := _tcp.take_connection()
		if peer == null:
			continue

		if _ws_clients.size() >= MAX_WEBSOCKET_CLIENTS:
			peer.disconnect_from_host()
			continue

		_ws_clients.append({
			"tcp": peer,
			"ws": null,
			"address": peer.get_connected_host(),
			"buffer": PackedByteArray(),
			"last_seen": Time.get_ticks_msec(),
		})

	var still_open: Array[Dictionary] = []
	for client in _ws_clients:
		if _poll_ws_client(client):
			still_open.append(client)
		else:
			_close_ws_client(client)
	_ws_clients = still_open


func _poll_ws_client(client: Dictionary) -> bool:
	if Time.get_ticks_msec() - int(client["last_seen"]) > WEBSOCKET_IDLE_MS:
		return false

	if client["ws"] != null:
		var ws: WebSocketPeer = client["ws"]
		ws.poll()

		var ready := ws.get_ready_state()
		if ready == WebSocketPeer.STATE_CLOSED:
			return false
		if ready != WebSocketPeer.STATE_OPEN:
			return true

		while ws.get_available_packet_count() > 0:
			client["last_seen"] = Time.get_ticks_msec()
			var frame := ws.get_packet()
			if frame.size() > MAX_WEBSOCKET_REQUEST_BYTES:
				return false
			_answer_websocket(client, frame.get_string_from_utf8())

		return true

	var tcp: StreamPeerTCP = client["tcp"]
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
	client["buffer"] = buffer

	if buffer.size() > MAX_WEBSOCKET_REQUEST_BYTES:
		return false

	var text := buffer.get_string_from_utf8()
	if not text.contains("\r\n\r\n"):
		return true

	if not text.to_lower().contains("upgrade: websocket"):
		return false

	var ws_peer := WebSocketPeer.new()
	if ws_peer.accept_stream(tcp) != OK:
		return false

	client["ws"] = ws_peer
	client["buffer"] = PackedByteArray()
	client["last_seen"] = Time.get_ticks_msec()
	return true


func _answer_websocket(client: Dictionary, text: String) -> void:
	var address := str(client["address"])

	if not is_answering():
		_send_websocket(client, {
			"code": DotError.CODE_STATE, "error": "Queries are disabled."
		})
		return

	if not _limiter.allow(DotBanManager.normalise_address(address)):
		_refused += 1
		_send_websocket(client, {"code": DotError.CODE_RATE_LIMITED, "error": "Slow down."})
		return

	var request: Dictionary = {}

	if text.strip_edges() != "":
		var parsed: Variant = JSON.parse_string(text)
		if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
			_send_websocket(client, {
				"code": DotError.CODE_PARSE, "error": "Send a JSON object."
			})
			return
		request = parsed as Dictionary

	var sections := _requested_sections(request)

	_answered += 1
	query_answered.emit(address, sections)

	_send_websocket(client, _build_body(request, sections))


func _send_websocket(client: Dictionary, body: Dictionary) -> void:
	if client["ws"] == null:
		return
	var ws: WebSocketPeer = client["ws"]
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	ws.send_text(JSON.stringify(body))


func _close_ws_client(client: Dictionary) -> void:
	if client["ws"] != null:
		(client["ws"] as WebSocketPeer).close()
	var tcp: StreamPeerTCP = client["tcp"]
	if tcp != null:
		tcp.disconnect_from_host()


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"listening": is_listening(),
		"answering": is_answering(),
		"port": server.config.effective_query_port() if server != null else 0,
		"websocket": _tcp != null,
		"answered": _answered,
		"unchanged": _unchanged,
		"challenged": _challenged,
		"refused": _refused,
		"a2s_shared": _a2s != null,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if server == null:
		out.append("query not set up")
		return out

	out.append("port        %d/udp%s%s" % [
		server.config.effective_query_port(),
		" (+ a2s)" if _a2s != null else "",
		"" if is_answering() else "  [sv_query 0: not answering]",
	])
	if _tcp != null:
		out.append("websocket   %d/tcp (%d connected)" % [
			server.config.effective_query_websocket_port(), _ws_clients.size()
		])
	out.append("answered    %d (%d unchanged)" % [_answered, _unchanged])
	out.append("challenged  %d" % _challenged)
	out.append("refused     %d (rate limited or oversized)" % _refused)
	if challenge != null:
		out.append("challenge   %.0fs window" % (challenge.ttl_sec * 2.0))
	return out
