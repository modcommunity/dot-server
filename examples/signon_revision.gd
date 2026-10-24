extends Node

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

const PORT := 27717

## How many checks a clean run makes. A section that aborts part-way stops adding checks,
## and the section counter cannot see that when the abort comes after the section
## announced itself — so the total is asserted too.
const CHECKS := 149

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0
var _failures: Array[String] = []

var _server: DotServer = null
var _link: DotClientLink = null
var _client_side: Node = null

# Captured through an Array: a GDScript lambda captures locals by value, so a flag set
# inside a signal handler stays false outside it and the suite reports a failure for a
# signal that fired perfectly.
var _spawned := [false]
var _refused := [""]


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
		await _test_the_profile_stage()

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


# --- 1. The two sides of the handshake ------------------------------------

## [b]This is the section that would have prevented the bug.[/b]
##
## Every `@rpc` on [DotServer] has a counterpart on [DotClientLink] and every one on
## [DotChatManager] has one on [DotClientChat] -- not because it is tidy, but because
## Godot compares the name sets and refuses the pair when they differ. The suite asserts
## the sets rather than the count, so a rename is caught as loudly as an addition and
## the failure names the method.
func _test_the_two_sides_agree() -> void:
	_section("the two sides of the handshake declare the same methods")

	var server_names := DotSignon.rpc_method_names([DotServer, DotChatManager])
	var client_names := DotSignon.rpc_method_names([DotClientLink, DotClientChat])

	# [b]The surface is frozen, and this is the check that holds it.[/b] Exactly the six
	# envelope names on each end, and none at all on the chat pair that used to carry
	# two of their own: a feature is a kind now, and a seventh method is the protocol
	# break the envelope exists to end.
	var frozen := PackedStringArray(DotSignon.ENVELOPE)
	_check(
		server_names == frozen,
		"the server declares exactly the six envelope rpcs",
		"it declares: %s -- add a kind to DotServer.envelope, not an @rpc" % ", ".join(server_names)
	)
	_check(
		client_names == frozen,
		"and so does the client",
		"it declares: %s" % ", ".join(client_names)
	)
	_check(
		DotSignon.rpc_method_names([DotChatManager, DotClientChat]).is_empty(),
		"and the chat nodes declare none: chat is two kinds now"
	)

	_check(
		not server_names.is_empty(),
		"the server side declares rpc methods (%d)" % server_names.size()
	)
	_check(
		not client_names.is_empty(),
		"the client side declares rpc methods (%d)" % client_names.size()
	)

	var only_server := _missing_from(server_names, client_names)
	var only_client := _missing_from(client_names, server_names)

	_check(
		only_server.is_empty(),
		"every server rpc has a client counterpart",
		"DotClientLink/DotClientChat are missing: %s" % ", ".join(only_server)
	)
	_check(
		only_client.is_empty(),
		"every client rpc has a server counterpart",
		"DotServer/DotChatManager are missing: %s" % ", ".join(only_client)
	)

	# The consequence, stated as the thing a deployment actually depends on.
	_check(
		DotSignon.revision([DotServer]) == DotSignon.revision([DotClientLink]),
		"so a client built from this tree can join a server built from it"
	)

	_done()


# --- 2. The revision itself ------------------------------------------------

func _test_the_revision_is_derived() -> void:
	_section("the revision is derived from the declaration, not written down")

	var rev := DotSignon.revision([DotServer, DotChatManager])

	_check(rev != "", "it is not empty (%s)" % rev)
	_check(
		rev.length() == DotSignon.REVISION_LENGTH,
		"and is %d characters" % DotSignon.REVISION_LENGTH
	)
	_check(
		rev == DotSignon.revision([DotChatManager, DotServer]),
		"the order the scripts are passed in does not change it",
		"two servers that loaded their scripts in different orders would disagree"
	)

	# [b]An empty answer must not be a hash.[/b] A build that cannot read the rpc
	# config -- an engine without `get_rpc_config` -- has to say so, because a hash of
	# nothing is a specific twelve characters that every other build would read as a
	# real revision and refuse.
	_check(
		DotSignon.revision([]) == "",
		"a side that cannot answer reports nothing rather than a hash of nothing"
	)

	# Empty on EITHER side is not a mismatch: a server older than this class sends no
	# revision, and refusing it would break every client against every server deployed
	# before this landed -- which is the failure this whole thing exists to prevent,
	# arrived at from the other direction.
	_check(DotSignon.compatible(rev, ""), "an older server is not refused")
	_check(DotSignon.compatible("", rev), "and neither is an older client")
	_check(DotSignon.compatible(rev, rev), "the same revision is compatible")
	_check(
		not DotSignon.compatible(rev, "0123456789ab"),
		"a different one is not"
	)

	var err := DotSignon.explain(rev, "0123456789ab")
	_check(
		err.code == DotError.CODE_UNSUPPORTED,
		"and explaining it gives CODE_UNSUPPORTED rather than a network error",
		"a player told 'connection failed' will retry for ever"
	)
	_check(
		err.detail.contains(rev) and err.detail.contains("0123456789ab"),
		"naming both revisions, because the next question is always which"
	)

	_done()


# --- 3. A real join --------------------------------------------------------

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


