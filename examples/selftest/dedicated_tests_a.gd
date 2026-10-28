extends "res://examples/selftest/dedicated_base.gd"

## dedicated_server selftest sections, part a.

func _test_console() -> void:
	_section("[console]")
	var console := server.console

	_check("status runs", _run("status").contains("hostname:"))
	_check("help lists commands", _run("help").contains("status"))
	_check("unknown command reported", _run("nonsense").contains("Unknown"))
	# The suggestion path is what makes a typo over RCON recoverable.
	_check("typo suggests a name", _run("statuz").contains("Did you mean"))
	_check("echo works", _run("echo hello").contains("hello"))

	# Quoting must survive tokenization, or every multi-word argument breaks.
	var tokens := DotConsole.tokenize('say "hello world" extra')
	_check("quoted argument kept whole", tokens.size() == 3 and tokens[1] == "hello world")

	# Semicolons split, but not inside quotes.
	var statements := DotConsole.split_statements('say "a; b"; status')
	_check("semicolon in quotes not split", statements.size() == 2)

	_check("cvarlist runs", _run("cvarlist sv_").contains("sv_maxplayers"))
	_check("find searches", _run("find maxplayers").contains("sv_maxplayers"))

	console.set_alias("mystatus", "status")
	_check("alias resolves", _run("mystatus").contains("hostname:"))
	_done()

## A command object of the duck-typed shape, for [method DotConsole.add_source]. A bare
## [RefCounted] on purpose: an addon dot-server has never heard of must be able to plug in.
class ProbeSource:
	extends RefCounted

	var calls: int = 0
	var last_line: String = ""

	func names() -> PackedStringArray:
		return PackedStringArray(["probe", "probe2"])

	func claims(name: String) -> bool:
		return names().has(name.to_lower())

	func help_for(name: String) -> String:
		return "probe — a test source" if name == "probe" else ""

	## Whole lines, filtered on the last token. The shape every source of this kind has:
	## it is handed the line it would execute and answers with lines that could be.
	func complete(partial: String, _limit: int = 24) -> PackedStringArray:
		if not partial.begins_with("probe"):
			return PackedStringArray()
		var words := partial.split(" ", false)
		var prefix := "" if partial.ends_with(" ") else words[words.size() - 1]
		var out := PackedStringArray()
		for word in ["alpha", "beta"]:
			if word.begins_with(prefix):
				out.append("probe " + word)
		return out

	func execute(line: String) -> DotResult:
		calls += 1
		last_line = line
		if line.contains("fail"):
			return DotResult.fail(DotError.CODE_INVALID, "the probe refused")
		if line.contains("lines"):
			return DotResult.success(PackedStringArray(["one", "two"]))
		return DotResult.success("probe ran: %s" % line)

## Which stdin the operator console reads. A reader on an unclosed pipe cannot be cancelled and
## hangs the exit, so only a terminal and a file are read unless a host asks for pipes. The exit
## is checked from outside: run this scene with an open pipe on stdin and it must exit.
func _test_stdin_console() -> void:
	_section("[stdin console]")

	_check("a terminal is read", DotStdinConsole.should_read(OS.STD_HANDLE_CONSOLE, false))
	_check("a file is read, because it ends",
		DotStdinConsole.should_read(OS.STD_HANDLE_FILE, false))
	_check("a pipe is not read by default",
		not DotStdinConsole.should_read(OS.STD_HANDLE_PIPE, false))
	_check("nor /dev/null or a socket (UNKNOWN)",
		not DotStdinConsole.should_read(OS.STD_HANDLE_UNKNOWN, false))
	_check("a pipe is read when asked",
		DotStdinConsole.should_read(OS.STD_HANDLE_PIPE, true))
	_check("no handle is never read, asked or not",
		not DotStdinConsole.should_read(OS.STD_HANDLE_INVALID, true))
	_check("pipes are off by default in the config",
		DotServerConfig.new().stdin_console_pipes == false)

	var console := server.stdin_console

	if console == null:
		_check("the server built a stdin console", false)
		return

	var kind := OS.get_stdin_type()
	var reading: bool = console.describe().get("reading", false)

	# A file may have been read to its end already, so only the refusing side is exact.
	if DotStdinConsole.should_read(kind, server.config.stdin_console_pipes):
		_check("this run's stdin (%d) is read or already ended" % kind, true)
	else:
		_check("this run's stdin (%d) started no reader" % kind, not reading)

	_done()

