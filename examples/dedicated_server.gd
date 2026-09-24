extends Node

## Boots a dedicated server and exercises the console, admin and moderation paths.
##
## Runs headless with no clients, which is enough to verify everything a client does
## not participate in: cvar flags, permission enforcement, config execution, the
## command buffer, bans and durations, votes, modules, and the audit trail.
##
## [codeblock]
## godot --headless --path . res://examples/dedicated_server.tscn
##
## # As a real server, with the usual dedicated-server arguments:
## godot --headless --path . res://examples/dedicated_server.tscn -- \
##     --sv-port 27015 --sv-hostname "My Server" +sv_maxplayers 24
## [/codeblock]
##
## Exits non-zero if any check fails, so it works as a smoke test in CI.

const SELFTEST_ARG := "--selftest"

var server: DotServer
## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose.
const SECTIONS := 24

## Every check this suite runs, including the two at the end that compare the counts. The
## section counter cannot see a section that aborted after announcing itself — its remaining
## checks simply never run — and a total can. See docs/testing.md.
const CHECKS := 301

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0


## Stands in for a DotChatRelay, which this addon deliberately cannot name.
class FakeRelay extends RefCounted:
	func is_carrying() -> bool:
		return true


func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	DotLog.timestamps = true

	var config := DotServerConfig.new()
	config.hostname = "dot-server example"
	config.server_id = "example-1"
	# 0 lets the OS pick a free port, so the example never collides with a real
	# server or with a second copy of itself.
	config.port = 0
	config.max_players = 16
	config.reserved_slots = 2
	config.tickrate = 30
	# Explicit, because an ephemeral game port has nothing to derive one from.
	config.rcon_port = 27055
	config.rcon_password = "example-rcon-password"
	config.rcon_allowed_addresses = PackedStringArray(["127.0.0.1"])
	# The browser-facing console. On its own port, with its own auth path, so it
	# needs its own coverage: a panel cannot open a raw TCP socket.
	config.rcon_websocket = true
	config.rcon_websocket_port = 27057
	# Both query protocols, on one explicit UDP port. An ephemeral game port has
	# nothing to derive a query port from, and this exercises the shared-socket
	# path: the dot query listener binds and A2S attaches to it.
	config.a2s_enabled = true
	config.a2s_port = 27056
	config.a2s_app_id = 4242
	config.a2s_game_folder = "dotexample"
	config.tags = PackedStringArray(["example", "dev"])
	config.admins_path = "user://example/admins.json"
	config.bans_path = "user://example/bans.json"
	config.audit_log_path = "user://example/audit.jsonl"
	config.hibernate_when_empty = false

	# No boot configs. The addon ships a default server.cfg (setting
	# sv_maxplayers 32 among other things) and the search path finds it, which is
	# correct behaviour — a file layer beats exported defaults — but it would make
	# this self-test assert against whatever that file happens to contain.
	# Config execution is tested explicitly in _test_config_files().
	config.startup_config = ""
	config.autoexec_config = ""

	# [b]A self-test starts from nothing in user://example.[/b] The ban list, the audit log
	# and the admin file there are read back at boot, and they used to carry over: every
	# run began with the previous run's permanent address ban already in place, and the
	# audit log had grown past a quarter of a megabyte. Not when serving — an operator
	# trying this scene out may want to keep what they did. See docs/testing.md.
	if _should_selftest():
		DotPaths.remove_tree("user://example")

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	# Empty so the example is not affected by a config file left from another run.
	server.config_file = ""
	server.auto_boot = false
	add_child(server)

	var booted := await server.boot()

	if not booted.ok:
		printerr("boot failed: %s" % str(booted.error))
		get_tree().quit(1)
		return

	print("")
	print("Server is up. Try: telnet 127.0.0.1 %d (RCON)" % config.effective_rcon_port())
	print("")

	if _should_selftest():
		await _run_selftest()
		return

	# Interactive mode: print status every 30 seconds so a headless run shows signs
	# of life.
	var timer := Timer.new()
	timer.wait_time = 30.0
	timer.autostart = true
	timer.timeout.connect(func() -> void:
		DotLog.info("example", "still running", server.describe()))
	add_child(timer)


func _should_selftest() -> bool:
	# Default to self-testing when headless with no arguments, so the scene is
	# useful as a smoke test without anyone remembering a flag.
	var args := OS.get_cmdline_user_args()
	if args.has(SELFTEST_ARG):
		return true
	if args.has("--serve"):
		return false
	return DotPlatform.is_headless()


# --- Self-test -------------------------------------------------------------

func _run_selftest() -> void:
	print("=== self-test ===")
	print("")

	_test_console()
	_test_stdin_console()
	_test_console_source()
	_test_argument_completion()
	_test_cvar_flags()
	_test_permissions()
	_test_config_files()
	await _test_command_buffer()
	await _test_bans()
	_test_admins()
	_test_connection_limits()
	_test_background_grace()
	_test_targeting()
	await _test_ban_source()
	_test_events()
	_test_chat_state()
	_test_notices()
	_test_chat_commands()
	_test_guest_identity()
	await _test_modules()
	_test_audit()
	_test_rcon_allow_list()
	await _test_rcon_socket()
	await _test_rcon_websocket()

	print("")
	# The two guards, as the last two checks. See docs/testing.md.
	_check(
		"every section ran to its last line (%d of %d)" % [_completed, SECTIONS],
		_completed == _entered and _entered == SECTIONS
	)
	_check(
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		_passed + _failed + 1 == CHECKS
	)
	print("%d passed, %d failed" % [_passed, _failed])

	server.shutdown("self-test complete")
	get_tree().quit(1 if _failed > 0 else 0)


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


