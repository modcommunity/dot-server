extends "res://examples/selftest/signon_revision_tests_a.gd"

## The check nobody could make: whether this client and this server can finish a join.
##
## [b]The bug this suite exists for has been hit, diagnosed by hand, and written up in
## a comment, and nothing could see it.[/b] Godot refuses an RPC unless both ends
## declare the same set of [code]@rpc[/code] methods on the node. Add one to
## [DotServer] and forget [DotClientLink] and every shipped client stops being able to
## join, with this and nothing else:
##
## [codeblock]
## ERROR: The rpc node checksum failed. Make sure to have the same methods on both
##        nodes. Node path: /root/Server
## [/codeblock]
##
## The server then reports "timed out during join". Neither end says "version".
##
## The four sections here are, in the order they would have caught it:
##
##   1. The two sides of the handshake declare the SAME rpc method names. This is the
##      regression guard proper -- it fails on the commit that adds a method to one
##      side, rather than on the deployment that ships it.
##   2. [DotSignon] is derived from the same declaration the engine checksums, is
##      stable, and is not a hash of nothing.
##   3. A real join carries the revision, and the client keeps it.
##   4. A client meeting a server it cannot match fails with a sentence, immediately,
##      instead of waiting out a timeout that blames the network.
##
## And, since the RPCs became an envelope (see [DotEnvelope]): the surface is exactly the
## six names in [constant DotSignon.ENVELOPE], so adding a seventh fails here; and two
## builds that know different KINDS play together over a real socket -- an older client
## on a newer server, a newer client on an older server, each ignoring what it has never
## heard of -- while a kind one end REQUIRES and the other lacks refuses the join in words,
## in seconds, rather than as a timeout. "Older" is a link or a server with fewer kinds
## registered, which is exactly what an older build is.
##
## And one section for the pair that most recently changed the revision: a [DotNotice]
## sent over the same real socket arrives whole, on the node the join used. It is here
## rather than in `dedicated_server` because that suite has no client, and a message whose
## only failure mode is "the two ends disagree about the RPC set" is not tested by a suite
## that has one end.
##
## Run:
## [codeblock]
## godot --headless --path . res://examples/signon_revision.tscn
## [/codeblock]

func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()

func _run() -> void:
	print("dot-server: the signon revision, and what happens when it does not match")

	_test_the_two_sides_agree()
	_test_the_revision_is_derived()
	await _test_the_warm_feeds_progress_and_survives_the_cloud()

	if await _boot():
		if await _test_a_real_join_carries_it():
			await _test_a_notice_reaches_the_client()
			await _test_the_scoreboard_reaches_the_client()
			await _test_replicated_cvars_reach_the_client()
			_test_a_mismatch_is_refused_at_once()
		await _test_an_older_client_on_a_newer_server()
		await _test_a_newer_client_on_an_older_server()
		await _test_a_required_kind_the_server_lacks()
		await _test_a_required_kind_the_client_lacks()
		await _test_a_secret_never_rides_udp()
		await _test_introspect_refuses_a_server_not_ours()
		await _test_a_ticket_is_asked_for_by_the_dialled_address()
		await _test_an_account_holds_one_seat()
		await Profile.new(self).run()

	_teardown()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	_check(
		_passed + _failed + 1 == CHECKS,
		"and made every check it has (%d of %d)" % [_passed + _failed + 1, CHECKS],
		"a check that never ran is not a check that passed"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)

func _boot() -> bool:
	_section("a server boots")

	var config := DotServerConfig.new()
	config.hostname = "Signon Test"
	config.port = PORT
	config.max_players = 4
	config.a2s_enabled = false
	config.query_enabled = false
	config.hibernate_when_empty = false
	# The addon ships a server.cfg the search path would find, and this would then be
	# asserting against whatever that file contains.
	config.startup_config = ""
	config.autoexec_config = ""

	# [b]Each half gets its own MultiplayerAPI, scoped to its own subtree.[/b] Godot
	# addresses an RPC by the receiver's node path relative to its API root, so without
	# this the client answers every call with `Node not found` -- the handshake
	# included -- and the only symptom is a timeout, which is the failure this suite is
	# about wearing a different hat.
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), server_side.get_path()
	)
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _client_side.get_path()
	)

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)

	# What a host announces about its addons, so a client can fetch newer ones as packs.
	_server.addon_set = [{"dir": "dot_ui", "repo": "dot-ui", "id": "modcommunity/dot-ui", "version": "9.9.9"}]

	var booted := await _server.boot()

	if not _check(booted.ok, "it boots", str(booted.error)):
		_done()
		return false

	var game := DotGameDescriptor.new()
	game.game_id = "lobby"
	game.display_name = "Lobby"
	game.version = "1.0.0"
	game.scene = "res://examples/fixtures/lobby_world.tscn"
	_server.games.add_game(game)

	var loaded: DotResult = await _server.games.change_game("lobby")
	_check(loaded.ok, "and loads a game", str(loaded.error))

	_done()
	return true