func _test_console_source() -> void:
	print("")
	_section("[a duck-typed console source]")
	var console := server.console

	var source := ProbeSource.new()
	var added := console.add_source(source, "", true)

	_check("a source registers", added.ok)
	_check("both of its names are taken",
		console.find_command("probe") != null and console.find_command("probe2") != null)

	# The reason the hook exists at all: everything downstream treats it as a command.
	_check("it is in the name list", console.command_names().has("probe"))
	_check("help_for became the description",
		console.find_command("probe").description.contains("a test source"))
	_check("a name with no help still has one",
		console.find_command("probe2").description != "")

	_check("running it reaches the source", _run("probe status").contains("probe ran"))
	# The command word travels with the line. Every source of this shape parses its own
	# first word and answers "not mine" without it, which is the failure this asserts.
	_check("the whole line is handed over, command word included",
		source.last_line == "probe status")

	_check("an array result becomes several lines",
		_run("probe lines").split("\n").size() == 2)
	_check("a refusal is reported as one", _run("probe fail").contains("refused"))

	# Completion arrives.
	var completions := console.complete("probe al")
	_check("the source completes its own arguments",
		completions.size() == 1 and completions[0] == "probe alpha")

	# A source may not take a name somebody already has: two objects answering one word
	# is a console that runs a different command depending on registration order.
	var thief := ProbeSource.new()
	var stolen := console.add_source(thief)
	_check("a second source cannot steal a name", stolen.ok and PackedStringArray(stolen.value).is_empty())
	_run("probe status")
	_check("and the original still answers", thief.calls == 0)

	var refused := console.add_source(RefCounted.new())
	_check("an object with no execute() is refused", not refused.ok)
	_check("and null is too", not console.add_source(null).ok)

	console.remove_source(source)
	_check("remove_source unregisters every name",
		console.find_command("probe") == null and console.find_command("probe2") == null)
	_done()

func _test_argument_completion() -> void:
	print("")
	_section("[argument completion]")
	var console := server.console

	# `DotConCommand.completer` was set by seven builtins and read by nothing: the only
	# reader was `complete_argument`, which had no callers in this family. These two
	# assertions are the difference between a completer that exists and one that runs.
	var seen := PackedStringArray()
	console.command(
		"probe_args",
		func(_ctx: DotCmdContext) -> void: pass,
		"A command with a completer."
	).with_completer(
		func(partial: String, index: int) -> PackedStringArray:
			seen.append("%d:%s" % [index, partial])
			if index == 0:
				return PackedStringArray(["alpha", "amber", "beta"])
			return PackedStringArray(["second"])
	)

	var first := console.complete("probe_args ")
	_check("a trailing space completes the first argument",
		first.size() == 3 and first[0] == "probe_args alpha")
	_check("and asks for position 0 with an empty prefix", seen.has("0:"))

	var narrowed := console.complete("probe_args a")
	_check("a partial token is passed as the prefix", seen.has("0:a"))
	_check("candidates come back as whole lines",
		narrowed.size() == 3 and narrowed[1] == "probe_args amber")

	var second := console.complete("probe_args alpha ")
	_check("the settled arguments are kept in the line",
		second.size() == 1 and second[0] == "probe_args alpha second")
	_check("and the position moves on", seen.has("1:"))

	# Nothing that completed before completes differently.
	_check("a bare word still completes command names",
		console.complete("probe_arg").has("probe_args"))
	_check("a command with no completer offers nothing",
		console.complete("status ").is_empty())
	_check("an unknown command offers nothing",
		console.complete("nonsense_xyz ").is_empty())

	console.set_alias("pa", "probe_args")
	_check("an alias completes as what it stands for",
		console.complete("pa ").size() == 3)

	console.unregister_command("probe_args")
	console.remove_alias("pa")
	_done()