## A command object of the duck-typed shape, for [method DotConsole.add_source].
##
## Deliberately a bare [RefCounted] with nothing of this family on it. The whole point of
## the hook is that an addon dot-server has never heard of can plug a command in, and a
## fixture that extended one of ours would prove a narrower thing than the one claimed.
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


## Which stdin the operator console reads. A reader on a pipe nobody closes cannot be
## cancelled and keeps the process from exiting, so this very suite, run as `sleep 600 |
## godot ...`, used to print its totals and then hang until the runner killed it. Only a
## terminal and a file are read unless a host asks for pipes. The exit itself is checked
## from outside -- run this scene with an open pipe on stdin and it must exit on its own.
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

	# Completion, which is the half that used to have nowhere to arrive.
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


func _test_cvar_flags() -> void:
	print("")
	_section("[cvar flags]")
	var console := server.console

	_check("cvar reads", _run("sv_maxplayers").contains("sv_maxplayers = 16"))

	_run("sv_maxplayers 24")
	_check("cvar writes", console.get_int("sv_maxplayers") == 24)

	# Clamping rather than refusing: an operator typing a huge number should get the
	# maximum with a note, not an error.
	_run("sv_maxplayers 99999")
	_check("out-of-range clamped", console.get_int("sv_maxplayers") == 4096)
	_run("sv_maxplayers 16")

	# A protected cvar must never print its value.
	_run("sv_password hunter2")
	var listed := _run("cvarlist sv_password")
	_check("protected value redacted", listed.contains("***") and not listed.contains("hunter2"))
	_run("sv_password \"\"")

	# Startup-only cvars are locked once the server is listening.
	var before := console.get_int("sv_tickrate")
	var refused := _run("sv_tickrate 120")
	_check(
		"startup-only refused while running",
		console.get_int("sv_tickrate") == before and refused.contains("only be changed")
	)

	# ...and settable before it is, which is the half that makes the flag mean
	# "startup" rather than "never". `server.cfg` is exec'd before the listener for
	# exactly this, and so is the CVAR half of the command line — `+sv_tickrate 128`
	# is the most startup-ish input a server takes, and running the whole command
	# line after the listener made it unsettable from there, so an operator with
	# muscle memory from any other server got one that quietly ignored them.
	console.set_server_running(false)
	_run("sv_tickrate 120")
	_check("startup-only settable before the server runs", console.get_int("sv_tickrate") == 120)
	_run("sv_tickrate %d" % before)
	console.set_server_running(true)

	# The command-line split itself. There is no `+` argument on this process's
	# argv, so both passes find nothing — what is under test is that the cvar-only
	# pass exists, is selective, and does not run commands.
	_check(
		"the command line can be replayed for cvars only",
		console.execute_command_line(true) == 0
			and console.command_line_statements().is_empty()
	)

	# A cheat cvar set from an untrusted context must be refused.
	var cheat := console.cvar(
		"sv_example_cheat", "0", "Test cheat variable.", DotConVar.FLAG_CHEAT
	)
	var ctx := _client_context(PackedStringArray([DotAdminFlags.CVAR]))
	ctx.command = "sv_example_cheat"
	ctx.args = PackedStringArray(["1"])
	console.execute("sv_example_cheat 1", ctx)
	_check("cheat cvar refused with sv_cheats off", cheat.get_bool() == false)

	_run("sv_cheats 1")
	console.execute("sv_example_cheat 1", _client_context(
		PackedStringArray([DotAdminFlags.CVAR, DotAdminFlags.CHEATS])
	))
	_check("cheat cvar allowed with sv_cheats on", cheat.get_bool() == true)
	_run("sv_cheats 0")

	# Bool parsing should accept what an operator would actually type.
	cheat.force_set("true")
	_check("bool accepts 'true'", cheat.get_bool())
	cheat.force_set("off")
	_check("bool accepts 'off'", not cheat.get_bool())
	_done()