## [b]The pair that changed the revision, driven over the socket the join used.[/b]
##
## What can go wrong here is exactly what section 1 exists for — `_notice` on one side and
## not the other — plus the one thing a dictionary on the wire adds: a field that goes out
## and does not come back, because the decoder and the encoder disagree about its name or
## its type. So every field is sent and every field is read back on the far side.
func _test_a_notice_reaches_the_client() -> void:
	_section("a notice reaches the client over the socket")

	var received: Array[DotNotice] = []
	var sent: Array[int] = []
	_link.notice_received.connect(func(n: DotNotice) -> void: received.append(n))
	_server.notice_sent.connect(func(_n: DotNotice, count: int) -> void: sent.append(count))

	# [b]The client's `spawned` is not the server's.[/b] The client announces it has
	# loaded and considers itself in; the server moves the session to SPAWNED when that
	# announcement arrives, a poll later. A broadcast in between reaches nobody, correctly
	# -- a notice goes to playing sessions -- and reads as a broken RPC.
	await _until(func() -> bool: return _server.playing_sessions().size() == 1, 5.0)

	var full := DotNotice.make(
		&"vote_warning", "A vote for the next game starts in", 10.0, &"game_vote"
	)
	var reached := _server.broadcast_notice(full)

	_check(reached == 1, "a broadcast reaches the one playing client (%d)" % reached)
	_check(
		sent.size() == 1 and sent[0] == 1,
		"and the server says so (%s)" % str(sent),
		"a host that mirrors notices into a log would hear nothing"
	)

	if not _check(
		await _until(func() -> bool: return received.size() >= 1, 5.0),
		"the client hears it",
		"nothing arrived; if section 1 passed, the RPC is reaching a node without _notice"
	):
		_done()
		return

	var got: DotNotice = received[0]
	_check(got.cue == &"vote_warning", "with its cue (%s)" % got.cue)
	_check(
		got.text == "A vote for the next game starts in",
		"its text (%s)" % got.text
	)
	_check(is_equal_approx(got.seconds, 10.0), "its countdown (%s)" % got.seconds)
	_check(got.topic == &"game_vote", "and its topic (%s)" % got.topic)
	_check(_link.last_notice == got, "and the link keeps it for a HUD built afterwards")

	# The two shapes that are not "everything": a cue and nothing else, which must come
	# back with NO countdown rather than a countdown of zero -- a HUD told "0 seconds" draws
	# a line that has already run out -- and a clear, which is a topic and nothing else.
	var session: DotClientSession = _server.playing_sessions()[0]
	_check(
		_server.send_notice(session, DotNotice.make(&"vote_count")),
		"a cue alone can be sent to one session"
	)
	_check(
		_server.send_notice(session, DotNotice.clear(&"game_vote")),
		"and so can a clear"
	)

	var both := await _until(func() -> bool: return received.size() >= 3, 5.0)

	if _check(both, "both arrive (%d notices)" % received.size()):
		var bare := received[1]
		_check(
			bare.cue == &"vote_count" and not bare.has_countdown() and bare.text == "",
			"a bare cue has no countdown and no line (%s)" % str(bare.describe())
		)
		_check(
			received[2].is_clear() and received[2].topic == &"game_vote",
			"a clear arrives as a clear of its topic (%s)" % str(received[2].describe())
		)

	# Structured content rides the same dictionary, which is why it changes no revision: a
	# ballot goes out with its options and its voters and comes back whole.
	var ballot := {"open": true, "options": [{"id": "a", "label": "Alpha", "votes": 1.0}], "voters": {"u1": 0}}
	_check(
		_server.send_notice(session, DotNotice.make(&"", "", 20.0, &"game_ballot", ballot)),
		"a notice can carry data"
	)
	var carried := await _until(func() -> bool: return received.size() >= 4, 5.0)

	if _check(carried, "and it arrives (%d notices)" % received.size()):
		var tree: Dictionary = received[3].data
		_check(
			tree.get("options", [{}])[0].get("label", "") == "Alpha"
				and int(tree.get("voters", {}).get("u1", -1)) == 0
				and not received[3].is_clear(),
			"with its tree intact, and not mistaken for a clear (%s)" % str(tree)
		)

	_check(
		DotNotice.make(&"", "", -1.0, &"x", {"bad": RefCounted.new()}).data.is_empty()
			and DotNotice.make(&"", "", -1.0, &"x", {"big": "x".repeat(DotNotice.MAX_DATA_BYTES)}).data.is_empty(),
		"data that is not plain, or too big, is dropped whole"
	)

	# Nothing on it is nothing sent: a HUD that has to decide what an empty notice means
	# is a HUD with a case nobody wrote.
	_check(
		_server.broadcast_notice(DotNotice.new()) == 0,
		"an empty notice is not sent at all"
	)

	_done()

