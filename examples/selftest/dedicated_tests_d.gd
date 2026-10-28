extends "res://examples/selftest/dedicated_tests_c.gd"

## Notice and RCON sections of dedicated_server.gd.

## [DotNotice]'s wire form, and the server's half with nobody to send to. The half with a
## client is in `signon_revision`; this shows the decoder survives a payload no server of this
## build sends, because a client may not raise.
func _test_notices() -> void:
	print("")
	_section("[notices]")

	var full := DotNotice.make(&"vote_start", "Vote now", 30.0, &"game_vote")
	var back := DotNotice.from_wire(full.to_wire())
	_check(
		"a notice survives its own wire form",
		back.cue == full.cue and back.text == full.text
			and is_equal_approx(back.seconds, full.seconds) and back.topic == full.topic
	)

	# A bare cue is one key. Absent and default decode the same, and a countdown of
	# zero is NOT what "no countdown" means -- a HUD shows a line that has run out.
	var bare := DotNotice.make(&"vote_count")
	_check("a bare cue is one key on the wire", bare.to_wire().size() == 1)
	_check(
		"and comes back with no countdown",
		not DotNotice.from_wire(bare.to_wire()).has_countdown()
	)
	_check(
		"a countdown of zero is still a countdown",
		DotNotice.make(&"", "go", 0.0).has_countdown()
	)

	_check("a topic and nothing else is a clear", DotNotice.clear(&"x").is_clear())
	_check("and a clear is not empty", not DotNotice.clear(&"x").is_empty())
	_check("a notice with nothing on it is empty", DotNotice.new().is_empty())

	_test_notices_bounds()

func _test_notices_bounds() -> void:
	# Bounded, because this is drawn on a HUD: a newline pushes the next line off the
	# panel and a thousand characters cover the game.
	var long := DotNotice.make(&"", "line one\nline two" + "x".repeat(500))
	_check("a line has no control characters", not long.text.contains("\n"))
	_check("and is bounded", long.text.length() == DotNotice.MAX_TEXT)
	# The same list chat refuses, because the same client draws both. DEL, a zero-width
	# space and joiner, a byte-order mark, a right-to-left override and an isolate: every
	# one of them passed when this stripped only what is below 32.
	var spoof := DotNotice.make(&"", "a\u007Fb\u200Bc\u200Dd\uFEFFe\u202Ef\u2066g\nh")
	_check("and none of the characters chat refuses (%s)" % spoof.text.c_escape(), spoof.text == "abcdefg h")
	# Every character dot-chat's filter refuses, written out rather than read from the
	# constant, so the constant shrinking is visible here.
	var refused := PackedStringArray()
	for code in [0x00AD, 0x061C, 0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
			0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060, 0x2061, 0x2062, 0x2063, 0x2064,
			0x2066, 0x2067, 0x2068, 0x2069, 0x206A, 0x206B, 0x206C, 0x206D, 0x206E, 0x206F,
			0xFEFF]:
		refused.append(String.chr(code))
	for code in range(0x80, 0xA0):
		refused.append(String.chr(code))
	var every := DotNotice.make(&"", "a" + "".join(refused) + "b")
	_check("nor any character dot-chat's filter refuses (%s)" % every.text.c_escape(), every.text == "ab")
	# A host that fills the fields itself skipped make(); the wire form bounds them again,
	# because what the server sends is the server's to decide, not the receiving client's.
	var by_hand := DotNotice.new()
	by_hand.text = "a\u202Eb\u200Fc\nd" + "x".repeat(500)
	by_hand.topic = StringName("t".repeat(200))
	by_hand.seconds = INF
	var sent := by_hand.to_wire()
	_check(
		"a notice built by hand is bounded on its way out, not only on its way in",
		str(sent.get("text", "")).begins_with("abc d") \
			and str(sent.get("text", "")).length() == DotNotice.MAX_TEXT \
			and str(sent.get("topic", "")).length() == DotNotice.MAX_ID \
			and not sent.has("seconds")
	)
	# The wire is plain text, drawn by a plain Label; a rich-text client escapes it itself,
	# and in one pass, or "[a]" comes out as "[lb[rb]a[rb]".
	var marked := DotNotice.make(&"", "[b]x[/b]")
	_check(
		"a line's markup stays text on the wire, and escapes whole for rich text (%s)" % marked.bbcode_text(),
		marked.text == "[b]x[/b]" and marked.bbcode_text() == "[lb]b[rb]x[lb]/b[rb]"
	)
	# Whether the linear sanitiser is still strip, collapse, then cut — the definition it
	# replaced — over inputs built to sit on every edge: spaces at the cut, runs that
	# collapse across a refused character, all-refused text, and limits of 0, 1 and 2.
	var mismatch := _sanitise_mismatch()
	_check("the sanitiser is still strip, collapse, then cut%s" % ("" if mismatch == "" else ": " + mismatch),
		mismatch == "")
	# A megabyte from a caller that meant a line. Built by `+=` and cut at the end, this
	# was a copy of the whole string per character kept.
	var started := Time.get_ticks_msec()
	var huge := DotNotice.make(&"", "word ".repeat(200000))
	var took := Time.get_ticks_msec() - started
	_check("a megabyte is read no further than the line it makes (%d ms)" % took,
		took < 1000 and huge.text.length() == DotNotice.MAX_TEXT)
	_check(
		"a countdown that could not be computed is none, not an hour",
		not DotNotice.make(&"", "", NAN).has_countdown()
	)
	_check(
		"and one past the ceiling is clamped to it",
		is_equal_approx(DotNotice.make(&"", "", 1.0e9).seconds, DotNotice.MAX_SECONDS)
	)

	_test_notices_decode()