func _test_permissions() -> void:
	print("")
	_section("[permissions]")
	var console := server.console

	# A caller with no flags must not reach a permissioned command.
	var nobody := _client_context(PackedStringArray())
	var res := console.execute("kick someone", nobody)
	_check(
		"command refused without permission",
		not res.ok and res.code() == DotError.CODE_FORBIDDEN
	)

	# With the flag it gets past the permission check and fails on the target
	# instead, which is the next check in line.
	var kicker := _client_context(PackedStringArray([DotAdminFlags.KICK]))
	var res2 := console.execute("kick someone", kicker)
	_check(
		"command allowed with permission",
		res2.ok or res2.code() != DotError.CODE_FORBIDDEN
	)

	# ROOT satisfies every flag.
	var root := _client_context(PackedStringArray([DotAdminFlags.ROOT]))
	_check("root satisfies any flag", root.has_permission(DotAdminFlags.BAN))

	# Immunity: equal cannot act on equal.
	var mid := _client_context(PackedStringArray([DotAdminFlags.KICK]))
	mid.immunity = 50
	_check("equal immunity does not outrank", not mid.outranks(50))
	_check("higher immunity outranks", mid.outranks(20))
	_check("root bypasses immunity", root.outranks(DotAdminFlags.MAX_IMMUNITY))

	# Chat reaches the console, and the permission check is what decides. `rcon_status`
	# has never been marked `with_chat()` and is reachable anyway, because this holder has
	# ROOT -- that reversal is the whole point of `sv_chat_commands`.
	var chat_ctx := _client_context(PackedStringArray([DotAdminFlags.ROOT]))
	chat_ctx.source = DotCmdContext.Source.CHAT
	var chat_res := console.execute("rcon_status", chat_ctx)
	_check("an unmarked command runs from chat with the flag", chat_res.ok)

	# The same line without the flag stops at the permission check, not before it: what
	# refuses a player is the flag they do not hold, on every source alike.
	var chat_nobody := _client_context(PackedStringArray())
	chat_nobody.source = DotCmdContext.Source.CHAT
	var chat_denied := console.execute("rcon_status", chat_nobody)
	_check(
		"and is refused without it",
		not chat_denied.ok and chat_denied.code() == DotError.CODE_FORBIDDEN
	)

	# A command that refuses chat outright is refused for ROOT too. That is the difference
	# between `no_chat()` and a permission: one is about the operation, the other about who.
	var quit_res := console.execute("quit", chat_ctx)
	_check(
		"a no_chat() command is refused from chat even for root",
		not quit_res.ok and quit_res.code() == DotError.CODE_FORBIDDEN
	)

	# And one that opted in must be reachable.
	var chat_ok := console.execute("whoami", chat_ctx)
	_check("chat-allowed command works from chat", chat_ok.ok)

	# `sv_chat_commands 0` restores the old behaviour exactly: only `with_chat()` is
	# reachable by typing. Checked by flipping the cvar the console reads, because a
	# deployment that wants its console reached by console is a supported one.
	var chat_cvar := console.find_cvar("sv_chat_commands")
	_check("sv_chat_commands exists and ships on", chat_cvar != null and chat_cvar.get_bool())
	if chat_cvar != null:
		chat_cvar.set_value("0", {"has_permission": true, "cheats_enabled": true})
		var closed := console.execute("rcon_status", chat_ctx)
		_check(
			"closing it puts the unmarked command back out of reach",
			not closed.ok and closed.code() == DotError.CODE_FORBIDDEN
		)
		_check(
			"while a with_chat() command still answers",
			console.execute("whoami", chat_ctx).ok
		)
		chat_cvar.set_value("1", {"has_permission": true, "cheats_enabled": true})
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


func _test_connection_limits() -> void:
	print("")
	_section("[per-address connection limit]")

	var guard := DotAddressGuard.new(2)
	var in_use := PackedStringArray(["203.0.113.7:51000", "203.0.113.7:51001"])

	_check("the port is not part of the address", guard.count_for("203.0.113.7", in_use) == 2)
	_check(
		"a third connection from one address is refused",
		not guard.check("203.0.113.7:51002", in_use).ok
	)
	_check(
		"the refusal tells the player the number",
		guard.check("203.0.113.7:9", in_use).error.message.contains("2")
	)
	_check("a different address is unaffected", guard.check("198.51.100.4", in_use).ok)

	# The operator's own machine is where every listen client, bot harness and headless
	# test connects from. A limit that locks them out is a limit nobody leaves on.
	_check(
		"loopback is never limited",
		guard.check("127.0.0.1", PackedStringArray(["127.0.0.1", "127.0.0.1", "127.0.0.1"])).ok
	)

	# An address the transport could not report is not an address. Limiting it would put
	# every such client in one bucket and refuse the third player on an empty server.
	_check(
		"an unreportable address is not limited",
		guard.check("unknown", PackedStringArray(["unknown", "unknown", "unknown"])).ok
	)

	guard.exempt_addresses = PackedStringArray(["198.51.100.4"])
	_check(
		"an exempt address is not limited",
		guard.check(
			"198.51.100.4", PackedStringArray(["198.51.100.4", "198.51.100.4"])
		).ok
	)

	_check(
		"0 means no limit",
		DotAddressGuard.new(0).check("203.0.113.7", in_use).ok
	)
	_check("refusals are counted", guard.refused > 0)

	# And now through the server's own admission path, against its real session table —
	# a guard that decides correctly and is asked by nobody is this family's most
	# repeated bug.
	var before := server.address_guard.limit
	server.address_guard.limit = 2

	_check(
		"the server admits the first from an address",
		server.check_address_admission("203.0.113.20:1000").ok
	)

	var one := _adopt(901, "203.0.113.20:1000", "Nat One")
	var two := _adopt(902, "203.0.113.20:1001", "Nat Two")

	_check("two sessions are counted at that address", server.sessions_from("203.0.113.20").size() == 2)
	_check(
		"the third is refused by the server",
		not server.check_address_admission("203.0.113.20:1002").ok
	)
	_check(
		"somebody else still gets in",
		server.check_address_admission("198.51.100.77:1002").ok
	)

	# Live, because an operator turns this on while the thing it stops is happening.
	_run("sv_max_connections_per_ip 3")
	_check("the cvar reaches the guard", server.address_guard.limit == 3)
	_check(
		"and the third is admitted again",
		server.check_address_admission("203.0.113.20:1002").ok
	)
	_check("the config sees it too", server.config.max_connections_per_ip == 3)

	server.release_session(one.peer_id)
	server.release_session(two.peer_id)
	server.address_guard.limit = before
	_run("sv_max_connections_per_ip %d" % before)
	_done()


