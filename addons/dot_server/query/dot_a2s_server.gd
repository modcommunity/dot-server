@tool
class_name DotA2SServer
extends Node

## The A2S query protocol, so existing server trackers can see this server.
##
## [b]This exists for compatibility, not because it is good.[/b] A2S is a packed
## byte layout with positional fields, an extras bitfield, a multi-packet format
## that differs between engine branches, no room for anything a game knows about
## itself, and — until 2020 — no defence at all against being used as a DDoS
## amplifier. [DotQueryServer] is the protocol to reach for.
##
## What A2S has is twenty years of tooling. Every server-list site, every chat
## bot, every [code]python-a2s[/code] script and every "is my server up" monitor
## speaks it and speaks nothing else. A server that wants to appear in those places
## has to answer A2S, and inventing a better protocol does not change that.
##
## So: off by default ([member DotServerConfig.a2s_enabled]), on when an operator
## wants to be listed, and when on it answers on the game port over UDP — which is
## where every one of those tools looks.
##
## [b]Every request is challenged[/b], including [code]A2S_INFO[/code]. That was added
## that in 2020 after years of A2S reflection attacks and modern query libraries
## handle it; a library old enough not to is old enough to be a reflection risk.
## See [DotQueryChallenge].
##
## Requests handled: [code]A2S_INFO[/code] (0x54), [code]A2S_PLAYER[/code] (0x55),
## [code]A2S_RULES[/code] (0x56), [code]A2S_SERVERQUERY_GETCHALLENGE[/code] (0x57)
## and [code]A2A_PING[/code] (0x69).

const CHANNEL := "a2s"
const SERVICE := &"dot_a2s_server"

## Single-packet header: int32 -1.
const HEADER_SINGLE := 0xFFFFFFFF

## Multi-packet header: int32 -2.
const HEADER_MULTI := 0xFFFFFFFE

const REQUEST_INFO := 0x54          ## 'T'
const REQUEST_PLAYER := 0x55        ## 'U'
const REQUEST_RULES := 0x56         ## 'V'
const REQUEST_CHALLENGE := 0x57     ## 'W'
const REQUEST_PING := 0x69          ## 'i'

const RESPONSE_INFO := 0x49         ## 'I'
const RESPONSE_PLAYER := 0x44       ## 'D'
const RESPONSE_RULES := 0x45        ## 'E'
const RESPONSE_CHALLENGE := 0x41    ## 'A'
const RESPONSE_PING := 0x6A         ## 'j'

## The string an A2S_INFO request carries, null terminator included.
##
## Part of the wire format rather than a description of this server, so it is spelled
## exactly as the protocol spells it: a client sending anything else is not speaking
## A2S, and a server that accepted something else would answer nothing.
const INFO_PAYLOAD := "Source Engine Query"

## Protocol version byte. 17 is what the protocol's servers report and what
## clients expect.
const PROTOCOL_VERSION := 17

## Extra Data Flag bits, in the order A2S serialises them.
const EDF_PORT := 0x80
const EDF_STEAM_ID := 0x10
const EDF_SPECTATOR := 0x40
const EDF_KEYWORDS := 0x20
const EDF_GAME_ID := 0x01

## Size a client expects a split response to be chunked at.
const SPLIT_SIZE := 1248
const SPLIT_HEADER_BYTES := 12
const SPLIT_PAYLOAD_BYTES := SPLIT_SIZE - SPLIT_HEADER_BYTES

## Ceiling on a split response.
##
## Well under A2S's 255-packet limit. A full player list on a 4096-slot server
## would otherwise be a 200 kB reply to a 29-byte request, and the challenge only
## proves the address is real — not that it wants that much traffic.
const MAX_SPLIT_PACKETS := 8

## Longest string field written into a response.
const MAX_STRING_BYTES := 255

## Requests are tiny; anything larger is not one.
const MAX_REQUEST_BYTES := 512

signal query_answered(address: String, request_type: int)

var server: DotServer = null
var source: DotQuerySource = null

## Shared with [DotQueryServer] when they share a socket, so one secret covers both.
var challenge: DotQueryChallenge = null

var _udp: PacketPeerUDP = null
var _limiter: DotRateLimiter = null
var _next_split_id: int = 1

var _answered: int = 0
var _challenged: int = 0
var _refused: int = 0


