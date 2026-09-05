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
var _passed := 0
var _failed := 0


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
	_test_cvar_flags()
	_test_permissions()
	_test_config_files()
	await _test_command_buffer()
	await _test_bans()
	_test_admins()
	_test_connection_limits()
	_test_targeting()
	await _test_ban_source()
	_test_events()
	_test_query()
	_test_query_protocol()
	_test_a2s()
	_test_guest_identity()
	await _test_modules()
	_test_audit()
	_test_rcon_allow_list()
	await _test_rcon_socket()
	await _test_rcon_websocket()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	server.shutdown("self-test complete")
	get_tree().quit(1 if _failed > 0 else 0)


func _test_console() -> void:
	print("[console]")
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


func _test_cvar_flags() -> void:
	print("")
	print("[cvar flags]")
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


func _test_permissions() -> void:
	print("")
	print("[permissions]")
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

	# A command that opted out of chat must be unreachable from chat.
	var chat_ctx := _client_context(PackedStringArray([DotAdminFlags.ROOT]))
	chat_ctx.source = DotCmdContext.Source.CHAT
	var chat_res := console.execute("writeconfig", chat_ctx)
	_check(
		"non-chat command refused from chat",
		not chat_res.ok and chat_res.code() == DotError.CODE_FORBIDDEN
	)

	# And one that opted in must be reachable.
	var chat_ok := console.execute("whoami", chat_ctx)
	_check("chat-allowed command works from chat", chat_ok.ok)


func _test_config_files() -> void:
	print("")
	print("[config files]")
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


func _test_command_buffer() -> void:
	print("")
	print("[command buffer]")
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


func _test_bans() -> void:
	print("")
	print("[bans]")
	var bans := server.bans

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


func _test_connection_limits() -> void:
	print("")
	print("[per-address connection limit]")

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


func _test_targeting() -> void:
	print("")
	print("[targeting a player]")

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


func _test_ban_source() -> void:
	print("")
	print("[an external ban list: dot-moderation]")

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
	print("[admins]")
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


func _test_events() -> void:
	print("")
	print("[events]")
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


## The identity used when dot-auth is absent.
##
## Only reached in that configuration, which is exactly why it needs a test — a
## server with dot-auth installed never touches it, so a break here would surface
## only for the people running the simplest setup.
func _test_guest_identity() -> void:
	print("")
	print("[guest identity]")

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


func _test_modules() -> void:
	print("")
	print("[modules]")

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

	var loaded := server.modules.load_module("user://example/modules/example.gd")
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
		not server.modules.load_module("user://example/bad_module.gd").ok
	)


func _test_audit() -> void:
	print("")
	print("[audit]")
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


# --- Query -----------------------------------------------------------------