func _test_notices_decode() -> void:
	var full := DotNotice.make(&"vote_start", "Vote now", 30.0, &"game_vote")
	# The decoder's whole job: a Variant it did not choose. Every one of these must come
	# back as a notice rather than as a runtime error in a client's RPC handler.
	_check("a non-dictionary decodes to nothing", DotNotice.from_wire("x").is_empty())
	_check("so does null", DotNotice.from_wire(null).is_empty())
	var odd := DotNotice.from_wire({"cue": 7, "text": ["a"], "seconds": "10", "topic": &"t"})
	_check(
		"fields of the wrong type are dropped, the rest kept",
		odd.cue == &"" and odd.text == "" and not odd.has_countdown() and odd.topic == &"t"
	)
	_check(
		"an integer countdown is read as seconds",
		is_equal_approx(DotNotice.from_wire({"seconds": 5}).seconds, 5.0)
	)
	_check(
		"a field this build has never heard of is ignored",
		DotNotice.from_wire({"cue": "a", "colour": "red"}).cue == &"a"
	)

	# The server half with nobody connected. Sent to nobody, and said so: a host mirroring
	# notices into a log still hears the one it meant.
	var heard: Array[int] = []
	var on_sent := func(_n: DotNotice, count: int) -> void: heard.append(count)
	server.notice_sent.connect(on_sent)

	_check("a broadcast to nobody reaches nobody", server.broadcast_notice(full) == 0)
	_check("and is still reported", heard.size() == 1 and heard[0] == 0)
	_check("an empty notice is not even that", server.broadcast_notice(DotNotice.new()) == 0)
	_check("and is not reported", heard.size() == 1)
	_check("nothing is sent to no session", not server.send_notice(null, full))

	# An adopted session has no peer. rpc_id at it is an engine error on a path that is
	# otherwise working, which is how error output stops being read.
	var adopted := DotClientSession.new()
	adopted.local = true
	_check("nor to one with no peer", not server.send_notice(adopted, full))

	server.notice_sent.disconnect(on_sent)
	_done()