func _test_a_real_join_carries_it() -> bool:
	_section("a real join carries the revision")

	_link = DotClientLink.new()
	# "Server", the same as DotServer. The name is the routing.
	_link.name = "Server"
	_link.player_name = "Joiner"
	_client_side.add_child(_link)

	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _refused[0] = reason)

	var connecting: DotResult = await _link.connect_to_server("127.0.0.1:%d" % PORT)

	if not _check(connecting.ok, "the client connects", str(connecting.error)):
		_done()
		return false

	var admitted := await _until(
		func() -> bool: return _spawned[0] or _refused[0] != ""
	)

	if not _check(admitted, "and finishes signon", "refused: %s" % _refused[0]):
		_done()
		return false

	# The round trip is known within a second of joining, not after the first two-second
	# heartbeat: every game's clock takes its input lead from it (DotClientLink._enter_playing).
	var joined_ms := Time.get_ticks_msec()
	var measured := await _until(func() -> bool: return _link.ping_ms() >= 0, 1.0)
	_check(measured, "the client knows its round trip within a second of joining (%d ms after)" % (Time.get_ticks_msec() - joined_ms))
	_check(_link.rtt_ms() > 0.0 or _link.ping_ms() == 0, "and rtt_ms() answers (%.1f ms)" % _link.rtt_ms())

	# A dual-stack server and a native client: the join is over UDP unless told otherwise.
	_check(
		_link.transport_used == "enet" and _server.peer_transport(_first_peer()) == "enet",
		"over ENet, which a native client tries first (%s)" % _link.transport_used
	)

	_check(
		_link.server_signon == DotSignon.revision([DotServer]),
		"and kept the server's revision (%s)" % _link.server_signon,
		"the challenge did not carry one, so no browser can read it either"
	)
	_check(
		_link.envelope.knows_peer(1) and _server.envelope.knows_peer(_first_peer()),
		"and each end has the other's kinds",
		"the adverts did not ride the challenge and the credentials"
	)
	_check(
		_link.server_addons.size() == 1
			and str((_link.server_addons[0] as Dictionary).get("id", "")) == "modcommunity/dot-ui"
			and str((_link.server_addons[0] as Dictionary).get("version", "")) == "9.9.9",
		"and the addon versions the server runs rode the challenge",
		str(_link.server_addons)
	)

	# Nothing to announce is nothing on the wire: the next joins read an empty list.
	_server.addon_set = []

	_done()
	return true


# --- 3b. A notice ----------------------------------------------------------

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


# --- 3b. The scoreboard ----------------------------------------------------

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


# --- 3d. Replicated cvars --------------------------------------------------

## [b]FLAG_REPLICATED meant nothing on the wire until this.[/b] A game rule a client predicts
## under (dot-combat's mp_teammate_passthrough) is a replicated cvar, and a client that never
## hears it predicts under its own default. The table rides before LOAD_GAME; a cvar a module
## registers later, and every change, arrives as a delta; a protected or plain cvar never does.
func _test_replicated_cvars_reach_the_client() -> void:
	_section("replicated cvars reach the client, live, and nothing else does")

	_check(_link.replicated_cvar("sv_cheats") == "0" and _link.replicated_cvar("sv_allow_web") == "1",
		"the join carried the server's replicated cvars (%s)" % str(_link.replicated_cvars))
	_check(not _link.replicated_cvars.has("hostname") and not _link.replicated_cvars.has("sv_password"),
		"and no cvar without the flag, protected or not")

	var heard: Array = []
	_link.replicated_cvar_changed.connect(func(n: String, v: String) -> void: heard.append([n, v]))

	var rule := _server.console.cvar("mp_signon_test_rule", "1", "a game rule a client predicts under",
		DotConVar.FLAG_REPLICATED | DotConVar.FLAG_NOTIFY)
	var secret := _server.console.cvar("mp_signon_test_secret", "hunter2", "replicated but protected",
		DotConVar.FLAG_REPLICATED | DotConVar.FLAG_PROTECTED)
	var plain := _server.console.cvar("mp_signon_test_plain", "5", "a server-only knob")

	_check(await _until(func() -> bool: return _link.replicated_cvar("mp_signon_test_rule") == "1", 5.0),
		"a replicated cvar a module registers mid-game reaches a playing client")

	var _set := rule.set_value("2")
	_check(await _until(func() -> bool: return _link.replicated_cvar("mp_signon_test_rule") == "2", 5.0),
		"and so does its change")
	_check(heard.has(["mp_signon_test_rule", "2"]), "announced by name and value (%s)" % str(heard))

	var _s2 := secret.set_value("swordfish")
	var _s3 := plain.set_value("6")
	var _s4 := rule.set_value("0")
	await _until(func() -> bool: return _link.replicated_cvar("mp_signon_test_rule") == "0", 5.0)
	_check(not _link.replicated_cvars.has("mp_signon_test_secret") and not _link.replicated_cvars.has("mp_signon_test_plain"),
		"a protected one and a plain one never arrive, registered or changed")

	var before := heard.size()
	_link._on_cvars(1, {"values": {"mp_signon_test_rule": "0"}, "full": false})
	_check(heard.size() == before, "a value that did not change is not announced again")
	_link._on_cvars(1, {"values": "not a table"})
	_link._on_cvars(1, {"values": {"x".repeat(200): "1", 7: "2"}})
	_check(_link.replicated_cvar("mp_signon_test_rule") == "0" and not _link.replicated_cvars.has("x".repeat(200)),
		"a malformed table, an oversized name and a non-string name change nothing")

	_server.console.unregister_cvar("mp_signon_test_rule")
	_server.console.unregister_cvar("mp_signon_test_secret")
	_server.console.unregister_cvar("mp_signon_test_plain")
	_done()