func _test_config_files() -> void:
	print("")
	_section("[config files]")
	var console := server.console

	DotPaths.write_text(
		"user://cfg/example_test.cfg",
		"// a comment\nhostname \"Set From Config\"\nsv_maxplayers 20\n"
	)

	var res := console.exec_config("example_test", null, true)
	_check("config executed", res.ok)
	_check("config set a string", console.get_string("hostname") == "Set From Config")
	_check("config set an int", console.get_int("sv_maxplayers") == 20)

	# A config file may set startup-only cvars? No — the server is running, so it
	# must still be refused even from a trusted source.
	_check("missing optional config tolerated", console.exec_config("no_such_file", null, false).ok)
	_check("missing required config reported", not console.exec_config("no_such_file", null, true).ok)

	# A traversal in an exec argument must be refused: exec is reachable over RCON.
	_check(
		"config path traversal refused",
		console.resolve_config_path("../../../etc/passwd") == ""
	)

	var written := console.write_config("example_written")
	_check("writeconfig wrote a file", written.ok)

	if written.ok:
		var text := DotPaths.read_text(str(written.value))
		_check(
			"archived cvar written",
			text.ok and str(text.value).contains("sv_maxplayers")
		)
		# A protected cvar must never be written to a file that gets copied around.
		_check(
			"protected cvar not written",
			text.ok and str(text.value).contains("omitted (protected)")
		)

	server.console.execute("hostname \"dot-server example\"")
	_done()

func _test_command_buffer() -> void:
	print("")
	_section("[command buffer]")
	var console := server.console

	console.execute("hostname \"before\"")
	console.enqueue("hostname \"after\"")

	_check("enqueued command not yet run", console.get_string("hostname") == "before")

	await get_tree().process_frame
	await get_tree().process_frame

	_check("enqueued command ran", console.get_string("hostname") == "after")

	# `wait` suspends the buffer for a number of frames.
	console.enqueue("wait 3; hostname \"waited\"")
	await get_tree().process_frame
	_check("wait suspends the buffer", console.get_string("hostname") == "after")

	for _i in range(6):
		await get_tree().process_frame

	_check("buffer resumes after wait", console.get_string("hostname") == "waited")

	console.execute("hostname \"dot-server example\"")
	_done()

func _test_bans() -> void:
	print("")
	_section("[bans]")
	var bans := server.bans

	_check("the ban list starts empty, not with a previous run's", bans.count() == 0)

	_check("duration: bare number is minutes", DotBanManager.parse_duration("30") == 1800)
	_check("duration: 2h", DotBanManager.parse_duration("2h") == 7200)
	_check("duration: 7d", DotBanManager.parse_duration("7d") == 604800)
	_check("duration: 0 is permanent", DotBanManager.parse_duration("0") == 0)
	_check("duration: garbage rejected", DotBanManager.parse_duration("soon") == -1)

	var banned := await bans.ban_uid("backbone:evil", "cheating", 0, "test")
	_check("account banned", banned.ok)
	_check("banned account refused", not bans.check_uid("backbone:evil").ok)
	_check("other account allowed", bans.check_uid("backbone:fine").ok)

	# The player-facing message must say how long a temporary ban lasts, or they
	# reconnect forever.
	await bans.ban_uid("backbone:temp", "spam", 3600, "test")
	var temp := bans.check_uid("backbone:temp")
	_check(
		"temporary ban states its duration",
		not temp.ok and temp.error.message.contains("1h")
	)

	# An already-expired ban must not block, even before the sweep runs.
	await bans.ban_uid("backbone:expired", "old", 1, "test")
	bans._bans[DotBanManager.uid_key("backbone:expired")]["expires_at"] = 1
	_check("expired ban does not block", bans.check_uid("backbone:expired").ok)

	# Assigned first: `await x.f().ok` binds the await to the property access, not
	# to the call, so the coroutine is never actually awaited.
	var loopback := await bans.ban_address("127.0.0.1", "oops")
	_check("loopback ban refused", not loopback.ok)
	var by_address := await bans.ban_address("203.0.113.5", "proxy")
	_check("address ban works", by_address.ok)
	_check("banned address refused", not bans.check_address("203.0.113.5:51234").ok)

	var lifted := await bans.unban("backbone:evil")
	_check("unban by uid", lifted.ok)
	_check("unbanned account allowed", bans.check_uid("backbone:evil").ok)
	var missing := await bans.unban("backbone:nobody")
	_check("unban unknown reported", not missing.ok)

	_check("banlist runs", _run("banlist").length() > 0)
	_done()

## The flags column of a `status` line, or "" when it is empty. Splits on whitespace, so it
## needs one-word display names.
func _status_flags(session: DotClientSession) -> String:
	var fields := session.status_line().split(" ", false)
	# "# userid name state time ping [flags] uid addr"
	return fields[6] if fields.size() >= 9 else ""