func _test_query() -> void:
	print("")
	print("[query snapshot]")

	var source := server.query_source
	_check("query source exists", source != null)
	if source == null:
		return

	_check("query listener bound", server.query != null and server.query.is_listening())
	# A2S shares that socket rather than binding its own, because both default to
	# the same port and two listeners cannot have one.
	_check("a2s attached to the query socket",
		server.a2s != null and not server.a2s.is_listening())
	_check("a2s shares the challenge secret",
		server.a2s != null and server.a2s.challenge == server.query.challenge)

	var snap := source.snapshot(true)
	_check("info has a name", str(snap.info.get("name", "")) != "")
	_check("info counts slots", int(snap.info.get("max_players", 0)) > 0)
	_check("info separates connecting from playing",
		snap.info.has("connecting") and snap.info.has("players"))
	_check("info advertises the dot protocol", snap.info.has("query"))

	# The revision must not move when nothing did, or conditional polling — the
	# whole point of it — never saves a byte. Uptime advances between these two
	# rebuilds, which is exactly the field that must not count as a change.
	var rev_before := source.snapshot(true).rev
	var rev_again := source.snapshot(true).rev
	_check("revision stable when nothing changed", rev_before == rev_again)

	_run("hostname \"Renamed For The Test\"")
	var rev_after := source.snapshot(true).rev
	_check("revision moves when something changed", rev_after > rev_again)
	_check("live cvar beats the boot config",
		str(source.snapshot(true).info.get("name", "")) == "Renamed For The Test")

	# Rules come from the console, and the flags decide what may leave the server.
	var rules: Dictionary = source.snapshot(true).rules
	_check("rules publish a notify cvar", rules.has("sv_cheats"))
	_check("rules never publish a protected cvar", not rules.has("sv_password"))

	server.config.query_extra_rules = PackedStringArray(["sv_password"])
	_check("naming a protected cvar does not publish it",
		not source.snapshot(true).rules.has("sv_password"))
	server.config.query_extra_rules = PackedStringArray()

	# Player policy.
	_run("sv_query_players none")
	_check("player list refused at 'none'", source.snapshot(true).players.is_empty())
	_run("sv_query_players nonsense")
	_check("an invalid player policy is refused",
		source.player_detail() == "none")
	_run("sv_query_players full")
	_check("player policy restored", source.player_detail() == "full")

	# A provider is the only thing that can know a bot count, and it must reach the
	# backbone stats report as well as the query response.
	var provider := ExampleQueryProvider.new()
	provider.bots = 3
	var added := source.add_provider(provider)
	_check("provider registered", added.ok)
	_check("registering the same provider twice is refused",
		not source.add_provider(provider).ok)
	_check("a non-provider is refused", not source.add_provider(RefCounted.new()).ok)

	var contributed := source.snapshot(true)
	_check("provider contributes a game section",
		str(contributed.game.get("phase", "")) == "warmup")
	_check("provider corrects the bot count", contributed.bot_count() == 3)
	_check("bot count reaches the stats report",
		int(server.to_stats_report().get("bots", -1)) == 3)
	var report := server.to_stats_report()
	_check("a report between games says null for the map, which the backbone accepts and \"\" is not",
		report.has("map") and (report["map"] == null or (report["map"] is String and report["map"] != "")))
	for key in ["online", "curUsers", "maxUsers", "bots", "password", "dedicated", "version"]:
		_check("the report carries `%s` as IngestServerStatsInput spells it" % key, report.has(key))

	source.remove_provider(provider)
	_check("provider removed", source.snapshot(true).game.is_empty())

	# Signing is off unless a secret is configured, and a signature nobody checks
	# is cost with no benefit.
	_check("unsigned by default", not source.sign({"a": 1}).has("auth"))
	server.config.query_secret = "example-query-secret"
	var signed := source.sign({"a": 1})
	_check("signed when a secret is set", signed.has("auth"))
	_check("signature carries a timestamp and nonce",
		(signed["auth"] as Dictionary).has("ts")
		and (signed["auth"] as Dictionary).has("nonce"))
	server.config.query_secret = ""


