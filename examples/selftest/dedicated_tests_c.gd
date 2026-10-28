extends "res://examples/selftest/dedicated_tests_b.gd"

## Cvar, permission, ban and admin sections of dedicated_server.gd.

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

	# Startup-only cvars lock once the server is listening. No real cvar is left with the
	# flag, so this one has its own: an unexercised flag is one that can break.
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

	_test_cvar_tickrate()

func _test_cvar_tickrate() -> void:
	var console := server.console
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

	_test_permissions_chat()

func _test_permissions_chat() -> void:
	var console := server.console
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

	_test_connection_limits_server()

func _test_connection_limits_server() -> void:
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

	# Loaded by path and called by duck typing: naming DotModerationManager would fail to
	# parse in a checkout without the addon.
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

	await _test_ban_source_admission(manager, banned)

func _test_ban_source_admission(manager: Object, banned: Variant) -> void:
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

	await _test_ban_source_broken(manager, good)

func _test_ban_source_broken(manager: Object, good: DotClientSession) -> void:
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

	# A uid answered by a SOURCE rather than the admin file: a table keyed by uid needs no
	# connection, and a deployment whose admins live in config depends on it for relayed commands.
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

	_test_admins_groups()

func _test_admins_groups() -> void:
	var admins := server.admins
	# Group NAMES are kept, not only merged into flags: a game grants things by role.
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