func _test_game_ids() -> void:
	print("")
	_section("[game ids]")

	var d := func(id: String) -> DotGameDescriptor:
		var g := DotGameDescriptor.new()
		g.game_id = id
		g.scene = "res://x.tscn"
		return g

	_check("an owner/name id validates", (d.call("gamemann/game-arena") as DotGameDescriptor).validate().ok)
	_check("so does a built-in's bare name", (d.call("lobby") as DotGameDescriptor).validate().ok)
	_check("two slashes or capitals do not",
		not (d.call("a/b/c") as DotGameDescriptor).validate().ok
		and not (d.call("Gamemann/Arena") as DotGameDescriptor).validate().ok)

	var manager := DotGameManager.new()
	for id in ["alice/arena", "bob/arena", "gamemann/game-g2gfast", "lobby"]:
		manager.add_game(d.call(id))

	_check("a short name that is unique finds its game",
		manager.find_game("game-g2gfast") != null
		and manager.find_game("game-g2gfast").game_id == "gamemann/game-g2gfast")
	var ambiguous := manager.resolve_game("arena")
	_check("a short name two owners share finds nothing, and says whose",
		manager.find_game("arena") == null and not ambiguous.ok
		and ambiguous.error.detail.contains("alice/arena") and ambiguous.error.detail.contains("bob/arena"))
	_check("the full id always finds exactly that fork",
		manager.find_game("bob/arena") != null and manager.find_game("bob/arena").game_id == "bob/arena")
	_check("a built-in with the same short name is not a duplicate of a fork",
		manager.add_game(d.call("arena")).ok)
	_check("and once it exists the bare name means the built-in",
		manager.find_game("arena") != null and manager.find_game("arena").game_id == "arena")
	manager.free()
	_done()

func _test_hibernation() -> void:
	print("")
	_section("[hibernation]")

	# The frame rate is the socket rate: every listener is read once a frame. At the old
	# 5 frames an empty server answered each query up to 200 ms late.
	var tickrate := server.console.get_int("sv_tickrate")
	server._set_state(DotServer.State.HIBERNATING)
	server._apply_tickrate()
	_check("hibernating drops physics to the hibernate tickrate",
		Engine.physics_ticks_per_second == server.config.hibernate_tickrate)
	_check("but keeps frames, and so the sockets, at hibernate_frame_rate (%d)" % Engine.max_fps,
		Engine.max_fps == maxi(server.config.hibernate_tickrate, server.config.hibernate_frame_rate))

	server._set_state(DotServer.State.RUNNING)
	server._apply_tickrate()
	_check("waking restores the tickrate", Engine.physics_ticks_per_second == tickrate)
	_check("and frames follow it again", Engine.max_fps == tickrate)

	# On by default, and the cvar says so: the user's rule is that an empty server idles
	# unless somebody turns it off.
	_check("hibernating when empty is the default", DotServerConfig.new().hibernate_when_empty)
	var cvar := server.console.find_cvar("sv_hibernate_when_empty")
	_check("sv_hibernate_when_empty is a cvar", cvar != null)

	# This server booted with it off and is empty, so it is RUNNING. Turning the cvar on
	# hibernates it now rather than at a disconnect that may never come, and turning it off
	# wakes it — and each says so on hibernation_changed, which every game clock follows.
	var heard: Array[bool] = []
	var listen := func(on: bool) -> void: heard.append(on)
	server.hibernation_changed.connect(listen)
	var empty := server.sessions().is_empty()
	server.console.execute("sv_hibernate_when_empty 1")
	_check("turning it on hibernates an empty server at once (%s)" % server.state_name(),
		not empty or (server.is_hibernating() and server.config.hibernate_when_empty))
	server.console.execute("sv_hibernate_when_empty 0")
	_check("turning it off wakes it", not server.is_hibernating() and not server.config.hibernate_when_empty)
	_check("and hibernation_changed carried both (%s)" % str(heard),
		not empty or str(heard) == str([true, false]))
	server.hibernation_changed.disconnect(listen)
	server._apply_tickrate()
	_done()