# --- 4. The mismatch -------------------------------------------------------

## [b]Driven through the challenge handler directly, and that is the only way to reach
## it.[/b] Producing a REAL mismatch would mean two builds of this addon in one process
## -- two scripts declaring different rpc sets under the same class names -- which
## GDScript cannot express. What can be exercised is the half that matters: a challenge
## carrying a revision this build does not match must be refused immediately, with an
## error that says what it is, rather than being answered and then falling silent.
func _test_a_mismatch_is_refused_at_once() -> void:
	_section("a client that cannot match the server is told so at once")

	_refused[0] = ""

	_link._on_challenge(1, {
		"protocol": DotSignon.PROTOCOL,
		"hostname": "Somewhere Else",
		"server_id": "",
		"needs_password": false,
		"auth": "none",
		"signon": "0123456789ab",
	})

	_check(
		_link.phase == DotClientLink.Phase.FAILED,
		"the client fails rather than answering",
		"phase is %s" % DotClientLink.phase_name(_link.phase)
	)
	_check(
		_link.last_error != null
			and _link.last_error.code == DotError.CODE_UNSUPPORTED,
		"with CODE_UNSUPPORTED",
		"got %s" % (str(_link.last_error) if _link.last_error != null else "nothing")
	)
	_check(
		_refused[0] != "",
		"and it disconnects rather than sitting on a socket that cannot work",
		"a client left connected is a slot the server holds until it times out"
	)
	# [b]The refusal must not throw away what it refused.[/b] A shell telling its page
	# "this server wants build X" reads `server_signon` off the link after the
	# disconnect, and this was assigned past the early return -- so the one case it
	# exists for was the one case it was empty.
	_check(
		_link.server_signon == "0123456789ab",
		"and it kept the revision the server asked for (%s)" % _link.server_signon,
		"a page cannot offer the right build if the client discarded its name"
	)

	# The one change names cannot express: the same revision, a different PROTOCOL.
	var protocol_link := DotClientLink.new()
	add_child(protocol_link)
	protocol_link._on_challenge(1, {
		"protocol": DotSignon.PROTOCOL + 1,
		"hostname": "Elsewhere",
		"signon": DotSignon.revision([DotClientLink]),
	})
	_check(
		protocol_link.phase == DotClientLink.Phase.FAILED
			and protocol_link.last_error != null
			and protocol_link.last_error.code == DotError.CODE_UNSUPPORTED,
		"a server on another signon protocol is refused the same way"
	)
	protocol_link.queue_free()

	_done()


# --- 5. Two builds that know different kinds -------------------------------

## [b]An older client meets a newer server.[/b] The client has never heard of notices or
## chat lines -- an older build that predates them -- and the server has a kind of its own
## the client has never heard of. The join must complete, the server must not send what the
## client does not know, and what arrives anyway must be dropped rather than break
## anything.
func _test_an_older_client_on_a_newer_server() -> void:
	_section("an older client joins a newer server")

	_server.envelope.register(&"skew.server_news")

	var old := _new_link("OldClient", func(link: DotClientLink) -> void:
		link.envelope.unregister(DotEnvelope.NOTICE)
		link.envelope.unregister(DotEnvelope.CHAT_LINE)
		link.envelope.unregister(DotEnvelope.CVARS)
	)

	var joined := await _join(old)
	if not _check(joined == "", "it joins and plays", joined):
		_server.envelope.unregister(&"skew.server_news")
		_done()
		return

	_check(old.server_addons.is_empty(), "a server announcing no addons sends no list", str(old.server_addons))

	var peer := _peer_of("OldClient")
	var session: DotClientSession = _server.session_of(peer)

	_check(
		not _server.envelope.peer_knows(peer, DotEnvelope.NOTICE),
		"the server knows this client has no notices"
	)
	var skipped := _server.envelope.skipped_sends
	_check(
		not _server.send_notice(session, DotNotice.make(&"cue", "not for you")),
		"so a notice to it is not sent"
	)
	_check(
		not _server.send_kind(peer, &"skew.server_news", {"x": 1}, DotEnvelope.Lane.EVENT),
		"and nor is the newer server's own kind"
	)
	_check(
		_server.envelope.skipped_sends == skipped + 2,
		"and both are counted as not sent (%d)" % (_server.envelope.skipped_sends - skipped)
	)
	_check(
		old.replicated_cvars.is_empty() and not _server._send_replicated_cvars(session),
		"a client without the cvars kind is sent no table and keeps its own defaults"
	)

	# Put an unknown kind on the wire anyway, as a server that did not filter would.
	var dropped := old.envelope.dropped_arrivals
	_server._dot_down_event.rpc_id(peer, "skew.server_news", {"x": 1})
	_server._dot_down.rpc_id(peer, String(DotEnvelope.NOTICE), {"cue": "raw"})
	var ignored := await _until(func() -> bool: return old.envelope.dropped_arrivals >= dropped + 2, 5.0)
	_check(ignored, "what it has never heard of is dropped on arrival (%d)" % (old.envelope.dropped_arrivals - dropped))

	# And it is still in the game: its heartbeat still reaches the server.
	old._send_heartbeat()
	var alive := await _until(func() -> bool: return old.ping_ms() >= 0, 5.0)
	_check(alive and old.is_playing(), "and it goes on playing (ping %d ms)" % old.ping_ms())
	# net_stat's source: the link's peer is metered, and the heartbeat fed it.
	var meter := old.net_meter()
	_check(meter != null and meter.bytes_in > 0 and meter.bytes_out > 0 and meter.rtt_ms >= 0.0,
		"its connection is metered, and the heartbeat gave the meter its ping (%s)" % [meter.describe() if meter != null else "no meter"])
	_check(meter != null and int(meter.remote.get("tick", 0)) > 0 and meter.remote.has("fps"),
		"and the server's own frame rate and tick came back with it (%s)" % [meter.remote if meter != null else {}])
	_check(
		session != null and session.is_playing(),
		"without the server having dropped it"
	)

	_drop_link(old)
	_server.envelope.unregister(&"skew.server_news")
	_done()