func setup(p_server: DotServer, p_source: DotQuerySource) -> void:
	server = p_server
	source = p_source

	if challenge == null:
		challenge = DotQueryChallenge.new(server.config.query_challenge_ttl_sec)

	_limiter = DotRateLimiter.new(
		server.config.query_rate_per_second, server.config.query_rate_burst
	)

	DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	close()
	DotRegistry.unregister_instance(SERVICE, self)


# --- Socket ----------------------------------------------------------------

## Binds this responder's own UDP socket.
##
## Not called when [DotQueryServer] is listening on the same port — it owns the
## socket then and hands A2S datagrams over, since the two protocols are told apart
## by their first four bytes.
func open() -> DotResult:
	if not DotPlatform.can_listen():
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED, "This platform cannot listen for connections."
		)

	var port := server.config.effective_a2s_port()

	_udp = PacketPeerUDP.new()
	var err := _udp.bind(port, server.config.bind_address)

	if err != OK:
		_udp = null
		return DotResult.failure(DotError.from_engine(
			err,
			"binding the A2S port %d" % port
		)).wrap(_bind_advice(port))

	set_process(true)
	DotLog.info(CHANNEL, "A2S listening", {"port": port})
	return DotResult.success(port)


## Explains the failure that is almost always the reason for one.
##
## The default A2S port is the game port, because that is where every tracker
## looks. A server using ENet already holds that port over UDP, so the bind fails —
## and the fix is a different port plus the knowledge that most trackers will not
## find it there.
static func _bind_advice(port: int) -> String:
	return (
		"Could not open A2S on UDP %d. A transport using UDP (ENet) already holds "
		+ "that port; set a2s_port to a free one — but note most trackers only "
		+ "look at the game port."
	) % port


func close() -> void:
	if _udp != null:
		_udp.close()
		_udp = null


func is_listening() -> bool:
	return _udp != null


## Whether A2S requests are being answered right now.
##
## `sv_a2s 0` stops answering without closing anything, which is what an operator
## wants when a tracker is hammering them: A2S is the protocol most likely to be
## abused and the one most safely turned off, since nothing joining depends on it.
func is_answering() -> bool:
	if server == null or server.console == null:
		return true
	return server.console.get_bool("sv_a2s", true)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint() or _udp == null:
		return

	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		var address := _udp.get_packet_ip()
		var port := _udp.get_packet_port()

		for reply in handle_datagram(data, address, port):
			_udp.set_dest_address(address, port)
			_udp.put_packet(reply)


# --- Protocol --------------------------------------------------------------

## Whether a datagram is A2S. Four bytes, so it is safe to run on every packet.
static func looks_like_a2s(data: PackedByteArray) -> bool:
	if data.size() < 5:
		return false
	return data.decode_u32(0) == HEADER_SINGLE


## Answers one datagram. Returns the datagrams to send back, possibly none.
##
## Pure with respect to sockets, so [DotQueryServer] can call it for packets that
## arrive on a shared socket and so the self-test can exercise the whole protocol
## without opening one.
func handle_datagram(
	data: PackedByteArray, address: String, port: int
) -> Array[PackedByteArray]:
	var none: Array[PackedByteArray] = []

	if not is_answering():
		return none

	if data.size() > MAX_REQUEST_BYTES or not looks_like_a2s(data):
		return none

	# Rate limited before anything is built. An unchallenged request costs a hash
	# and nine bytes, and this keeps even that bounded.
	if not _limiter.allow(DotBanManager.normalise_address(address)):
		_refused += 1
		return none

	var request := data.decode_u8(4)

	match request:
		REQUEST_PING:
			# Deprecated in the protocol and answered anyway: the reply is smaller than
			# the request, so it cannot amplify, and some old monitors still use it
			# as a liveness check.
			return _single(_ping_response())

		REQUEST_CHALLENGE:
			_challenged += 1
			return _single(_challenge_response(address, port))

		REQUEST_INFO:
			if not _info_request_valid(data):
				return none
			if not _challenge_ok(data, _info_challenge_offset(data), address, port):
				_challenged += 1
				return _single(_challenge_response(address, port))
			_answered += 1
			query_answered.emit(address, request)
			return _split(_info_response())

		REQUEST_PLAYER:
			if not _challenge_ok(data, 5, address, port):
				_challenged += 1
				return _single(_challenge_response(address, port))
			_answered += 1
			query_answered.emit(address, request)
			return _split(_player_response())

		REQUEST_RULES:
			if not _challenge_ok(data, 5, address, port):
				_challenged += 1
				return _single(_challenge_response(address, port))
			_answered += 1
			query_answered.emit(address, request)
			return _split(_rules_response())

	return none