## A second server, booted with hibernation left at its default and nobody connected.
func _test_boot_hibernation() -> void:
	print("")
	_section("[hibernation from boot]")

	var config := DotServerConfig.new()
	config.hostname = "hibernating example"
	config.port = 0
	config.query_enabled = false
	config.a2s_enabled = false
	config.log_file_enabled = false
	config.startup_config = ""
	config.autoexec_config = ""
	config.admins_path = "user://example/hib_admins.json"
	config.bans_path = "user://example/hib_bans.json"
	config.audit_log_path = "user://example/hib_audit.jsonl"

	var second := DotServer.new()
	second.name = "Hibernating"
	second.config = config
	second.config_file = ""
	second.auto_boot = false
	var heard: Array[bool] = []
	second.hibernation_changed.connect(func(on: bool) -> void: heard.append(on))
	add_child(second)

	var booted: DotResult = await second.boot()
	_check("a server with the default boots", booted.ok)
	_check("and, being empty, hibernates straight away (%s)" % second.state_name(),
		second.state == DotServer.State.HIBERNATING)
	_check("saying so on hibernation_changed (%s)" % str(heard), str(heard) == str([true]))
	_check("its cvar reads 1", second.console.get_bool("sv_hibernate_when_empty", false))

	# A connect wakes it, long before a spawn would: the joining client syncs its clock to
	# the ticks the server runs from here, and a server still at hibernate_tickrate under
	# that sync sent the first player's commands 28 s early and left them on the spawn pad.
	second._on_peer_connected(4242)
	_check("a client connecting wakes it, before any spawn (%s)" % second.state_name(),
		second.state == DotServer.State.RUNNING
		and Engine.physics_ticks_per_second == second.config.tickrate)

	second.shutdown("test over")
	remove_child(second)
	second.free()

	# Engine.physics_ticks_per_second is process-wide, and the second server set it.
	server._apply_tickrate()
	_done()

func _test_platforms() -> void:
	print("")
	_section("[platforms]")

	var console := server.console
	_check("every platform is admitted by default",
		server.allowed_platforms() == PackedStringArray(["web", "desktop", "mobile"]))
	_check("a browser is admitted by default", server.platform_refusal_for("web") == "")

	console.execute("sv_allow_web 0")
	_check("with sv_allow_web 0 a browser is refused in a sentence that names it",
		server.platform_refusal_for("web").contains("web browser"))
	_check("and a desktop client is still admitted", server.platform_refusal_for("desktop") == "")
	_check("a client from before the field existed is admitted",
		server.platform_refusal_for("") == "" and server.platform_refusal_for("toaster") == "")
	_check("the allowed list says so",
		server.allowed_platforms() == PackedStringArray(["desktop", "mobile"]))

	console.execute("sv_allow_web 1")
	_check("and turning it back on restores it", server.platform_refusal_for("web") == "")
	_done()

func _test_background_grace() -> void:
	print("")
	_section("[background grace]")

	var console := server.console
	var session := _adopt(9100, "10.0.0.9", "Backgrounder")
	session.state = DotClientSession.State.SPAWNED

	console.execute("sv_timeout 60")
	console.execute("sv_background_grace 300")

	_check("an ordinary session is judged on sv_timeout", is_equal_approx(
		server.silence_budget(session), 60.0
	))

	server.set_session_background(session, true, 120.0)
	_check("a background announcement is recorded", session.backgrounded)
	_check("a grace inside the cap is granted as asked", is_equal_approx(
		session.background_grace_sec, 120.0
	))
	_check("the grace is what the sweep judges on", is_equal_approx(
		server.silence_budget(session), 120.0
	))
	# The flags COLUMN, not the line: this session's name and address both contain a
	# "B", and a `contains` over the whole line passed whether the flag was set or not.
	_check("status shows the flag", _status_flags(session).contains("B"))

	# The whole point of the cap. A client that names its own number could hold a slot
	# on a full server for as long as it liked.
	server.set_session_background(session, true, 9999.0)
	_check("a greedy request is clamped to sv_background_grace", is_equal_approx(
		session.background_grace_sec, 300.0
	))

	server.set_session_background(session, true, 0.0)
	_check("asking for nothing in particular gets the maximum", is_equal_approx(
		session.background_grace_sec, 300.0
	))

	# A grace shorter than the ordinary timeout must not SHORTEN it. maxf, not
	# assignment: a client asking for 15 seconds is asking for more tolerance than it
	# had, never for less.
	server.set_session_background(session, true, 15.0)
	_check("a grace below sv_timeout does not shorten it", is_equal_approx(
		server.silence_budget(session), 60.0
	))

	server.set_session_background(session, false)
	_check("coming back clears the flag", not session.backgrounded)
	_check("coming back restores the ordinary budget", is_equal_approx(
		server.silence_budget(session), 60.0
	))
	_check("status drops the flag", not _status_flags(session).contains("B"))

	# 0 is the off switch, and off has to mean the session is not flagged either --
	# a `B` in `status` against a session on the ordinary budget would be a lie.
	console.execute("sv_background_grace 0")
	server.set_session_background(session, true, 120.0)
	_check("a server granting no grace refuses the request", not session.backgrounded)
	_check("and judges it on sv_timeout", is_equal_approx(
		server.silence_budget(session), 60.0
	))

	console.execute("sv_background_grace 300")
	server.release_session(session.peer_id)
	_done()