## The flags column of a `status` line, or "" when it is empty.
##
## Every other column is a fixed width the format string owns; splitting on runs of
## whitespace finds them all regardless, and an empty flags column simply is not there.
## Depends on the display name having no spaces in it, which is why the sessions this
## is used on are named in one word.
func _status_flags(session: DotClientSession) -> String:
	var fields := session.status_line().split(" ", false)
	# "# userid name state time ping [flags] addr"
	return fields[6] if fields.size() >= 8 else ""


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


func _test_ban_source() -> void:
	print("")
	_section("[an external ban list: dot-moderation]")

	# Loaded by path and called by duck typing, never by class name: naming
	# DotModerationManager here would make this whole example fail to parse in a
	# checkout that does not have the addon, which is every checkout of dot-server
	# alone.
	var manager_path := "res://addons/dot_moderation/runtime/dot_moderation_manager.gd"
	var store_path := "res://addons/dot_moderation/store/dot_punishment_store_file.gd"

	if not ResourceLoader.exists(manager_path):
		# Said out loud rather than skipped. "0 failures" from a suite that ran nothing
		# is how this family gets to a release with two ends that never met.
		_check(
			"dot-moderation is linked, so the ban-source seam is covered",
			false
		)
		return

	# A fresh file each run. A suite whose result depends on what a previous run left
	# behind is a suite that passes until the day it is read.
	var store_file := "user://example/punishments.json"
	DotPaths.remove_tree(store_file)

	var manager: Node = (load(manager_path) as GDScript).new()
	manager.name = "Moderation"
	manager.set("store", (load(store_path) as GDScript).new(store_file))
	manager.set("register_ban_source", true)
	add_child(manager)
	await get_tree().process_frame

	var loaded: Variant = await manager.call("load_all")
	_check("the punishment store loads", loaded is DotResult)

	# One registry name, and neither addon names the other.
	_check(
		"it publishes itself where dot-server looks",
		DotRegistry.get_service(DotServer.BAN_SOURCE) == manager
	)

	var banned: Variant = await manager.call(
		"ban_address", "203.0.113.55", "smurfing", "admin:sarah", 0, 0
	)
	_check("an address ban is recorded", banned is DotResult and (banned as DotResult).ok)
	# A ban filed against 1.2.3.4 and checked as ip:1.2.3.4:51000 is two strings that
	# never meet, and nothing errors when they do not.
	_check(
		"and the two ends spell the subject the same way",
		bool(manager.call("is_banned_address", "203.0.113.55:51000"))
	)

	var refused := server.check_address_admission("203.0.113.55:51000")
	_check("dot-server refuses that address at connect", not refused.ok)
	_check(
		"with a message the player can act on",
		not refused.ok and refused.error.message.to_lower().contains("banned")
	)
	_check(
		"anybody else is still admitted",
		server.check_address_admission("198.51.100.90:51000").ok
	)

	var uid_banned: Variant = await manager.call(
		"ban_uid", "backbone:evil", "cheating", "admin:sarah", 0, 0
	)
	_check("an account ban is recorded", uid_banned is DotResult and (uid_banned as DotResult).ok)

	var evil := _adopt(921, "198.51.100.91:1", "Evil")
	_named(evil, "backbone:evil", "evil")
	_check(
		"and dot-server refuses them after they authenticate",
		not server.check_identity_admission(evil).ok
	)

	var good := _adopt(922, "198.51.100.92:1", "Good")
	_named(good, "backbone:good", "good")
	_check("an unpunished account is admitted", server.check_identity_admission(good).ok)

	# The whole point of enforce_bans: a ban issued against somebody already connected
	# has to remove them, or it takes effect only when they choose to leave.
	var removed := server.enforce_bans()
	_check("a ban issued mid-session removes them", removed == 1)
	_check("and leaves everybody else alone", server.session_by_userid(922) != null)

	# Loopback is a mistyped argument far more often than it is a decision, and banning
	# it locks an operator out of their own listen server.
	var loopback: Variant = await manager.call(
		"ban_address", "127.0.0.1", "oops", "admin:sarah", 0, 0
	)
	_check(
		"loopback cannot be banned",
		loopback is DotResult and not (loopback as DotResult).ok
	)

	var record: Object = (banned as DotResult).value
	var lifted: Variant = await manager.call(
		"revoke", str(record.get("id")), "admin:sarah", "appealed", 0
	)
	_check("the ban is lifted", lifted is DotResult and (lifted as DotResult).ok)
	_check(
		"and the address is admitted again",
		server.check_address_admission("203.0.113.55:51000").ok
	)

	# A source that cannot answer must not be trusted to have answered. It is reported
	# once and ignored, because refusing every connection would take the server down.
	manager.queue_free()
	await get_tree().process_frame

	var broken := Node.new()
	add_child(broken)
	DotRegistry.register(DotServer.BAN_SOURCE, broken)
	_check(
		"a ban source that cannot answer does not refuse everybody",
		server.check_address_admission("203.0.113.55:51000").ok
	)
	DotRegistry.unregister_instance(DotServer.BAN_SOURCE, broken)
	broken.queue_free()

	server.release_session(good.peer_id)
	_done()