## [b]A newer client meets an older server.[/b] The client has a kind of its own the server
## has never heard of, and sends it; the server has no notices (an older build). The join
## completes and the newer kind is ignored.
func _test_a_newer_client_on_an_older_server() -> void:
	_section("a newer client joins an older server")

	_server.envelope.unregister(DotEnvelope.NOTICE)

	var heard := [0]
	var newer := _new_link("NewClient", func(link: DotClientLink) -> void:
		link.envelope.register(&"skew.client_news")
		link.envelope.register(&"skew.server_only_reply", func(_p: int, _d: Dictionary) -> void: heard[0] += 1)
	)

	var joined := await _join(newer)
	if not _check(joined == "", "it joins and plays", joined):
		_server.envelope.register(DotEnvelope.NOTICE)
		_done()
		return

	_check(
		not newer.send_kind(&"skew.client_news", {"hello": true}),
		"the client does not send the server what it does not know"
	)

	var dropped := _server.envelope.dropped_arrivals
	newer._dot_up.rpc_id(1, "skew.client_news", {"hello": true})
	var ignored := await _until(func() -> bool: return _server.envelope.dropped_arrivals > dropped, 5.0)
	_check(ignored, "and one that arrives anyway is dropped by the server")

	var session: DotClientSession = _server.session_of(_peer_of("NewClient"))
	_check(
		session != null and session.is_playing(),
		"which goes on serving it"
	)
	_check(
		not newer.envelope.peer_knows(1, DotEnvelope.NOTICE),
		"and the client knows this server has no notices"
	)

	_drop_link(newer)
	_server.envelope.register(DotEnvelope.NOTICE)
	_done()


## [b]A newer client REQUIRES a kind the server does not have.[/b] Refused by the server in
## words, and quickly -- not left to the auth timeout.
func _test_a_required_kind_the_server_lacks() -> void:
	_section("a client that requires a kind this server lacks is refused in words")

	var strict := _new_link("StrictClient", func(link: DotClientLink) -> void:
		link.envelope.register(&"skew.vital", Callable(), true)
	)

	var started := Time.get_ticks_msec()
	var outcome := await _join(strict)
	var took := (Time.get_ticks_msec() - started) / 1000.0

	_check(outcome != "", "it does not join")
	_check(
		strict.phase == DotClientLink.Phase.FAILED,
		"its phase says it failed (%s)" % DotClientLink.phase_name(strict.phase)
	)
	_check(
		strict.last_error != null and strict.last_error.code == DotError.CODE_VERSION,
		"as a version problem, not a kick",
		str(strict.last_error)
	)
	_check(
		outcome == "This server is older than this game client and cannot host it.",
		"with a sentence a player can act on",
		outcome
	)
	_check(
		strict.last_error != null and strict.last_error.detail.contains("skew.vital"),
		"naming the kind where an operator reads it"
	)
	_check(took < 5.0, "in %.1f s, not an auth timeout" % took)

	_drop_link(strict)
	_done()


## [b]The server REQUIRES a kind an older client does not have.[/b]
func _test_a_required_kind_the_client_lacks() -> void:
	_section("a server that requires a kind this client lacks refuses it in words")

	_server.envelope.register(&"skew.must", Callable(), true)

	var older := _new_link("OlderClient", Callable())

	var started := Time.get_ticks_msec()
	var outcome := await _join(older)
	var took := (Time.get_ticks_msec() - started) / 1000.0

	_check(
		outcome == "This server needs a newer game client.",
		"refused with a sentence a player can act on",
		outcome
	)
	_check(
		older.last_error != null and older.last_error.code == DotError.CODE_VERSION
			and older.last_error.detail.contains("skew.must"),
		"as a version problem naming the kind",
		str(older.last_error)
	)
	_check(took < 5.0, "in %.1f s" % took)
	_check(
		_server.sessions().size() == _playing_before_refusals,
		"and the server holds no slot for it"
	)

	_drop_link(older)
	_server.envelope.unregister(&"skew.must")
	_done()


# --- 9. A secret over UDP --------------------------------------------------