func _test_query_protocol() -> void:
	print("")
	print("[dot query protocol]")

	var query := server.query
	if query == null:
		_check("query listener present", false)
		return

	var address := "198.51.100.7"
	var port := 41000

	# An unchallenged query is answered with a cookie and nothing else. That reply
	# is smaller than the request, which is what makes the protocol useless as an
	# amplifier.
	var unchallenged := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_QUERY, 1, 0, {"sections": ["info", "players"]}
	)
	var replies := query.handle_datagram(unchallenged, address, port)
	_check("an unchallenged query gets a challenge", replies.size() == 1)

	var challenge_packet := DotQueryProtocol.parse(replies[0])
	_check("challenge parses", challenge_packet.ok)
	var cookie := int((challenge_packet.value as Dictionary)["challenge"])
	_check("challenge is not zero", cookie != 0)
	_check("the challenge reply is smaller than the request",
		replies[0].size() < unchallenged.size())

	# The cookie is bound to the address it was mailed to, so a forger who guessed
	# somebody else's address cannot use one issued to them.
	_check("a cookie is refused from another address",
		not query.challenge.verify("198.51.100.9", port, cookie))
	_check("a cookie is refused from another port",
		not query.challenge.verify(address, port + 1, cookie))
	_check("a cookie is accepted from its own address",
		query.challenge.verify(address, port, cookie))

	var challenged := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_QUERY, 2, cookie, {"sections": ["info", "players"]}
	)
	var answer := query.handle_datagram(challenged, address, port)
	_check("a challenged query is answered", answer.size() >= 1)

	var body := DotQueryProtocol.reassemble(answer)
	_check("the answer reassembles", body.ok)

	var result: Dictionary = body.value
	_check("the answer echoes the transaction",
		int((DotQueryProtocol.parse(answer[0]).value as Dictionary)["txn"]) == 2)
	_check("the answer carries the info section",
		(result.get("sections", {}) as Dictionary).has("info"))
	_check("the answer carries only what was asked for",
		not (result.get("sections", {}) as Dictionary).has("rules"))

	# Conditional polling: a querier holding the current revision gets told so.
	var rev := int(result.get("rev", 0))
	var conditional := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_QUERY, 3, cookie, {"if_rev": rev}
	)
	var unchanged := DotQueryProtocol.reassemble(
		query.handle_datagram(conditional, address, port)
	)
	_check("a matching revision replies 'unchanged'",
		unchanged.ok and bool((unchanged.value as Dictionary).get("unchanged", false)))
	_check("the unchanged reply is one small datagram",
		query.handle_datagram(conditional, address, port)[0].size() < 200)

	# An unknown section is reported rather than dropped, or a querier who
	# misspelled one concludes the server has no players.
	var misspelled := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_QUERY, 4, cookie, {"sections": ["playerz"]}
	)
	var reported := DotQueryProtocol.reassemble(
		query.handle_datagram(misspelled, address, port)
	)
	_check("an unknown section is reported",
		reported.ok and (reported.value as Dictionary).has("unknown"))

	# A response arriving on the listening socket is never answered: doing so is
	# how a server becomes one leg of a reflection loop between two servers.
	var reflected := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_RESULT, 5, cookie, {}
	)
	_check("a response is not answered",
		query.handle_datagram(reflected, address, port).is_empty())
	_check("a non-DQP datagram is ignored",
		query.handle_datagram(
			"hello".to_utf8_buffer(), address, port
		).is_empty())

	var oversized := PackedByteArray()
	oversized.resize(DotQueryProtocol.MAX_REQUEST_BYTES + 1)
	_check("an oversized request is ignored",
		query.handle_datagram(oversized, address, port).is_empty())

	# Ping is answered without a challenge because the reply is smaller than the
	# request; there is nothing to amplify.
	var ping := DotQueryProtocol.build_request(DotQueryProtocol.TYPE_PING, 6, 0)
	var pong := query.handle_datagram(ping, address, port)
	_check("ping is answered",
		pong.size() == 1
		and int((DotQueryProtocol.parse(pong[0]).value as Dictionary)["type"])
			== DotQueryProtocol.TYPE_PONG)

	# Fragmentation and compression, round-tripped without a socket.
	var big := {"filler": []}
	for i in range(400):
		(big["filler"] as Array).append("entry-%d-padding-padding-padding" % i)

	# The request flag says "I can decompress a reply"; the response flag says "this
	# payload is compressed". Sharing one bit made the header unparseable without
	# already knowing which direction the packet was going.
	_check("a request advertises gzip without claiming to be gzipped",
		(DotQueryProtocol.parse(DotQueryProtocol.build_request(
			DotQueryProtocol.TYPE_QUERY, 9, cookie, {}, true
		)).value as Dictionary)["flags"] == DotQueryProtocol.FLAG_ACCEPT_GZIP)

	var claims_gzip := DotQueryProtocol.build(
		DotQueryProtocol.TYPE_QUERY, 10, cookie,
		"not actually gzip".to_utf8_buffer(), DotQueryProtocol.FLAG_GZIP
	)[0]
	_check("a request claiming to be compressed is refused",
		not DotQueryProtocol.parse(claims_gzip).ok)

	var plain := DotQueryProtocol.encode_body(big, false)
	_check("a large body is not compressed when gzip is not accepted",
		int(plain[1]) == 0)
	var fragments := DotQueryProtocol.build(
		DotQueryProtocol.TYPE_RESULT, 7, 0, plain[0] as PackedByteArray,
		int(plain[1]), 99
	)
	_check("a large body fragments", fragments.size() > 1)
	_check("every fragment carries the whole header",
		fragments[fragments.size() - 1].size() > DotQueryProtocol.HEADER_BYTES)

	var shuffled := fragments.duplicate()
	shuffled.reverse()
	var rebuilt := DotQueryProtocol.reassemble(shuffled)
	_check("fragments reassemble out of order",
		rebuilt.ok and (rebuilt.value as Dictionary).has("filler"))

	var missing := fragments.duplicate()
	missing.remove_at(1)
	_check("a missing fragment is a failure, not a partial body",
		not DotQueryProtocol.reassemble(missing).ok)

	var gzipped := DotQueryProtocol.encode_body(big, true)
	_check("a large body compresses when gzip is accepted",
		int(gzipped[1]) & DotQueryProtocol.FLAG_GZIP)
	_check("compression actually shrinks it",
		(gzipped[0] as PackedByteArray).size() < (plain[0] as PackedByteArray).size())
	var inflated := DotQueryProtocol.reassemble(DotQueryProtocol.build(
		DotQueryProtocol.TYPE_RESULT, 8, 0, gzipped[0] as PackedByteArray,
		int(gzipped[1]), 100
	))
	_check("a compressed body reassembles",
		inflated.ok and (inflated.value as Dictionary).has("filler"))

	# Rate limiting, from an address no other check has spent tokens for.
	var flooder := "203.0.113.200"
	var flood_port := 42000
	var flood_cookie := query.challenge.issue(flooder, flood_port)
	var refused := 0
	for i in range(40):
		var req := DotQueryProtocol.build_request(
			DotQueryProtocol.TYPE_QUERY, 100 + i, flood_cookie
		)
		if query.handle_datagram(req, flooder, flood_port).is_empty():
			refused += 1
	_check("a flood from one address is rate limited", refused > 0)

	# Turning it off stops answers without closing the socket, so it can be turned
	# back on without the port moving under whatever was polling it.
	_run("sv_query 0")
	_check("sv_query 0 stops answering",
		query.handle_datagram(challenged, address, port).is_empty())
	_check("sv_query 0 leaves the socket open", query.is_listening())
	_run("sv_query 1")
	_check("sv_query 1 resumes answering",
		not query.handle_datagram(challenged, address, port).is_empty())