## A session the server did not get from a socket, for tests that need players.
##
## The userid and the peer id are the same number here purely so the checks below read
## clearly; on a real server they are unrelated, which is why `kick` and `kickid` exist
## separately.
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


func _test_admins() -> void:
	print("")
	_section("[admins]")
	var admins := server.admins

	_check(
		"admin_add",
		admins.set_admin(
			"backbone:alice",
			DotAdminFlags.parse("kick,ban"),
			50,
			PackedStringArray(),
			"Alice"
		).ok
	)

	_check(
		"granted flag recognised",
		admins.uid_has_permission("backbone:alice", DotAdminFlags.KICK)
	)
	_check(
		"ungranted flag refused",
		not admins.uid_has_permission("backbone:alice", DotAdminFlags.ROOT)
	)

	# A uid answered by a SOURCE rather than by the admin file.
	#
	# This is the case that used to be refused for everybody: `uid_permissions` read the
	# file and nothing else, on the reasoning that a source needs an identity and only a
	# connection carries one. True of dot-auth's, false of every source that is a table
	# keyed by uid -- so a deployment whose admins live in a config file (which is
	# `dot-server-deploy`, and therefore every TMC server) refused every command relayed
	# from the website, permanently, with nothing erroring.
	var table := UidTableSource.new()
	table.rows["backbone:bob"] = PackedStringArray([DotAdminFlags.CHANGEMAP])
	admins.add_source(table)

	_check(
		"a source answers for a uid with no file entry",
		admins.uid_has_permission("backbone:bob", DotAdminFlags.CHANGEMAP)
	)
	_check(
		"and grants only what it said",
		not admins.uid_has_permission("backbone:bob", DotAdminFlags.BAN)
	)
	_check(
		"a uid nothing knows still holds nothing",
		not admins.uid_has_permission("backbone:nobody", DotAdminFlags.CHANGEMAP)
	)
	# The name the site would have sent is deliberately NOT tried: it is a string the
	# person can edit on their own profile page, and an admin entry keyed on one is a
	# permission anybody can take by renaming themselves.
	table.rows["Alice"] = PackedStringArray([DotAdminFlags.ROOT])
	_check(
		"a display name is never a key",
		not admins.uid_has_permission("Alice", DotAdminFlags.ROOT)
			or table.asked_with_display_name == false
	)

	_check("flag parse: comma", DotAdminFlags.parse("kick,ban").size() == 2)
	_check("flag parse: space", DotAdminFlags.parse("kick ban").size() == 2)
	_check("flag parse: mixed", DotAdminFlags.parse("kick, ban").size() == 2)
	_check(
		"unknown flag detected",
		DotAdminFlags.unknown(PackedStringArray(["kcik"])).size() == 1
	)
	_check(
		"custom flag reported but not refused",
		DotAdminFlags.granted(PackedStringArray(["slay"]), "slay")
	)

	_check("admins listed", _run("admins").contains("backbone:alice"))
	_check("admin_remove", admins.remove_admin("backbone:alice").ok)
	_done()


## [DotNotice]'s wire form, and the server's half with nobody to send to.
##
## The half with a client is in `signon_revision`, over a real socket. This is what a
## socket cannot show: that the decoder survives a payload no server of this build sends —
## an older one, a newer one, or garbage — because a client is not allowed to raise on a
## message it did not expect.
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
	# And every one dot-chat's filter refuses, written out here rather than read from the
	# constant, so that the constant shrinking is something this can see. The C1 controls,
	# the soft hyphen, both directional marks, the word joiner and the deprecated format
	# characters all reached a HUD line while this matched only eleven of them.
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