## The roster a held scoreboard shows: the server's numbers, which no client has for anybody
## but itself, sent only while the board is held.
func _test_the_scoreboard_reaches_the_client() -> void:
	_section("a held scoreboard is sent the server's roster, and only while held")

	var got: Array[Dictionary] = []
	_link.scoreboard_received.connect(func(snap: Dictionary) -> void: got.append(snap))
	var session: DotClientSession = _server.playing_sessions()[0]
	# The ping is not planted: the client's early heartbeats report a real one within a
	# second of joining (DotClientLink._enter_playing), and the row has to match the session.
	session.score = 7
	_server.scoreboard_fields = func(s: DotClientSession) -> Dictionary: return {"team": 2, "kills": s.score * 2}
	_server.scoreboard_extra = func() -> Dictionary:
		return {"teams": [{"id": 2, "name": "Blue", "score": 3}], "players": "never over a core key"}
	_server.scoreboard_interval_sec = 0.2

	await _settle(0.5)
	_check(got.is_empty(), "nothing is sent to a client that is not holding its board")

	_check(_link.want_scoreboard(true), "the client says its board is open")
	if not _check(await _until(func() -> bool: return got.size() >= 1, 5.0), "and the roster arrives"):
		_done()
		return

	var snap: Dictionary = got[0]
	var server: Dictionary = snap.get("server", {})
	var rows: Array = snap.get("players", [])
	_check(str(server.get("name", "")) == _server.config.hostname and int(server.get("players", 0)) == 1
		and int(server.get("max", 0)) == _server.config.max_players,
		"with the server's name and its slots (%s)" % str(server))
	_check(rows.size() == 1 and int(snap.get("you", 0)) == session.userid, "one row, and which one is this client")
	var row: Dictionary = rows[0] if not rows.is_empty() else {}
	_check(str(row.get("name", "")) == session.display_name and int(row.get("score", -1)) == 7
		and int(row.get("ping", -1)) == session.ping_ms and int(row.get("seconds", -1)) >= 0,
		"the name, score, ping and time connected the session kept (%s)" % str(row))
	_check(int(row.get("team", 0)) == 2 and int(row.get("kills", 0)) == 14, "and the game's own columns")
	_check(snap.get("teams", []).size() == 1 and snap.get("players") is Array,
		"the game's extra keys ride beside the core ones and never replace one")
	_check(await _until(func() -> bool: return got.size() >= 3, 3.0), "it keeps coming while held (%d)" % got.size())

	_check(_link.want_scoreboard(false), "the board closes")
	await _settle(0.4)
	var after := got.size()
	await _settle(0.8)
	_check(got.size() == after, "and nothing more is sent (%d then %d)" % [after, got.size()])
	_check(_link.scoreboard == got[-1], "the link keeps the last one for a board drawn later")

	# Unreliable over ENet arrives in any order: a board older than the one held is dropped.
	var newest := int(_link.scoreboard.get("seq", 0))
	var stale := (_link.scoreboard as Dictionary).duplicate(true)
	stale["seq"] = newest - 1
	stale["you"] = -999
	var heard := got.size()
	_link._on_scoreboard(1, stale)
	_check(newest > 0 and int(_link.scoreboard.get("you", 0)) != -999 and got.size() == heard,
		"a board older than the one held is dropped, not shown (seq %d after %d)" % [newest - 1, newest])

	# The block list's two fields (dot-chat's `sm`): whose voice is whose, and a key that
	# outlives the session but means nothing on another server.
	var key := str(row.get("key", ""))
	_check(int(row.get("peer", 0)) == session.peer_id, "each row carries the player's peer, for voice")
	_check(key != "" and key == _server.player_key(session) and not key.contains(session.uid())
		and key != str(session.userid),
		"and a key that is neither the uid nor the userid (%s)" % key)
	var salt_path := _server.player_key_salt_path
	_server._player_key_salt = ""
	_check(_server.player_key(session) == key and FileAccess.file_exists(salt_path),
		"the key survives a restart: its salt is kept on disk")

	# One board on request, without holding it: nothing follows it, and a held board stays held.
	var before := got.size()
	_check(_link.request_scoreboard(), "a one-off board is asked for")
	_check(await _until(func() -> bool: return got.size() == before + 1, 3.0), "and exactly one arrives")
	await _settle(0.6)
	_check(got.size() == before + 1 and not session.wants_scoreboard,
		"and nothing after it: the board was never held (%d)" % (got.size() - before))
	var _held := _link.want_scoreboard(true)
	await _settle(0.3)
	var _once := _link.request_scoreboard()
	await _settle(0.3)
	_check(session.wants_scoreboard, "a one-off request leaves a held board held")
	var _closed := _link.want_scoreboard(false)
	await _settle(0.3)

	_server.scoreboard_fields = Callable()
	_server.scoreboard_extra = Callable()
	_done()