## An access token is a bearer secret and ENet is cleartext: a server whose sign-in
## wants one gets it over WebSocket, and the UDP connection carries nothing at all.
func _test_a_secret_never_rides_udp() -> void:
	_section("a sign-in that sends a secret never sends it over UDP")

	var seen: Array[Dictionary] = []
	var server_auth := _AuthStandIn.new()
	server_auth.on_authenticate = func(credential: Dictionary) -> void:
		var counts: Dictionary = _server.multiplayer.multiplayer_peer.call("peer_counts")
		seen.append({"token": credential.get("access_token", ""), "enet": counts["enet"]})
	var client_auth := _TokenStandIn.new()
	DotRegistry.register(&"dot_auth_server", server_auth)
	DotRegistry.register(&"dot_auth_client", client_auth)

	var link := _new_link("Secretive", Callable())
	await _join(link)
	await _until(func() -> bool: return not seen.is_empty(), 5.0)

	_check(link.transport_used == "websocket", "the client rejoined over WebSocket (%s)" % link.transport_used)
	var over_udp := seen.filter(func(c: Dictionary) -> bool: return c["enet"] > 0)
	var with_join := seen.filter(func(c: Dictionary) -> bool: return c["token"] == _TokenStandIn.JOIN)
	var with_secret := seen.filter(func(c: Dictionary) -> bool: return c["token"] == _TokenStandIn.SECRET)
	_check(over_udp.is_empty(), "no credentials at all arrived while it was on ENet (%d)" % over_udp.size())
	_check(with_join.size() == 1, "and a join token arrived once, over WebSocket")
	_check(with_secret.is_empty(), "and the account's access token never arrived at all")
	_check(
		client_auth.minted_for == [_AuthStandIn.AUDIENCE],
		"minted for the audience the server announced", str(client_auth.minted_for)
	)

	DotRegistry.unregister_instance(&"dot_auth_server", server_auth)
	DotRegistry.unregister_instance(&"dot_auth_client", client_auth)
	_drop_link(link)
	_done()


## [b]An INTROSPECT server the client does not list as first-party gets nothing.[/b]
## No join token is minted for it, no access token is sent, and with no ticket issuer
## the join fails in words rather than leaking the account's credential.
func _test_introspect_refuses_a_server_not_ours() -> void:
	_section("an introspect server not on the first-party list never gets a token")

	var seen: Array[Dictionary] = []
	var server_auth := _AuthStandIn.new()
	server_auth.audience = "server:999"
	server_auth.on_authenticate = func(credential: Dictionary) -> void:
		seen.append(credential.duplicate())
	var client_auth := _TokenStandIn.new()
	DotRegistry.register(&"dot_auth_server", server_auth)
	DotRegistry.register(&"dot_auth_client", client_auth)

	var link := _new_link("Stranger", func(l: DotClientLink) -> void:
		l.transport_preference = "ws")
	var outcome := await _join(link)

	_check(
		link.last_error != null and link.last_error.code == DotError.CODE_FORBIDDEN,
		"the join failed as forbidden", str(link.last_error)
	)
	_check(outcome != "", "with a sentence for the player", outcome)
	_check(seen.is_empty(), "and the server received no credentials (%d)" % seen.size())
	_check(client_auth.minted_for.is_empty(), "and no join token was minted")

	DotRegistry.unregister_instance(&"dot_auth_server", server_auth)
	DotRegistry.unregister_instance(&"dot_auth_client", client_auth)
	_drop_link(link)
	_done()


## A ticket server: the client must ask for its ticket by the address it dialled,
## never by an id the server announced (a hostile server would name a victim's).
## Armed by asking by [code]server_id[/code]: the address check fails.
func _test_a_ticket_is_asked_for_by_the_dialled_address() -> void:
	_section("a ticket is asked for by the address the client dialled")

	var seen: Array[Dictionary] = []
	var server_auth := _AuthStandIn.new()
	server_auth.strategy = "ticket"
	server_auth.on_authenticate = func(credential: Dictionary) -> void:
		seen.append(credential.duplicate())
	var client_auth := _TicketStandIn.new()
	DotRegistry.register(&"dot_auth_server", server_auth)
	DotRegistry.register(&"dot_auth_client", client_auth)

	var link := _new_link("Ticketed", func(l: DotClientLink) -> void:
		l.transport_preference = "ws")
	await _join(link)

	_check(client_auth.addresses == ["127.0.0.1:%d" % PORT],
		"the ticket was asked for by the dialled address", str(client_auth.addresses))
	_check(client_auth.ids.is_empty(), "never by an id the server announced", str(client_auth.ids))
	_check(seen.size() == 1 and str(seen[0].get("ticket", "")) == _TicketStandIn.TICKET
			and str(seen[0].get("access_token", "")) == "",
		"and the server got the ticket and no token", str(seen))
	_check(client_auth.nonces.size() == 1 and client_auth.nonces[0].length() >= 16,
		"the ticket was bound to the challenge's nonce", str(client_auth.nonces))
	_check(server_auth.nonces == client_auth.nonces and not seen.is_empty()
			and not seen[0].has("ticket_nonce"),
		"and the server checked it against its own copy, not the client's", str(server_auth.nonces))

	DotRegistry.unregister_instance(&"dot_auth_server", server_auth)
	DotRegistry.unregister_instance(&"dot_auth_client", client_auth)
	_drop_link(link)
	_done()


## dot-auth's client half for tickets: records what it was asked by.
class _TicketStandIn extends RefCounted:
	const TICKET := "ticket-for-the-test"
	var addresses: Array[String] = []
	var ids: Array[String] = []
	var nonces: Array[String] = []

	func request_ticket_for_address(address: String, _issuer := "", nonce := "") -> DotResult:
		addresses.append(address)
		nonces.append(nonce)
		return DotResult.success(TICKET)

	func request_ticket(_issuer: String, server_id: String) -> DotResult:
		ids.append(server_id)
		return DotResult.success(TICKET)