func _test_rcon_allow_list() -> void:
	_section("[rcon allow-list]")

	# The allow-list is the control that survives a leaked RCON password, and it
	# had no executed coverage at all. Driven through the static entry point so
	# the checks need no socket, then tied back to the live server below.
	var lan := PackedStringArray(["192.168."])
	var host := PackedStringArray(["127.0.0.1"])

	_check("an empty allow-list allows anything",
		DotRconServer.address_matches("203.0.113.9", PackedStringArray()))
	_check("an exact address is allowed",
		DotRconServer.address_matches("127.0.0.1", host))
	_check("any other address is refused",
		not DotRconServer.address_matches("203.0.113.9", host))

	# The containment case: the trailing dot has to anchor the prefix to an octet
	# boundary, or "192.16." quietly covers the whole of 192.168.0.0/16.
	_check("a subnet prefix covers its subnet",
		DotRconServer.address_matches("192.168.1.5", lan))
	_check("a subnet prefix stops at the octet boundary",
		not DotRconServer.address_matches("192.168.1.1",
			PackedStringArray(["192.16."])))
	_check("a subnet prefix does not cover a different subnet",
		not DotRconServer.address_matches("10.0.0.4", lan))

	# A dual-stack listener reports an IPv4 client mapped into IPv6. Both
	# spellings are the same address and each has to match an entry written in
	# the other, or the operator is refused by their own server.
	_check("a mapped IPv4 client matches a bare entry",
		DotRconServer.address_matches("::ffff:127.0.0.1", host))
	_check("a mapped IPv4 client matches a bare subnet prefix",
		DotRconServer.address_matches("::ffff:192.168.1.5", lan))
	_check("a bare IPv4 client matches a mapped entry",
		DotRconServer.address_matches("127.0.0.1",
			PackedStringArray(["::ffff:127.0.0.1"])))
	_check("mapping does not admit an address the list never had",
		not DotRconServer.address_matches("::ffff:203.0.113.9", host))

	# The entry side is normalised too. It was not, so an entry carrying a port,
	# a scheme or stray whitespace matched nothing and said nothing about it.
	_check("an entry carrying a port still matches the host",
		DotRconServer.address_matches("127.0.0.1",
			PackedStringArray(["127.0.0.1:27055"])))
	_check("an entry carrying a scheme still prefix-matches",
		DotRconServer.address_matches("192.168.1.5",
			PackedStringArray(["tcp://192.168."])))
	_check("an entry with stray whitespace still prefix-matches",
		DotRconServer.address_matches("192.168.1.5",
			PackedStringArray(["  192.168.  "])))
	_check("an empty entry matches nothing",
		not DotRconServer.address_matches("127.0.0.1",
			PackedStringArray([""])))

	# Documented behaviour, asserted so it cannot drift into a silent hole: a
	# prefix without its trailing dot matches nothing. DotServerConfig warns
	# about exactly this shape.
	_check("a prefix missing its trailing dot matches nothing",
		not DotRconServer.address_matches("192.168.1.5",
			PackedStringArray(["192.168"])))

	_check("an IPv6 client matches an IPv6 entry",
		DotRconServer.address_matches("::1", PackedStringArray(["::1"])))

	await _test_rcon_allow_list_live()

func _test_rcon_allow_list_live() -> void:
	# And the live object agrees with the static, so the wiring is checked and
	# not just the arithmetic.
	var rcon := server.rcon
	if rcon == null:
		_check("rcon is present", false)
		return
	_check("the running RCON server allows its configured address",
		rcon._address_allowed("127.0.0.1"))
	_check("the running RCON server refuses anything else",
		not rcon._address_allowed("203.0.113.9"))
	# A scanner dialling the port seven times in a row logs one WARN, not seven.
	var warns: Array[Dictionary] = []
	var on_record := func(rec: Dictionary) -> void:
		if str(rec.get("channel", "")) == "rcon" and int(rec.get("level", -1)) == DotLog.Level.WARN:
			warns.append(rec)
	DotLog.signals().record.connect(on_record)
	var refuser := DotRconServer.new()
	for n in 7:
		refuser._log_refusal("167.94.146.48", "RCON connection refused: address not allowed")
	refuser._log_refusal("203.0.113.9", "RCON connection refused: address not allowed")
	DotLog.signals().record.disconnect(on_record)
	_check("seven refusals from one address log one WARN (plus the other address's)", warns.size() == 2)
	_check("the quiet count is held for the address that was muted", int(refuser._refusals_quiet.get("167.94.146.48", 0)) == 6)

	refuser.free()

	# Both tables shrink once the window has passed: a refilled bucket is dropped by time.
	var scan := DotRconServer.new()
	scan._refusal_log = DotRateLimiter.new(100.0, 1.0)
	scan._refusal_log.idle_eviction_sec = 0.02
	scan._refusal_log.sweep_interval_ms = 0
	for n in 3:
		scan._log_refusal("198.51.100.%d" % n, "RCON connection refused: address not allowed")
		scan._log_refusal("198.51.100.%d" % n, "RCON connection refused: address not allowed")
	var before := scan._refusal_log.tracked_count() + scan._refusals_quiet.size()
	await get_tree().create_timer(0.1).timeout
	scan._log_refusal("203.0.113.77", "RCON connection refused: address not allowed")
	scan._log_refusal("203.0.113.77", "RCON connection refused: address not allowed")
	_check("after the window only the live address is tracked (%d entries before)" % before,
		before == 6 and scan._refusal_log.tracked_count() == 1 and scan._refusals_quiet.size() == 1)
	scan.free()

	_done()