## `DotChatManager.sanitise` against the definition it replaced, as written before it was
## made linear: filter, collapse, strip, cut. Empty when every case agrees.
func _sanitise_mismatch() -> String:
	var alphabet := ["a", "b", " ", "\n", "\t", "\u007F", "\u200B", "\u202E", "\u0001", "é",
		"\u0085", "\u200E", "\u00AD", "\u2060"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var cases: Array[String] = ["", " ", "  a  ", "a \u200B b", "\u200B", "ab cd", "ab  ", " \n\t "]
	for n in 400:
		var one := PackedStringArray()
		for k in rng.randi_range(0, 12):
			one.append(alphabet[rng.randi_range(0, alphabet.size() - 1)])
		cases.append("".join(one))
	for raw in cases:
		for limit in [0, 1, 2, 3, 5, 160]:
			var got := DotChatManager.sanitise(raw, limit)
			var want := _sanitise_reference(raw, limit)
			if got != want:
				return "%s at %d: got %s, want %s" % [raw.c_escape(), limit, got.c_escape(), want.c_escape()]
	return ""


func _sanitise_reference(raw: String, max_length: int) -> String:
	var out := ""
	for i in range(raw.length()):
		var code := raw.unicode_at(i)
		if code == 9 or code == 10 or code == 13:
			out += " "
			continue
		if code < 32 or code == 127 or (code >= 0x80 and code <= 0x9F):
			continue
		if code in [0x00AD, 0x061C, 0x180E, 0xFEFF]:
			continue
		if (code >= 0x200B and code <= 0x200F) or (code >= 0x202A and code <= 0x202E):
			continue
		if (code >= 0x2060 and code <= 0x2064) or (code >= 0x2066 and code <= 0x206F):
			continue
		out += raw[i]
	while out.contains("  "):
		out = out.replace("  ", " ")
	out = out.strip_edges()
	if max_length > 0 and out.length() > max_length:
		out = out.substr(0, max_length)
	return out


func _test_chat_state() -> void:
	print("")
	_section("[chat state]")
	var chat := server.chat

	_check("a server nobody told carries chat nowhere else", not chat.is_relayed())
	_check(
		"and says so in a payload a client can tell from a line",
		str(chat.chat_state().get("kind", "")) == "state"
	)
	_check("with relay false", not bool(chat.chat_state().get("relay", true)))

	# The point of the seam: dot-server never names a relay, it asks.
	chat.relay_fn = func() -> bool: return true
	_check("a server with a relay says so", chat.is_relayed())
	_check("and the payload carries it", bool(chat.chat_state().get("relay", false)))

	# A seam that answers with something that is not a bool must read as "no" rather
	# than as truthy: a host wiring this to a method that returns a DotResult would
	# otherwise tell every client the conversation is carried when it is not.
	chat.relay_fn = func() -> Variant: return "yes"
	_check("a non-boolean answer is no", not chat.is_relayed())

	# `watch_relay` is the one line a game writes, and it is duck-typed because
	# dot-server cannot name DotChatRelay.
	#
	# [b]Held in a variable, and that is not style.[/b] A [Callable] stores an object id
	# and does NOT keep a [RefCounted] alive, so `watch_relay(FakeRelay.new())` binds to
	# something that is freed on the next line and the seam reads as "no relay" for ever.
	# The real one is a [Node] the game keeps in the tree, which is why this is a trap the
	# test walked into and the product did not.
	var fake := FakeRelay.new()
	chat.watch_relay(fake)
	_check("watch_relay takes anything with is_carrying", chat.is_relayed())

	var plain := RefCounted.new()
	chat.watch_relay(plain)
	_check("and an object without one carries nothing", not chat.is_relayed())

	chat.watch_relay(null)
	_check("and clearing it goes back to no", not chat.is_relayed())
	_done()


func _test_events() -> void:
	print("")
	_section("[events]")
	var events := server.events

	var fired := [0]
	events.hook_post("example_event", func(_e: DotEvent) -> void: fired[0] += 1)
	events.fire("example_event", {})
	_check("post hook ran", fired[0] == 1)

	# A pre-hook that cancels must stop the event and skip post hooks.
	var post_ran := [false]
	events.hook_pre("cancel_me", func(e: DotEvent) -> void: e.cancel("nope"))
	events.hook_post("cancel_me", func(_e: DotEvent) -> void: post_ran[0] = true)

	var event := events.fire("cancel_me", {})
	_check("pre hook cancelled", event.cancelled and event.cancel_reason == "nope")
	_check("post hook skipped after cancel", not post_ran[0])

	# A pre-hook rewriting data is how a chat filter works without rejecting.
	events.hook_pre("rewrite_me", func(e: DotEvent) -> void:
		e.set_value("text", "clean"))
	var rewritten := events.fire("rewrite_me", {"text": "dirty"})
	_check("pre hook rewrote data", rewritten.get_string("text") == "clean")

	# Typed accessors must coerce rather than crash on unexpected types.
	var typed := events.fire("typed", {"n": "42", "f": 1, "b": "yes"})
	_check("get_int coerces a string", typed.get_int("n") == 42)
	_check("get_float coerces an int", is_equal_approx(typed.get_float("f"), 1.0))
	_check("get_bool coerces 'yes'", typed.get_bool("b"))
	_check("missing key returns default", typed.get_int("absent", 7) == 7)
	_done()


## The identity used when dot-auth is absent.
##
## Only reached in that configuration, which is exactly why it needs a test — a
## server with dot-auth installed never touches it, so a break here would surface
## only for the people running the simplest setup.
func _test_guest_identity() -> void:
	print("")
	_section("[guest identity]")

	var guest := DotGuestIdentity.from_device("device-abc", "Ada")

	_check("valid", guest.is_valid())
	_check("uid namespaced", guest.uid.begins_with("guest:"))
	_check("marked as guest", guest.is_guest)
	_check("requested name used", guest.display_name == "Ada")
	_check("label includes the uid", guest.label().contains(guest.uid))

	# The device id is hashed, not stored: it is client-supplied and arbitrary.
	_check("device id not stored raw", not guest.uid.contains("device-abc"))

	# Stable, so a mute or kick lasts across a reconnect within the session.
	var again := DotGuestIdentity.from_device("device-abc")
	_check("same device gives the same uid", again.uid == guest.uid)

	var other := DotGuestIdentity.from_device("device-xyz")
	_check("different device gives a different uid", other.uid != guest.uid)

	# No device id at all must not make every anonymous client the same person.
	var anon_a := DotGuestIdentity.from_device("")
	var anon_b := DotGuestIdentity.from_device("")
	_check("missing device id yields distinct ids", anon_a.uid != anon_b.uid)
	_check("generated name when none given", anon_a.display_name.begins_with("Guest-"))

	# The session reads identity through this surface, so it must satisfy it.
	var session := DotClientSession.new(99, 99)
	session.identity = guest
	_check("session accepts it", session.is_authenticated())
	_check("session reads the uid", session.uid() == guest.uid)
	_check("session sees it is not an account", not session.is_account())

	# A guest must never receive admin permissions.
	server.admins.resolve(session)
	_check("guest gets no permissions", session.permissions.is_empty())
	_done()


func _test_modules() -> void:
	print("")
	_section("[modules]")

	var module_source := """
extends DotModule

func _module_name() -> String: return "example"
func _module_version() -> String: return "1.2.3"
func _module_description() -> String: return "A test module."

func _module_load() -> DotResult:
	add_command("example_hello", _hello, "Say hello", "")
	add_cvar("example_mod_cvar", "7", "A module variable.")
	hook_post("client_spawn", _on_spawn)
	return DotResult.success(null)

func _hello(ctx: DotCmdContext) -> void:
	ctx.reply("hello from the module")

func _on_spawn(_e: DotEvent) -> void:
	pass
"""

	DotPaths.write_text("user://example/modules/example.gd", module_source)

	var loaded: DotResult = await server.modules.load_module(
		"user://example/modules/example.gd"
	)
	_check("module loaded", loaded.ok)

	if loaded.ok:
		_check("module command registered", server.console.find_command("example_hello") != null)
		_check("module cvar registered", server.console.find_cvar("example_mod_cvar") != null)
		_check("module command runs", _run("example_hello").contains("hello from the module"))
		_check("modules listed", _run("modules").contains("example"))

		var hooks_before := server.events.hook_count("client_spawn")

		var unloaded := server.modules.unload_module("example")
		_check("module unloaded", unloaded.ok)

		# The reason the registration helpers exist: an unloaded module must leave
		# nothing behind that can be called into.
		_check(
			"module command removed",
			server.console.find_command("example_hello") == null
		)
		_check(
			"module cvar removed",
			server.console.find_cvar("example_mod_cvar") == null
		)
		_check(
			"module hooks removed",
			server.events.hook_count("client_spawn") < hooks_before
		)

	# A script that is not a DotModule must be refused rather than half-loaded.
	DotPaths.write_text(
		"user://example/bad_module.gd",
		"extends Node\nfunc _ready() -> void: pass\n"
	)
	_check(
		"non-module script refused",
		not (await server.modules.load_module("user://example/bad_module.gd")).ok
	)
	_done()


func _test_audit() -> void:
	print("")
	_section("[audit]")
	var audit := server.audit

	audit.record("test_action", "tester", "target", {"detail": "value"})

	var recent := audit.recent(10)
	_check("action recorded", recent.size() > 0)
	_check(
		"recorded action found",
		audit.search("test_action").size() > 0
	)

	# Permissioned commands go into the audit trail; unpermissioned ones do not, or
	# `status` would bury every real action.
	var before := audit.recent(200).size()
	_run("status")
	_check("public command not audited", audit.recent(200).size() == before)

	var console := server.console
	console.execute("admin_reload", _client_context(
		PackedStringArray([DotAdminFlags.ROOT])
	))
	_check("permissioned command audited", audit.recent(200).size() > before)

	_check("audit command runs", _run("audit 5").length() > 0)
	_done()


# --- Query -----------------------------------------------------------------
#
# The query tests are NOT here any more. Both protocols live in dot-server-query,
# and its own suite drives them the same way this one used to: handle_datagram()
# takes a datagram and returns the datagrams to send back, so the whole of DQP and
# A2S is exercised without binding a socket. Running them here would have needed
# this project to link an optional addon in order to test a server without it.


# --- Helpers ---------------------------------------------------------------

## Runs a command as the local console and returns its output.
func _run(line: String) -> String:
	var lines := PackedStringArray()
	var ctx := DotCmdContext.console("", PackedStringArray())
	ctx.reply_sink = func(text: String) -> void: lines.append(text)
	server.console.execute(line, ctx)
	return "\n".join(lines)


## A context that looks like a client, for permission tests.
## The whole chat-command path, end to end, which had no executed coverage at all.
##
## Everything else about chat commands is asserted against a hand-built context with
## `Source.CHAT` on it. That skips the part a player actually uses: the prefix, the
## manager's parse, the dispatch into the console. The bug that started this — an operator
## typing `/map surf_beginner` and being told the command cannot be run from chat — lived
## precisely in the gap between those two, and no assertion in this suite could see it.
func _test_chat_commands() -> void:
	print("")
	_section("[chat commands]")

	var chat := server.chat
	var console := server.console

	# A session the manager will accept: SPAWNED, with a peer id no transport knows. The
	# replies really are sent — this is the whole path, not a stubbed one — and the
	# multiplayer layer drops them, which is what it does for a player who left mid-command.
	var session := DotClientSession.new()
	session.userid = 9001
	session.peer_id = 424242
	session.display_name = "operator"
	session.address = "203.0.113.9"
	session.state = DotClientSession.State.SPAWNED
	session.immunity = 50
	session.permissions = PackedStringArray([DotAdminFlags.RCON])

	var ran: Array[String] = []
	var on_run := func(c: DotCmdContext) -> void: ran.append(c.command)
	console.command_executed.connect(on_run)

	# `/` and `!`, both of dot-server's default prefixes, on a command that never marked
	# itself `with_chat()`. This is the line the screenshot was of.
	chat.handle_message(session, "/rcon_status")
	_check("a `/` line runs an unmarked command", ran.has("rcon_status"))
	ran.clear()
	chat.handle_message(session, "!rcon_status")
	_check("and so does a `!` line", ran.has("rcon_status"))
	ran.clear()

	# Without the flag it stops at the permission check. The refusal is the same one RCON
	# gets, from the same line of the same function.
	session.permissions = PackedStringArray()
	var denied := chat.handle_message(session, "/rcon_status")
	_check(
		"the flag is what refuses, not the prefix",
		not denied.ok and denied.code() == DotError.CODE_FORBIDDEN and ran.is_empty()
	)

	# A command that refuses chat outright stays refused for somebody holding ROOT.
	session.permissions = PackedStringArray([DotAdminFlags.ROOT])
	var quit_res := chat.handle_message(session, "/quit")
	_check(
		"and `no_chat()` refuses even root, because it is about the operation",
		not quit_res.ok and ran.is_empty()
	)

	# An ordinary sentence that happens to start with a slash must not be eaten silently
	# and must not become a command either.
	var typo := chat.handle_message(session, "/what is this")
	_check("an unknown `/` line is refused rather than spoken", not typo.ok)
	_check("and nothing ran", ran.is_empty())

	console.command_executed.disconnect(on_run)
	_done()


func _client_context(permissions: PackedStringArray) -> DotCmdContext:
	var ctx := DotCmdContext.new()
	ctx.source = DotCmdContext.Source.RCON
	ctx.permissions = permissions
	ctx.immunity = 10
	ctx.address = "203.0.113.1"
	ctx.reply_sink = func(_text: String) -> void: pass
	return ctx


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
	_done()


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


## Long output has to survive being split into several packets.
##
## The splitter is the only part of the protocol that rewrites the payload, and no
## in-process test can see it: [method DotConsole.execute] hands back the text
## whole. Both bounds matter — a client must be able to reassemble the exact text,
## and no single packet may exceed what the protocol allows.
func _test_rcon_long_responses(peer: StreamPeerTCP) -> void:
	# A command whose output is long, but built from short lines.
	server.console.register_command(DotConCommand.new(
		"selftest_long",
		func(ctx: DotCmdContext) -> void:
			for i in 400:
				ctx.reply("line %03d: %s" % [i, "x".repeat(20)]),
		"Long output, for the response splitter."
	))
	# A command whose output is one very long line of multi-byte text. Characters
	# are not bytes, and the packet limit is in bytes.
	server.console.register_command(DotConCommand.new(
		"selftest_wide",
		func(ctx: DotCmdContext) -> void:
			ctx.reply("é".repeat(2400)),
		"One long multi-byte line, for the response splitter."
	))

	var expected_long := _run("selftest_long")
	peer.put_data(_rcon_encode(51, RCON_TYPE_EXECCOMMAND, "selftest_long"))
	var long_packets := await _rcon_read(peer, 4, 240)

	_check("long output is split into several packets", long_packets.size() >= 2)

	var joined := ""
	var oversized := 0
	for packet in long_packets:
		if int(packet["size"]) > 4096:
			oversized += 1
		joined += str(packet["body"])
	_check(
		"a split response reassembles to the same text",
		joined.strip_edges() == expected_long.strip_edges()
	)
	_check("no split packet exceeds the protocol limit", oversized == 0)

	var expected_wide := _run("selftest_wide")
	peer.put_data(_rcon_encode(61, RCON_TYPE_EXECCOMMAND, "selftest_wide"))
	var wide_packets := await _rcon_read(peer, 2, 240)

	var wide_joined := ""
	var wide_oversized := 0
	for packet in wide_packets:
		if int(packet["type"]) == -1 or int(packet["size"]) > 4096:
			wide_oversized += 1
			continue
		wide_joined += str(packet["body"])
	_check(
		"a multi-byte response stays within the packet limit",
		wide_oversized == 0
	)
	_check(
		"a multi-byte response reassembles to the same text",
		wide_joined.strip_edges() == expected_wide.strip_edges()
	)


# --- RCON over WebSocket ---------------------------------------------------

## Drives the WebSocket console the way a browser panel would.
##
## This is a second, independent authentication path — the password arrives as the
## first text message rather than inside a binary AUTH packet — on a port that is
## meant to sit behind TLS and be reachable from an admin page. Nothing had ever
## opened it: every earlier test drove either [DotConsole] in-process or the raw
## TCP listener, so the upgrade, the text auth and the text command loop were
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