## dot-auth's server half, as far as dot-server asks: a strategy and a verdict.
class _AuthStandIn extends RefCounted:
	const AUDIENCE := "server:7"
	var on_authenticate: Callable
	var audience: String = AUDIENCE
	var strategy: String = "introspect"
	var nonces: Array[String] = []

	func strategy_name() -> String:
		return strategy

	func join_audience() -> String:
		return audience

	func authenticate(credential: Dictionary, _address: String, connection_nonce := "") -> DotResult:
		nonces.append(connection_nonce)
		on_authenticate.call(credential)
		return DotResult.fail(DotError.CODE_AUTH, "stand-in refuses everybody")


## Lets everybody in as the same account, for `sv_single_seat`.
class _SameAccountStandIn extends RefCounted:
	func strategy_name() -> String:
		return "local"

	func authenticate(_credential: Dictionary, _address: String, _nonce := "") -> DotResult:
		return DotResult.success(_Account.new())


class _Account extends RefCounted:
	var uid := "tmc:the-same-account"
	var display_name := "Twin"
	var is_guest := false


## [b]One account, one seat:[/b] signing in again replaces the older connection, so a
## player whose old connection is still timing out comes straight back. Armed by
## `sv_single_seat 0`, under which both stay.
func _test_an_account_holds_one_seat() -> void:
	_section("an account signing in again replaces its older connection")

	var auth := _SameAccountStandIn.new()
	DotRegistry.register(&"dot_auth_server", auth)
	var same := func() -> int:
		return _server.sessions().filter(func(x: DotClientSession) -> bool:
			return x.is_active() and x.uid() == "tmc:the-same-account").size()

	var first := _new_link("TwinA", func(l: DotClientLink) -> void: l.transport_preference = "ws")
	var lost := [""]
	first.disconnected.connect(func(reason: String) -> void: lost[0] = reason)
	_check(await _join(first) == "", "the account joins")
	var second := _new_link("TwinB", func(l: DotClientLink) -> void: l.transport_preference = "ws")
	_check(await _join(second) == "", "and joins again from another connection")
	await _until(func() -> bool: return lost[0] != "", 3.0)
	_check(same.call() == 1, "leaving one seat (%d)" % same.call())
	_check(lost[0] != "", "and the older connection was told why", lost[0])

	_server.console.set_cvar("sv_single_seat", "0")
	var third := _new_link("TwinC", func(l: DotClientLink) -> void: l.transport_preference = "ws")
	_check(await _join(third) == "", "with sv_single_seat 0 a third joins")
	_check(same.call() == 2, "and both seats stay (%d)" % same.call())
	_server.console.set_cvar("sv_single_seat", "1")

	DotRegistry.unregister_instance(&"dot_auth_server", auth)
	_drop_link(first)
	_drop_link(second)
	_drop_link(third)
	await _settle(0.5)
	_done()


## dot-auth's client half: an access token it must never send, and a join token
## minted only for a first-party audience.
class _TokenStandIn extends RefCounted:
	const SECRET := "bearer-secret-for-the-test"
	const JOIN := "tmc_jt_join-token-for-the-test"
	var minted_for: Array[String] = []

	func valid_access_token() -> DotResult:
		return DotResult.success(SECRET)

	func is_first_party(audience: String) -> bool:
		return audience == _AuthStandIn.AUDIENCE

	func request_join_token(audience: String) -> DotResult:
		minted_for.append(audience)
		return DotResult.success(JOIN)


# --- Harness ---------------------------------------------------------------

var _links: Dictionary = {}
# --- 9. The PROFILE stage ---------------------------------------------------