func _test_rcon_socket() -> void:
	print("")
	_section("[rcon over a socket]")

	var password := server.config.rcon_password

	# 1. A wrong password. The protocol answers with an empty RESPONSE and then an
	#    AUTH_RESPONSE carrying id -1; real clients key off the -1.
	var bad := await _rcon_connect()
	_check("a real client can connect", bad != null)
	if bad == null:
		return

	var bad_reply := await _rcon_auth(bad, "not-the-password")
	_check("a bad password is answered", bad_reply.size() == 2)
	_check(
		"a bad password gives auth id -1",
		bad_reply.size() == 2
			and bad_reply[1]["type"] == RCON_TYPE_AUTH_RESPONSE
			and bad_reply[1]["id"] == -1
	)

	# An unauthenticated command must not execute, and must look like an auth
	# failure rather than an error, which is what existing RCON clients expect.
	bad.put_data(_rcon_encode(11, RCON_TYPE_EXECCOMMAND, "status"))
	var refused := await _rcon_read(bad, 1)
	_check(
		"a command before auth is refused as auth failure",
		refused.size() >= 1
			and refused[0]["type"] == RCON_TYPE_AUTH_RESPONSE
			and refused[0]["id"] == -1
			and not refused[0]["body"].contains("hostname:")
	)
	bad.disconnect_from_host()

	# 2. The real password. A success echoes the client's own id back, which is how
	#    a client tells "authenticated" from "rejected".
	var peer := await _rcon_connect()
	_check("a second client can connect", peer != null)
	if peer == null:
		return

	var ok_reply := await _rcon_auth(peer, password, 7)
	_check(
		"the right password authenticates",
		ok_reply.size() == 2
			and ok_reply[1]["type"] == RCON_TYPE_AUTH_RESPONSE
			and ok_reply[1]["id"] == 7
	)

	await _test_rcon_socket_commands(peer)

func _test_rcon_socket_commands(peer: StreamPeerTCP) -> void:
	# 3. A command actually runs, over the socket, as root.
	peer.put_data(_rcon_encode(21, RCON_TYPE_EXECCOMMAND, "status"))
	var status := await _rcon_read(peer, 1)
	_check(
		"an authenticated command executes",
		status.size() >= 1 and status[0]["body"].contains("hostname:")
	)
	_check(
		"the response carries the request id",
		status.size() >= 1 and status[0]["id"] == 21
	)

	# 4. A packet split across two writes. Normal on a stream socket, and the
	#    reader keeps a partial tail precisely for this.
	var whole := _rcon_encode(31, RCON_TYPE_EXECCOMMAND, "echo split-ok")
	peer.put_data(whole.slice(0, 6))
	await get_tree().process_frame
	await get_tree().process_frame
	peer.put_data(whole.slice(6))
	var split := await _rcon_read(peer, 1)
	_check(
		"a packet split across two writes is reassembled",
		split.size() >= 1 and split[0]["body"].contains("split-ok")
	)

	# 5. Two packets in one write. A client is allowed to pipeline, and the reader
	#    loops rather than handling one packet per poll.
	var pipelined := _rcon_encode(41, RCON_TYPE_EXECCOMMAND, "echo first")
	pipelined.append_array(_rcon_encode(42, RCON_TYPE_EXECCOMMAND, "echo second"))
	peer.put_data(pipelined)
	var both := await _rcon_read(peer, 2)
	_check(
		"two pipelined packets are both answered",
		both.size() >= 2
			and both[0]["body"].contains("first")
			and both[1]["body"].contains("second")
	)

	await _test_rcon_long_responses(peer)

	peer.disconnect_from_host()
	_done()