## An A2S_INFO request carries a fixed string; a packet without it is not one.
static func _info_request_valid(data: PackedByteArray) -> bool:
	var needed := 5 + INFO_PAYLOAD.length() + 1
	if data.size() < needed:
		return false
	return data.slice(5, 5 + INFO_PAYLOAD.length()).get_string_from_ascii() \
		== INFO_PAYLOAD


## Where the optional challenge sits in an A2S_INFO request.
static func _info_challenge_offset(_data: PackedByteArray) -> int:
	return 5 + INFO_PAYLOAD.length() + 1


func _challenge_ok(
	data: PackedByteArray, offset: int, address: String, port: int
) -> bool:
	if data.size() < offset + 4:
		return false
	return challenge.verify_a2s(address, port, data.decode_u32(offset))


# --- Responses -------------------------------------------------------------

func _challenge_response(address: String, port: int) -> PackedByteArray:
	var buf := _writer()
	buf.put_u8(RESPONSE_CHALLENGE)
	buf.put_u32(challenge.issue_a2s(address, port))
	return buf.data_array


func _ping_response() -> PackedByteArray:
	var buf := _writer()
	buf.put_u8(RESPONSE_PING)
	_put_cstring(buf, "00000000000000")
	return buf.data_array


func _info_response() -> PackedByteArray:
	var snap := source.snapshot()
	var info := snap.info
	var config := server.config

	var buf := _writer()
	buf.put_u8(RESPONSE_INFO)
	buf.put_u8(PROTOCOL_VERSION)

	_put_cstring(buf, str(info.get("name", "")))
	_put_cstring(buf, str(info.get("map", "")))
	_put_cstring(buf, str(info.get("folder", "dot")))
	_put_cstring(buf, str(info.get("game", "")))

	# App id is 16-bit and belongs to the platform. A game that has one puts it in
	# the config; one that does not sends 0, which every client tolerates.
	buf.put_u16(config.a2s_app_id & 0xFFFF)

	# Every count here is a byte. A 4096-slot server genuinely cannot be described
	# by A2S, so the value is clamped rather than allowed to wrap — 255 is wrong,
	# and 4096 & 0xFF = 0 is wrong in a way that reads as "empty server".
	buf.put_u8(mini(255, int(info.get("players", 0)) + int(info.get("bots", 0))))
	buf.put_u8(mini(255, int(info.get("max_players", 0))))
	buf.put_u8(mini(255, int(info.get("bots", 0))))

	buf.put_u8(0x64 if str(info.get("server_type", "")) == "dedicated" else 0x6C)
	buf.put_u8(_os_byte(str(info.get("os", "linux"))))
	buf.put_u8(1 if str(info.get("visibility", "")) == "password" else 0)
	buf.put_u8(1 if bool(info.get("secure", false)) else 0)

	_put_cstring(buf, str(info.get("version", "")))

	var tags := _keywords(snap)
	var edf := EDF_PORT
	if tags != "":
		edf |= EDF_KEYWORDS

	buf.put_u8(edf)
	buf.put_u16(config.port & 0xFFFF)
	if tags != "":
		_put_cstring(buf, tags)

	return buf.data_array


## The keywords string, which is the only extensible field A2S has.
##
## Server tags, plus the DQP port when that protocol is running. A tracker that
## understands [code]dqp:27015[/code] can upgrade to the protocol that will
## actually tell it something; one that does not shows a tag nobody minds.
func _keywords(snap: DotQuerySnapshot) -> String:
	var parts := PackedStringArray()

	for tag in server.config.tags:
		parts.append(str(tag))

	var query: Variant = snap.info.get("query")
	if query != null and typeof(query) == TYPE_DICTIONARY:
		parts.append("dqp:%d" % int((query as Dictionary).get("port", 0)))

	return ",".join(Array(parts))


func _player_response() -> PackedByteArray:
	var snap := source.snapshot()
	var players := snap.players

	var buf := _writer()
	buf.put_u8(RESPONSE_PLAYER)
	buf.put_u8(mini(255, players.size()))

	var index := 0
	for entry in players:
		var player: Dictionary = entry
		if index >= 255:
			break
		# The protocol numbers players from 0 in the response and the field is documented
		# as unreliable; the userid a game actually uses goes out over DQP.
		buf.put_u8(index)
		_put_cstring(buf, str(player.get("name", "")))
		buf.put_32(int(player.get("score", 0)))
		buf.put_float(float(player.get("duration", 0)))
		index += 1

	return buf.data_array


