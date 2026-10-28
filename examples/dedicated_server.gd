extends "res://examples/selftest/dedicated_tests_b.gd"

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
	_test_platforms()
	_test_hibernation()
	_test_game_ids()
	_test_targeting()
	await _test_ban_source()
	_test_events()
	_test_chat_state()
	_test_notices()
	_test_chat_commands()
	_test_guest_identity()
	await _test_modules()
	await _test_bot_quota()
	_test_audit()
	await _test_rcon_allow_list()
	await _test_rcon_socket()
	await _test_rcon_websocket()
	# Last: a second DotServer replaces the first's registry entries, and every section above
	# that looks a subsystem up by name would be talking to the wrong server.
	await _test_boot_hibernation()

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

	# Startup-only cvars are locked once the server is listening. sv_tickrate was the
	# example here until it became live (2026-10-07), and it was the only one, so the
	# flag gets a cvar of its own -- a flag nothing exercises is a flag that can break.
	var startup := console.cvar("test_startup_only", "1", "", DotConVar.FLAG_STARTUP_ONLY)
	var refused := _run("test_startup_only 2")
	_check(
		"startup-only refused while running",
		startup.get_int() == 1 and refused.contains("only be changed")
	)

	# ...and settable before it is, which is the half that makes the flag mean
	# "startup" rather than "never". `server.cfg` is exec'd before the listener for
	# exactly this, and so is the CVAR half of the command line.
	console.set_server_running(false)
	_run("test_startup_only 2")
	_check("startup-only settable before the server runs", startup.get_int() == 2)
	console.set_server_running(true)

	# [b]sv_tickrate is live, and waits for a boundary.[/b] Set while running, nothing
	# moves -- not the engine, not the config -- until the game calls
	# apply_pending_tickrate (at its map change) or the next game change does.
	var playing := server.tickrate()
	var engine_before := Engine.physics_ticks_per_second
	var announced: Array[int] = []
	var on_pending := func(rate: int) -> void: announced.append(rate)
	server.tickrate_pending.connect(on_pending)
	var set_reply := _run("sv_tickrate %d" % (playing + 4))
	_check("sv_tickrate is accepted while running", not set_reply.contains("only be changed"))
	_check("and nothing changes yet", server.tickrate() == playing
		and Engine.physics_ticks_per_second == engine_before)
	_check("it is held as pending, and said so", server.pending_tickrate() == playing + 4
		and announced == [playing + 4])
	_check("stats says what is waiting", _run("stats").contains("at the next map change"))
	var changed: Array[int] = []
	var on_changed := func(rate: int) -> void: changed.append(rate)
	server.tickrate_changed.connect(on_changed)
	_check("the boundary applies it", server.apply_pending_tickrate()
		and server.tickrate() == playing + 4 and changed == [playing + 4]
		and server.pending_tickrate() == -1)
	_check("and the engine follows unless the server is hibernating",
		server.is_hibernating() or Engine.physics_ticks_per_second == playing + 4)
	_check("a second boundary with nothing waiting changes nothing",
		not server.apply_pending_tickrate())
	_run("sv_tickrate %d" % (playing + 8))
	_run("sv_tickrate %d" % (playing + 4))
	_check("setting it back to the playing rate cancels what was waiting",
		server.pending_tickrate() == -1)
	_run("sv_tickrate %d" % playing)
	server.apply_pending_tickrate()
	_check("and it goes back", server.tickrate() == playing)
	server.tickrate_pending.disconnect(on_pending)
	server.tickrate_changed.disconnect(on_changed)

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

	# Group NAMES are kept, not only merged into flags: a game grants things by role, and a
	# role is a group name. They used to be read, used, and dropped.
	var _vip := admins.set_admin(
		"backbone:carol", PackedStringArray(), 0, PackedStringArray(["vip"]), "Carol"
	)
	_check(
		"a player's admin groups are known by name",
		Array(admins.uid_permissions("backbone:carol").get("groups", [])).has("vip")
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

	# Both tables shrink once the window has passed: a refilled bucket is dropped by time
	# (it is stored at 0 tokens, which used to keep it forever) and the counts go with it.
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
