extends Node

## The dedicated_server suite's harness: counters, checks, the RCON and WebSocket clients.

## Runs a command as the local console and returns its output.
func _run(line: String) -> String:
	var lines := PackedStringArray()
	var ctx := DotCmdContext.console("", PackedStringArray())
	ctx.reply_sink = func(text: String) -> void: lines.append(text)
	server.console.execute(line, ctx)
	return "\n".join(lines)

func _client_context(permissions: PackedStringArray) -> DotCmdContext:
	var ctx := DotCmdContext.new()
	ctx.source = DotCmdContext.Source.RCON
	ctx.permissions = permissions
	ctx.immunity = 10
	ctx.address = "203.0.113.1"
	ctx.reply_sink = func(_text: String) -> void: pass
	return ctx

const SELFTEST_ARG := "--selftest"

var server: DotServer
## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose.
const SECTIONS := 29

## Every check this suite runs, including the two at the end that compare the counts. The
## section counter cannot see a section that aborted after announcing itself — its remaining
## checks simply never run — and a total can. See docs/testing.md.
const CHECKS := 363

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0

## Stands in for a DotChatRelay, which this addon deliberately cannot name.
class FakeRelay extends RefCounted:
	func is_carrying() -> bool:
		return true

func _section(title: String) -> void:
	_entered += 1
	print(title)

## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1

func _check(what: String, passed: bool) -> void:
	if passed:
		_passed += 1
		print("  %-44s ok" % what)
	else:
		_failed += 1
		print("  %-44s FAILED" % what)

# --- RCON over a real socket ----------------------------------------------
#
# Everything above drives the console in-process. This section is the only place
# anything connects to the RCON listener over TCP and speaks the binary framing, so
# it is the only coverage of accept, the allow-list on a real peer address, the
# packet reader's partial and pipelined reads, auth, and response splitting.

const RCON_TYPE_RESPONSE := 0
const RCON_TYPE_AUTH_RESPONSE := 2
const RCON_TYPE_EXECCOMMAND := 2
const RCON_TYPE_AUTH := 3

## Builds one binary RCON packet. Deliberately written out rather than reusing the
## addon's encoder, so a change to the wire format fails this test.
func _rcon_encode(id: int, type: int, body: String) -> PackedByteArray:
	var body_bytes := body.to_utf8_buffer()
	var packet := PackedByteArray()
	packet.resize(4)
	packet.encode_s32(0, 4 + 4 + body_bytes.size() + 2)
	var header := PackedByteArray()
	header.resize(8)
	header.encode_s32(0, id)
	header.encode_s32(4, type)
	packet.append_array(header)
	packet.append_array(body_bytes)
	packet.append(0)
	packet.append(0)
	return packet

func _rcon_connect() -> StreamPeerTCP:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", server.config.effective_rcon_port()) != OK:
		return null
	for _i in 240:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			return peer
		if peer.get_status() == StreamPeerTCP.STATUS_ERROR:
			return null
		await get_tree().process_frame
	return null

## Pumps frames until [param want] packets have arrived, or the budget runs out.
##
## Frames matter: the RCON server accepts and reads in [code]_process[/code], so a
## test that only sleeps on the socket deadlocks against a server that never runs.
func _rcon_read(peer: StreamPeerTCP, want: int, frames: int = 180) -> Array:
	var buffer := PackedByteArray()
	var packets: Array = []
	for _i in frames:
		await get_tree().process_frame
		peer.poll()
		var available := peer.get_available_bytes()
		if available > 0:
			buffer.append_array(peer.get_data(available)[1])
		while buffer.size() >= 4:
			var size := buffer.decode_s32(0)
			if size < 10 or size > 8192:
				# Refuse to parse a size this test would not have asked for; an
				# oversized frame is a finding, not something to keep reading past.
				packets.append({"id": 0, "type": -1, "body": "", "size": size})
				return packets
			if buffer.size() < size + 4:
				break
			packets.append({
				"id": buffer.decode_s32(4),
				"type": buffer.decode_s32(8),
				"body": buffer.slice(12, size + 4 - 2).get_string_from_utf8(),
				"size": size,
			})
			buffer = buffer.slice(size + 4)
		if packets.size() >= want:
			break
	return packets

func _rcon_auth(peer: StreamPeerTCP, password: String, id: int = 7) -> Array:
	peer.put_data(_rcon_encode(id, RCON_TYPE_AUTH, password))
	return await _rcon_read(peer, 2)

## Opens a WebSocket to the RCON port and pumps frames until it is open.
##
## Frames matter for the same reason they do on the TCP path: the server accepts
## and polls in [code]_process[/code], so waiting on the socket alone deadlocks.
func _ws_connect(port: int) -> WebSocketPeer:
	var ws := WebSocketPeer.new()
	if ws.connect_to_url("ws://127.0.0.1:%d" % port) != OK:
		return null
	for _i in 240:
		await get_tree().process_frame
		ws.poll()
		var state := ws.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			return ws
		if state == WebSocketPeer.STATE_CLOSED:
			return null
	return null

func _ws_read(ws: WebSocketPeer, want: int, frames: int = 180) -> PackedStringArray:
	var out := PackedStringArray()
	for _i in frames:
		await get_tree().process_frame
		ws.poll()
		while ws.get_available_packet_count() > 0:
			out.append(ws.get_packet().get_string_from_utf8())
		if out.size() >= want:
			break
	return out

## A source that is a table keyed by uid, which is what every deployment's admin config is.
##
## dot-auth's source needs a live session to resolve a site group; this one needs nothing
## but the uid, and the difference is the whole reason `uid_permissions` asks the sources at
## all. It records whether it was ever handed a display name, so the check above can assert
## that a relayed author's NAME is not a key.
class UidTableSource:
	extends RefCounted

	var rows: Dictionary = {}
	var asked_with_display_name := false

	func source_name() -> String:
		return "uid-table"

	func lookup(identity: Object) -> DotResult:
		if identity == null:
			return DotResult.fail(DotError.CODE_STATE, "No identity.")

		var name: Variant = identity.get("display_name")
		if name != null and str(name) != "":
			asked_with_display_name = true

		var uid: Variant = identity.get("uid")
		var key := "" if uid == null else str(uid)

		if key == "" or not rows.has(key):
			return DotResult.fail(DotError.CODE_STATE, "Not listed.")

		return DotResult.success({
			"flags": rows[key],
			"immunity": 10,
			"source": source_name(),
		})