## [b]A module can hold a player between authentication and content, and refuse them
## before anybody sees them.[/b] Before the stage, the only place a platform could decide
## about a player was off `client_state_changed`, after the spawn: a refusal was a kick of
## somebody already in the world, and admission drew everybody as a guest first.
##
## Over the real socket, because the claim being tested is about what a CLIENT sees: a
## held client hears nothing that moves it towards the game (it waits in its own
## AUTHENTICATING phase, which is also why a client built before the stage still joins),
## a client claiming to have loaded early does not appear, and a refused one reads the
## module's sentence and never spawned.
func _test_the_profile_stage() -> void:
	_section("a module holds a joining player in PROFILE, and may refuse them unseen")

	# A replay keeps `int(session.state)`, so the stage went on the end of the enum. The
	# numbers already in records must not have moved.
	_check(
		DotClientSession.State.CONNECTING == 0 and DotClientSession.State.AUTHENTICATING == 1
			and DotClientSession.State.DOWNLOADING == 2 and DotClientSession.State.LOADING == 3
			and DotClientSession.State.SPAWNED == 4 and DotClientSession.State.REJECTED == 5
			and DotClientSession.State.DISCONNECTED == 6 and DotClientSession.State.PROFILE == 7,
		"no stage a record already holds was renumbered"
	)

	# Each joiner's states as the server announced them, and who the server spawned.
	var trails: Dictionary = {}
	var spawned_names: Array[String] = []
	var holder := func(session: DotClientSession) -> void:
		if not trails.has(session.display_name):
			trails[session.display_name] = []
		(trails[session.display_name] as Array).append(session.state_name())
		if session.state == DotClientSession.State.PROFILE and session.display_name.begins_with("Held"):
			_server.hold_profile(session, "test")
	var on_spawn := func(session: DotClientSession) -> void:
		spawned_names.append(session.display_name)
	_server.client_state_changed.connect(holder)
	_server.client_spawned.connect(on_spawn)

	# Nobody holds an ordinary player: the stage costs them nothing.
	var passer := _new_link("Passer", Callable())
	var passed := await _join(passer)
	_check(passed == "", "with nobody holding, a player passes straight through", passed)
	var trail: Array = trails.get("Passer", [])
	_check(
		trail.find("PROFILE") >= 0 and trail.find("PROFILE") < trail.find("LOADING"),
		"and did pass through it, before content (%s)" % ", ".join(trail)
	)
	var passer_session := _server.session_of(_peer_of("Passer"))
	_check(
		passer_session != null and not _server.hold_profile(passer_session, "test")
			and passer_session.profile_holds.is_empty(),
		"a player already past the stage cannot be held"
	)

	# Held: in the stage, and nothing moves it on.
	var held := _new_link("HeldA", Callable())
	var _connecting: DotResult = await held.connect_to_server("127.0.0.1:%d" % PORT)
	var reached := await _until(func() -> bool:
		var s := _server.session_of(_peer_of("HeldA"))
		return s != null and s.state == DotClientSession.State.PROFILE, 5.0)
	var held_session := _server.session_of(_peer_of("HeldA"))
	_check(
		reached and held_session != null and held_session.profile_holds == PackedStringArray(["test"]),
		"a module's hold keeps the player in PROFILE, naming who holds it",
		held_session.state_name() if held_session != null else "no session"
	)
	await _settle(0.75)
	var held_outcome: Array = _outcomes["HeldA"]
	_check(
		held_session.state == DotClientSession.State.PROFILE and not held_outcome[0]
			and not spawned_names.has("HeldA"),
		"and it stays there: no content, no load, no spawn on either end"
	)
	_check(
		held.phase == DotClientLink.Phase.AUTHENTICATING,
		"the client waits in its own signing-in phase, as a client older than the stage would (%s)" % DotClientLink.phase_name(held.phase)
	)

	# A client that claims to have loaded without being sent a game must not appear.
	held.send_kind(DotEnvelope.LOADED, {})
	await _settle(0.3)
	_check(
		held_session.state == DotClientSession.State.PROFILE and not spawned_names.has("HeldA"),
		"a held client that says it has loaded is not spawned"
	)

	_server.release_profile(held_session, "test")
	var released := await _until(func() -> bool: return held_outcome[0] and spawned_names.has("HeldA"), 5.0)
	_check(released and held_session.state == DotClientSession.State.SPAWNED,
		"the last release sends the player on, and they spawn")
	_check(held_session.profile_holds.is_empty(), "with no hold left on the session")
	trail = trails.get("HeldA", [])
	_check(
		trail.find("PROFILE") >= 0 and trail.find("PROFILE") < trail.find("SPAWNED"),
		"through PROFILE, then content (%s)" % ", ".join(trail)
	)

	# Refused while held: told why, and never in the game.
	var refused := _new_link("HeldB", Callable())
	_connecting = await refused.connect_to_server("127.0.0.1:%d" % PORT)
	await _until(func() -> bool:
		var s := _server.session_of(_peer_of("HeldB"))
		return s != null and s.state == DotClientSession.State.PROFILE, 5.0)
	var refused_session := _server.session_of(_peer_of("HeldB"))
	_check(
		refused_session != null and _server.refuse_profile(refused_session, "Make an avatar first."),
		"a module can refuse a player it holds"
	)
	var refused_outcome: Array = _outcomes["HeldB"]
	var heard := await _until(func() -> bool: return refused_outcome[1] != "", 5.0)
	_check(heard and refused_outcome[1] == "Make an avatar first.",
		"and the client reads the module's own sentence", str(refused_outcome[1]))
	_check(
		not refused_outcome[0] and not spawned_names.has("HeldB") and _peer_of("HeldB") == 0
			and refused_session.state == DotClientSession.State.REJECTED,
		"and was never spawned, and the server has no session for them"
	)
	_check(
		passer_session != null and not _server.refuse_profile(passer_session, "too late"),
		"a player past the stage cannot be refused in it; that would be a kick"
	)

	# A hold nobody releases costs the player their join, never the server a slot.
	var budget := _server.config.profile_timeout_sec
	_server.config.profile_timeout_sec = 0.5
	var stuck := _new_link("HeldC", Callable())
	_connecting = await stuck.connect_to_server("127.0.0.1:%d" % PORT)
	var stuck_outcome: Array = _outcomes["HeldC"]
	var dropped := await _until(func() -> bool: return stuck_outcome[1] != "", 5.0)
	_server.config.profile_timeout_sec = budget
	_check(
		dropped and str(stuck_outcome[1]).contains("setting up a profile"),
		"a hold never released times out on the stage's own budget, in words",
		str(stuck_outcome[1])
	)
	_check(not spawned_names.has("HeldC") and _peer_of("HeldC") == 0, "and that player never appeared either")

	_server.client_state_changed.disconnect(holder)
	_server.client_spawned.disconnect(on_spawn)
	for link in [passer, held, refused, stuck]:
		await _drop_link(link)
	_done()