func _rules_response() -> PackedByteArray:
	var snap := source.snapshot()
	var rules := snap.rules

	var buf := _writer()
	buf.put_u8(RESPONSE_RULES)
	buf.put_u16(mini(65535, rules.size()))

	for name in rules:
		_put_cstring(buf, str(name))
		_put_cstring(buf, str(rules[name]))

	return buf.data_array


# --- Framing ---------------------------------------------------------------

func _writer() -> StreamPeerBuffer:
	var buf := StreamPeerBuffer.new()
	# A2S is little-endian throughout. StreamPeerBuffer already is, but a reader of
	# this file should not have to know that to trust the encoding.
	buf.big_endian = false
	return buf


## Writes a null-terminated UTF-8 string, truncated to fit.
##
## [b]Truncation is on bytes, not characters, and then repaired.[/b] A hostname
## with emoji in it cut at a byte boundary produces an invalid UTF-8 sequence, and
## a client that validates its input drops the whole response — a server that
## disappears from listings only once somebody renames it.
static func _put_cstring(buf: StreamPeerBuffer, text: String) -> void:
	var bytes := text.to_utf8_buffer()

	if bytes.size() > MAX_STRING_BYTES:
		bytes = bytes.slice(0, MAX_STRING_BYTES)
		# Drop trailing continuation bytes until what remains decodes.
		while not bytes.is_empty() and bytes.get_string_from_utf8() == "":
			bytes = bytes.slice(0, bytes.size() - 1)

	buf.put_data(bytes)
	buf.put_u8(0)


## Prefixes the single-packet header.
func _single(body: PackedByteArray) -> Array[PackedByteArray]:
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, HEADER_SINGLE)
	out.append_array(body)

	var packets: Array[PackedByteArray] = []
	packets.append(out)
	return packets


## Prefixes the header and splits the result if a client could not receive it whole.
##
## The reassembled payload is the complete single-packet response, leading
## [code]FF FF FF FF[/code] included — that is what every A2S client expects, and
## getting it wrong produces a response that reassembles into garbage rather than
## one that visibly fails.
func _split(body: PackedByteArray) -> Array[PackedByteArray]:
	var whole := PackedByteArray()
	whole.resize(4)
	whole.encode_u32(0, HEADER_SINGLE)
	whole.append_array(body)

	if whole.size() <= SPLIT_SIZE:
		var single: Array[PackedByteArray] = []
		single.append(whole)
		return single

	var total := int(ceil(float(whole.size()) / float(SPLIT_PAYLOAD_BYTES)))

	if total > MAX_SPLIT_PACKETS:
		total = MAX_SPLIT_PACKETS
		DotLog.debug(
			CHANNEL,
			"A2S response truncated to the split ceiling",
			{"bytes": whole.size(), "packets": total}
		)

	var split_id := _next_split_id
	_next_split_id += 1

	var packets: Array[PackedByteArray] = []

	for index in range(total):
		var start := index * SPLIT_PAYLOAD_BYTES
		var chunk := whole.slice(
			start, mini(start + SPLIT_PAYLOAD_BYTES, whole.size())
		)

		var packet := PackedByteArray()
		packet.resize(SPLIT_HEADER_BYTES)
		packet.encode_u32(0, HEADER_MULTI)
		packet.encode_u32(4, split_id)
		packet.encode_u8(8, total)
		packet.encode_u8(9, index)
		packet.encode_u16(10, SPLIT_SIZE)
		packet.append_array(chunk)

		packets.append(packet)

	return packets


static func _os_byte(name: String) -> int:
	match name:
		"windows": return 0x77   # 'w'
		"macos": return 0x6D     # 'm'
	return 0x6C                  # 'l'


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"listening": is_listening(),
		"answering": is_answering(),
		"port": server.config.effective_a2s_port() if server != null else 0,
		"answered": _answered,
		"challenged": _challenged,
		"refused": _refused,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if server == null:
		out.append("a2s not set up")
		return out

	out.append("port        %d/udp%s%s" % [
		server.config.effective_a2s_port(),
		"" if is_listening() else " (shared with the dot query listener)",
		"" if is_answering() else "  [sv_a2s 0: not answering]",
	])
	out.append("answered    %d" % _answered)
	out.append("challenged  %d" % _challenged)
	out.append("refused     %d (rate limited)" % _refused)
	out.append("app_id      %d" % server.config.a2s_app_id)
	return out