## Drives the WebSocket console as a browser panel would: upgrade, text auth (the password is the
## first text message, not a binary AUTH packet) and the text command loop.
## covered by nothing at all.
func _test_rcon_websocket() -> void:
	print("")
	_section("[rcon over websocket]")

	var port := server.config.effective_rcon_websocket_port()
	_check("the websocket port is distinct from the rcon port", port != server.config.effective_rcon_port())

	var ws := await _ws_connect(port)
	_check("a browser client completes the upgrade", ws != null)
	if ws == null:
		return

	# 1. A wrong password must not authenticate, and must say so rather than
	#    leaving the panel waiting.
	ws.send_text("not-the-password")
	var bad := await _ws_read(ws, 1)
	_check(
		"a bad password is rejected",
		bad.size() >= 1 and bad[0].contains("failed")
	)

	# 2. A command sent while unauthenticated must not execute. The socket is
	#    still in its auth state, so the text is treated as another password
	#    attempt rather than as a command.
	ws.send_text("status")
	var refused := await _ws_read(ws, 1)
	_check(
		"a command before auth does not execute",
		refused.size() >= 1
			and not refused[0].contains("hostname:")
			and refused[0].contains("failed")
	)

	ws.close()

	await _test_rcon_websocket_commands(port)

func _test_rcon_websocket_commands(port: int) -> void:
	# 3. The real password, on a fresh socket: the failures above must not have
	#    left this address locked out at the default threshold.
	var good := await _ws_connect(port)
	_check("a second browser client can connect", good != null)
	if good == null:
		return

	good.send_text(server.config.rcon_password)
	var authed := await _ws_read(good, 1)
	_check(
		"the right password authenticates",
		authed.size() >= 1 and authed[0].contains("Authenticated")
	)

	# 4. A command runs, as root, and comes back as text.
	good.send_text("status")
	var status := await _ws_read(good, 1)
	_check(
		"an authenticated command executes",
		status.size() >= 1 and status[0].contains("hostname:")
	)

	# 5. A command whose output is empty still has to answer. A panel that gets
	#    nothing back cannot tell "no output" from "the socket is dead", and
	#    plenty of console commands reply with nothing on success.
	good.send_text("echo")
	var empty := await _ws_read(good, 1, 90)
	_check("a command with no output still answers", empty.size() >= 1)

	# 6. Long output has to survive the same splitter the TCP path uses. Over a
	#    WebSocket the framing is the socket's own, so the text must arrive whole
	#    once the frames are concatenated.
	var expected_long := _run("selftest_long")
	good.send_text("selftest_long")
	var long_frames := await _ws_read(good, 2, 240)
	_check("long output arrives over websocket", long_frames.size() >= 1)
	_check(
		"long output reassembles to the same text",
		"".join(long_frames).strip_edges() == expected_long.strip_edges()
	)

	good.close()

	# 7. A plain HTTP request on the websocket port must be refused rather than
	#    served or left hanging: it is the same port an admin page is on.
	var plain := StreamPeerTCP.new()
	if plain.connect_to_host("127.0.0.1", port) == OK:
		for _i in 60:
			plain.poll()
			if plain.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				break
			await get_tree().process_frame
		plain.put_data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".to_utf8_buffer())
		var dropped := false
		for _i in 120:
			await get_tree().process_frame
			plain.poll()
			var st := plain.get_status()
			if st == StreamPeerTCP.STATUS_ERROR or st == StreamPeerTCP.STATUS_NONE:
				dropped = true
				break
		_check("a non-websocket request is refused", dropped)
		plain.disconnect_from_host()

	_check("no websocket client is left open", server.rcon.client_count() == 0)
	_done()