var _outcomes: Dictionary = {}
var _playing_before_refusals: int = 0


## A client in a subtree of its own, with its own MultiplayerAPI: one socket per link, as
## one process per client would have. [param configure] edits its envelope before it
## connects -- that is how it stands in for an older or a newer build.
func _new_link(label: String, configure: Callable) -> DotClientLink:
	var root := Node.new()
	root.name = label
	add_child(root)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), root.get_path())

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = label
	root.add_child(link)

	if configure.is_valid():
		configure.call(link)

	_links[label] = link
	_outcomes[label] = [false, ""]
	var outcome: Array = _outcomes[label]
	link.spawned.connect(func() -> void: outcome[0] = true)
	link.disconnected.connect(func(reason: String) -> void: outcome[1] = reason)
	return link


## Connects and waits for either end of the join. "" when it spawned; the reason when not.
func _join(link: DotClientLink) -> String:
	var outcome: Array = _outcomes[link.player_name]
	_playing_before_refusals = _server.sessions().size()
	var connecting: DotResult = await link.connect_to_server("127.0.0.1:%d" % PORT)
	if not connecting.ok:
		return "could not connect: %s" % str(connecting.error)
	var ended := await _until(func() -> bool: return outcome[0] or outcome[1] != "", 8.0)
	if not ended:
		return "timed out in %s" % DotClientLink.phase_name(link.phase)
	if outcome[0]:
		# The client's `spawned` is not the server's; wait for the server to agree.
		await _until(func() -> bool: return _server.playing_sessions().size() > _playing_before_refusals - 1, 3.0)
		return ""
	return str(outcome[1])


func _peer_of(label: String) -> int:
	for session in _server.sessions():
		if session.display_name == label:
			return session.peer_id
	return 0


func _first_peer() -> int:
	for session in _server.sessions():
		return session.peer_id
	return 0


func _drop_link(link: DotClientLink) -> void:
	if link == null:
		return
	link.disconnect_from_server()
	var root := link.get_parent()
	if root != null:
		root.queue_free()
	await get_tree().process_frame

func _missing_from(these: PackedStringArray, those: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for name in these:
		if not those.has(name):
			out.append(name)
	return out


## Stands in for the dot-cloud client's warm_content.
class FakeCloud extends Node:
	var hang := false

	func warm_content(_tree: SceneTree, _keys: PackedStringArray, _force: bool = false, on_progress: Callable = Callable()) -> RefCounted:
		if on_progress.is_valid():
			on_progress.call(1, 2)
			on_progress.call(2, 2)
		if hang:
			await get_tree().create_timer(3600.0).timeout
		return RefCounted.new()


## The warm feeds the loading bar, and a cloud freed mid-warm must not leave the join in
## LOADING: the link falls back to a plain load().
func _test_the_warm_feeds_progress_and_survives_the_cloud() -> void:
	_section("The content warm: progress reaches the bar, and a freed cloud does not strand the join")

	var dir := "res://dot_cloud/_warmtest/0.0.0"
	DirAccess.make_dir_recursive_absolute(dir)
	var scene := PackedScene.new()
	var node := Node.new()
	scene.pack(node)
	node.free()
	ResourceSaver.save(scene, dir + "/s.tscn")
	var info := {"scene": "s.tscn", "content_key": "_warmtest@0.0.0"}

	var cloud := FakeCloud.new()
	add_child(cloud)
	DotRegistry.register(&"dot_cloud_client", cloud)

	var link := DotClientLink.new()
	add_child(link)
	var seen: Array = []
	link.download_progress.connect(func(fraction: float, _text: String) -> void: seen.append(fraction))
	link._on_load_game(0, info)
	await _until(func() -> bool: return link.get("_scene_instance") != null, 5.0)
	_check(seen.has(0.5) and seen.has(1.0), "warm progress reaches download_progress", str(seen))
	_check(link.get("_scene_instance") != null, "and the scene loads after the warm")
	link.queue_free()

	cloud.hang = true
	var link2 := DotClientLink.new()
	add_child(link2)
	link2._on_load_game(0, info)
	for i in 8:
		await get_tree().process_frame
	cloud.free()
	var loaded := await _until(func() -> bool: return link2.get("_scene_instance") != null, 3.0)
	_check(loaded, "a cloud freed mid-warm falls back to a plain load() of the scene")
	_check(link2.phase != DotClientLink.Phase.LOADING or loaded, "and the join is not left in LOADING")
	link2.queue_free()

	DotRegistry.unregister(&"dot_cloud_client")
	DirAccess.remove_absolute(dir + "/s.tscn")
	DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute("res://dot_cloud/_warmtest")
	_done()


func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(ok: bool, label: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s%s" % [label, "" if detail == "" else "  -- " + detail])
		_failures.append(label)
	return ok


func _until(predicate: Callable, seconds: float = 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	return false


## Lets [param seconds] pass with the network polled every frame — a wait for something to
## NOT happen, which `_until` cannot express.
func _settle(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


func _teardown() -> void:
	for label in _links:
		var l: Variant = _links[label]
		if is_instance_valid(l):
			(l as DotClientLink).disconnect_from_server()
	if _link != null:
		_link.disconnect_from_server()
	if _server != null:
		_server.shutdown("test over")
