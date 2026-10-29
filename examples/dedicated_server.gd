extends "res://examples/selftest/dedicated_tests_d.gd"

## Boots a dedicated server and exercises the console, admin and moderation paths, headless with no clients.
## Covers cvar flags, permissions, config execution, the command buffer, bans, votes, modules and the audit trail.
## Exits non-zero if any check fails, so it works as a CI smoke test.

func _ready() -> void:
	DotLog.set_level(DotLog.Level.INFO)
	DotLog.timestamps = true

	var config := _make_config()

	# A self-test starts from nothing in user://example: the ban list, audit log and admin file are read
	# back at boot, so a stale permanent ban or a huge audit log would carry over. Not when serving. See docs/testing.md.
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

func _make_config() -> DotServerConfig:
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

	# No boot configs: the addon's default server.cfg (sv_maxplayers 32 and more) would be found and the
	# self-test would assert against its contents. Config execution is tested in _test_config_files().
	config.startup_config = ""
	config.autoexec_config = ""
	return config

func _should_selftest() -> bool:
	# Default to self-testing when headless with no arguments, so the scene is
	# useful as a smoke test without anyone remembering a flag.
	var args := OS.get_cmdline_user_args()
	if args.has(SELFTEST_ARG):
		return true
	if args.has("--serve"):
		return false
	return DotPlatform.is_headless()


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