func _test_a2s() -> void:
	print("")
	print("[a2s]")

	var query := server.query
	var a2s := server.a2s
	if a2s == null or query == null:
		_check("a2s present", false)
		return

	var address := "198.51.100.20"
	var port := 43000

	# Sent to the query listener, because that is what owns the socket. The two
	# protocols are told apart by their first four bytes.
	var info_request := _a2s_request(DotA2SServer.REQUEST_INFO, true, 0)
	var challenge_reply := query.handle_datagram(info_request, address, port)
	_check("A2S_INFO without a challenge gets one", challenge_reply.size() == 1)

	var reader := _A2SReader.new(challenge_reply[0])
	_check("the challenge is a single-packet response", reader.single())
	_check("the challenge has the 'A' header",
		reader.u8() == DotA2SServer.RESPONSE_CHALLENGE)

	var cookie := reader.u32()
	_check("the A2S challenge is not the reserved sentinel", cookie != 0xFFFFFFFF)
	_check("the A2S challenge is address-bound",
		not a2s.challenge.verify_a2s("198.51.100.21", port, cookie))

	var info_reply := query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_INFO, true, cookie), address, port
	)
	_check("A2S_INFO with a challenge is answered", info_reply.size() == 1)

	var info := _A2SReader.new(info_reply[0])
	_check("info is a single-packet response", info.single())
	_check("info has the 'I' header", info.u8() == DotA2SServer.RESPONSE_INFO)
	_check("info reports protocol 17", info.u8() == 17)
	_check("info carries the live hostname", info.cstring() == "Renamed For The Test")
	info.cstring()  # map
	_check("info carries the game folder", info.cstring() == "dotexample")
	info.cstring()  # game description
	_check("info carries the app id", info.u16() == 4242)
	info.u8()       # players
	_check("info carries the slot count", info.u8() == server.config.max_players)
	_check("info carries the bot count", info.u8() == 0)
	_check("info reports a dedicated server", info.u8() == 0x64)
	info.u8()       # os
	_check("info reports no password", info.u8() == 0)
	info.u8()       # vac
	_check("info carries the version", info.cstring() == DotServer.VERSION)

	var edf := info.u8()
	_check("info sets the port extra-data flag", (edf & DotA2SServer.EDF_PORT) != 0)
	info.u16()      # port
	_check("info sets the keywords flag", (edf & DotA2SServer.EDF_KEYWORDS) != 0)
	var keywords := info.cstring()
	_check("keywords carry the server tags", keywords.contains("example"))
	# The one extensible field A2S has, used to point a tracker at the protocol
	# that will actually tell it something.
	_check("keywords advertise the dot query port", keywords.contains("dqp:"))
	_check("info was read exactly to its end", info.at_end())

	# A packet claiming to be A2S_INFO without the fixed string is not one.
	_check("a malformed A2S_INFO is ignored",
		query.handle_datagram(
			_a2s_request(DotA2SServer.REQUEST_INFO, false, cookie), address, port
		).is_empty())

	# PLAYER and RULES have always been challenged.
	# 0xFFFFFFFF is what a real client sends to mean "I have no challenge", and it
	# must never match: every cookie has its top bit cleared, so it cannot be this.
	_check("A2S_PLAYER without a challenge gets one",
		_A2SReader.new(query.handle_datagram(
			_a2s_request(DotA2SServer.REQUEST_PLAYER, false, 0xFFFFFFFF),
			address, port
		)[0]).skip(4).u8() == DotA2SServer.RESPONSE_CHALLENGE)

	var players := _A2SReader.new(query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_PLAYER, false, cookie), address, port
	)[0])
	_check("A2S_PLAYER is answered", players.single())
	_check("player response has the 'D' header",
		players.u8() == DotA2SServer.RESPONSE_PLAYER)
	_check("player response counts nobody on an empty server", players.u8() == 0)

	var rules := _A2SReader.new(query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_RULES, false, cookie), address, port
	)[0])
	_check("A2S_RULES is answered", rules.single())
	_check("rules response has the 'E' header",
		rules.u8() == DotA2SServer.RESPONSE_RULES)

	var rule_count := rules.u16()
	_check("rules response lists rules", rule_count > 0)
	var leaked := false
	for i in range(rule_count):
		if rules.cstring() == "sv_password":
			leaked = true
		rules.cstring()
	_check("rules never include a protected cvar", not leaked)
	_check("rules response was read exactly to its end", rules.at_end())

	var ping := _A2SReader.new(query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_PING, false, -1), address, port
	)[0])
	_check("A2A_PING is answered",
		ping.single() and ping.u8() == DotA2SServer.RESPONSE_PING)

	_run("sv_a2s 0")
	_check("sv_a2s 0 stops answering",
		query.handle_datagram(
			_a2s_request(DotA2SServer.REQUEST_INFO, true, cookie), address, port
		).is_empty())
	_run("sv_a2s 1")
	_check("the dot protocol still answers while A2S is off",
		not query.handle_datagram(
			DotQueryProtocol.build_request(
				DotQueryProtocol.TYPE_CHALLENGE_REQUEST, 1, 0
			), address, port
		).is_empty())


