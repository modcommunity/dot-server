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
const CHECKS := 40

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

	if await _boot():
		if await _test_a_real_join_carries_it():
			await _test_a_notice_reaches_the_client()
			_test_a_mismatch_is_refused_at_once()

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
		DotSignon.revision([DotServer, DotChatManager])
			== DotSignon.revision([DotClientLink, DotClientChat]),
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

	_check(
		_link.server_signon == DotSignon.revision([DotServer, DotChatManager]),
		"and kept the server's revision (%s)" % _link.server_signon,
		"the challenge did not carry one, so no browser can read it either"
	)

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

	# Nothing on it is nothing sent: a HUD that has to decide what an empty notice means
	# is a HUD with a case nobody wrote.
	_check(
		_server.broadcast_notice(DotNotice.new()) == 0,
		"an empty notice is not sent at all"
	)

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

	_link._request_credentials({
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

	_done()


# --- Harness ---------------------------------------------------------------

func _missing_from(these: PackedStringArray, those: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for name in these:
		if not those.has(name):
			out.append(name)
	return out


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


func _teardown() -> void:
	if _link != null:
		_link.disconnect_from_server()
	if _server != null:
		_server.shutdown("test over")