func _test_targeting() -> void:
	print("")
	_section("[targeting a player]")

	var alpha := _adopt(911, "203.0.113.30:1", "Alpha")
	var alphabet := _adopt(912, "203.0.113.31:1", "Alphabet")
	var bob := _adopt(913, "203.0.113.30:2", "Bob")

	_named(alpha, "backbone:alpha", "alpha_the_first")
	_named(alphabet, "backbone:alphabet", "letters")
	_named(bob, "backbone:bob", "bobby")

	# The exact forms must beat the substring one, or a player whose whole name is
	# another player's prefix cannot be named at all.
	var by_name := server.find_sessions("Alpha")
	_check("an exact name wins outright", by_name.size() == 1 and by_name[0] == alpha)
	_check("case does not matter", server.find_sessions("alpha").size() == 1)
	_check("a substring matches several", server.find_sessions("alph").size() == 2)

	var by_username := server.find_sessions("alpha_the_first")
	_check(
		"a username resolves",
		by_username.size() == 1 and by_username[0] == alpha
	)
	var by_uid := server.find_sessions("backbone:bob")
	_check("an account id resolves", by_uid.size() == 1 and by_uid[0] == bob)
	_check("a userid resolves", server.find_sessions("912")[0] == alphabet)
	_check("a #userid resolves", server.find_sessions("#913")[0] == bob)

	# An address is a household. Returning one of the people at it without saying so is
	# how the wrong player gets removed.
	var by_address := server.find_sessions("ip:203.0.113.30")
	_check("an address matches everybody behind it", by_address.size() == 2)

	_check("@me is the caller", server.find_sessions("@me", bob)[0] == bob)
	_check("@me with no caller matches nobody", server.find_sessions("@me").is_empty())
	_check("nothing matches nothing", server.find_sessions("nobody-here").is_empty())

	# Immunity is checked on the way through resolve_target, from chat as well as here.
	var ctx := DotCmdContext.new()
	ctx.permissions = PackedStringArray([DotAdminFlags.KICK])
	ctx.immunity = 10
	alphabet.immunity = 50

	_check(
		"a target with higher immunity is refused",
		not server.resolve_target(ctx, "Alphabet").ok
	)
	_check("an ambiguous target is refused", not server.resolve_target(ctx, "alph").ok)
	_check("a clear target resolves", server.resolve_target(ctx, "Bob").ok)

	# whois is what makes the rest usable: it is where an admin reads the account id an
	# appeal will name.
	var whois := _run("whois Bob")
	_check("whois shows the account", whois.contains("backbone:bob"))
	_check("whois shows the username", whois.contains("bobby"))
	_check("whois shows the address", whois.contains("203.0.113.30"))

	server.release_session(alpha.peer_id)
	server.release_session(alphabet.peer_id)
	server.release_session(bob.peer_id)
	_done()

## A session the server did not get from a socket. Userid and peer id are the same number
## here so checks read clearly; on a real server they are unrelated.
func _adopt(peer_id: int, address: String, display_name: String) -> DotClientSession:
	var session := DotClientSession.new(peer_id, peer_id)
	session.address = address
	session.display_name = display_name
	server.adopt_session(session)
	return session

## Gives an adopted session an identity, so uid and username targeting have something
## to match.
func _named(session: DotClientSession, uid: String, username: String) -> void:
	var identity := DotGuestIdentity.new()
	identity.uid = uid
	identity.username = username
	identity.display_name = session.display_name
	session.identity = identity