## Builds an A2S request. [param challenge] of -1 appends nothing.
func _a2s_request(request: int, with_payload: bool, challenge: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(5)
	out.encode_u32(0, DotA2SServer.HEADER_SINGLE)
	out.encode_u8(4, request)

	if with_payload:
		out.append_array(DotA2SServer.INFO_PAYLOAD.to_utf8_buffer())
		out.append(0)

	if challenge >= 0:
		var tail := PackedByteArray()
		tail.resize(4)
		tail.encode_u32(0, challenge)
		out.append_array(tail)

	return out


## Reads an A2S response the way a real client would, so the encoding is checked
## field by field rather than by its length.
class _A2SReader extends RefCounted:
	var data: PackedByteArray
	var offset: int = 0

	func _init(p_data: PackedByteArray) -> void:
		data = p_data

	## Consumes the single-packet header.
	func single() -> bool:
		if data.size() < 4:
			return false
		offset = 4
		return data.decode_u32(0) == DotA2SServer.HEADER_SINGLE

	func skip(n: int) -> _A2SReader:
		offset += n
		return self

	func u8() -> int:
		var v := data.decode_u8(offset)
		offset += 1
		return v

	func u16() -> int:
		var v := data.decode_u16(offset)
		offset += 2
		return v

	func u32() -> int:
		var v := data.decode_u32(offset)
		offset += 4
		return v

	func cstring() -> String:
		var start := offset
		while offset < data.size() and data.decode_u8(offset) != 0:
			offset += 1
		var text := data.slice(start, offset).get_string_from_utf8()
		offset += 1
		return text

	func at_end() -> bool:
		return offset == data.size()


## A provider standing in for a game, so the plug-in point is exercised.
class ExampleQueryProvider extends DotQueryProvider:
	var bots: int = 0

	func _provider_name() -> String:
		return "example"

	func _contribute(snapshot: DotQuerySnapshot) -> void:
		snapshot.info["bots"] = bots
		snapshot.contribute_game({"phase": "warmup", "round": 1})


# --- Helpers ---------------------------------------------------------------

## Runs a command as the local console and returns its output.
func _run(line: String) -> String:
	var lines := PackedStringArray()
	var ctx := DotCmdContext.console("", PackedStringArray())
	ctx.reply_sink = func(text: String) -> void: lines.append(text)
	server.console.execute(line, ctx)
	return "\n".join(lines)


## A context that looks like a client, for permission tests.
func _client_context(permissions: PackedStringArray) -> DotCmdContext:
	var ctx := DotCmdContext.new()
	ctx.source = DotCmdContext.Source.RCON
	ctx.permissions = permissions
	ctx.immunity = 10
	ctx.address = "203.0.113.1"
	ctx.reply_sink = func(_text: String) -> void: pass
	return ctx


func _test_rcon_allow_list() -> void:
	print("[rcon allow-list]")

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
	print("[rcon over a socket]")

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
	print("[rcon over websocket]")

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
