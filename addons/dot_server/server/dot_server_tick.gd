@tool
extends "res://addons/dot_server/server/dot_server_sessions.gd"

## The tick, timeout sweep and cvar registration of [DotServer].

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if state != State.RUNNING and state != State.HIBERNATING:
		return

	# Exponential averages rather than a window: two floats, and a heartbeat every two
	# seconds reads them. The 0.05 is about the last twenty frames.
	var ms := delta * 1000.0
	if _frame_ms <= 0.0:
		_frame_ms = ms
	_frame_dev_ms = lerpf(_frame_dev_ms, absf(ms - _frame_ms), 0.05)
	_frame_ms = lerpf(_frame_ms, ms, 0.05)

	_sweep_accum += delta
	if _sweep_accum >= 1.0:
		_sweep_accum = 0.0
		_sweep_timeouts()

	_scoreboard_accum += delta
	if _scoreboard_accum >= scoreboard_interval_sec:
		_scoreboard_accum = 0.0
		_send_scoreboards()


## Drops clients that have been stuck in a stage too long.
##
## Per-stage timeouts: a 400 MB download and an auth reply differ by three orders of magnitude.
func _sweep_timeouts() -> void:
	for session in sessions():
		# A bot sends no packets and finishes no handshake, so every timeout here would
		# fire on one. The host that adopted it decides when it leaves.
		if session.local:
			continue

		var limit := 0.0

		match session.state:
			DotClientSession.State.CONNECTING, DotClientSession.State.AUTHENTICATING:
				limit = config.auth_timeout_sec
			DotClientSession.State.PROFILE:
				limit = config.profile_timeout_sec
			DotClientSession.State.DOWNLOADING:
				limit = config.download_timeout_sec
			DotClientSession.State.LOADING:
				limit = config.load_timeout_sec
			DotClientSession.State.SPAWNED:
				# Spawned clients are judged on silence, not on time in state, except one that announced it
				# was about to go silent (a hidden browser tab runs no frames). The grace is the server's
				# number, clamped on arrival, never the client's.
				if session.idle_seconds() > silence_budget(session):
					kick(
						session,
						"Timed out in the background"
						if session.backgrounded
						else "Timed out"
					)
				continue
			_:
				continue

		if limit > 0.0 and session.time_in_state() > limit:
			DotLog.info(
				CHANNEL,
				"timed out during join",
				{
					"user": session.label(),
					"state": session.state_name(),
					"seconds": int(session.time_in_state()),
					# Who a player stuck in PROFILE was waiting on; empty otherwise.
					"held_by": ", ".join(session.profile_holds),
				}
			)
			# PROFILE is a noun, not something a player is doing; the others read as a
			# sentence already ("Timed out while downloading").
			var stage := (
				"setting up a profile"
				if session.state == DotClientSession.State.PROFILE
				else session.state_name().to_lower()
			)
			kick(session, " ".join(["Timed out while", stage]))


func _register_cvars() -> void:
	console.cheats_cvar = console.cvar(
		"sv_cheats",
		"0",
		"Allow cheat-flagged variables to be changed.",
		DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	_cv_cheats = console.cheats_cvar

	_cv_hostname = console.cvar(
		"hostname",
		config.hostname,
		"Server name shown in listings.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)

	_cv_password = console.cvar(
		"sv_password",
		config.password,
		"Password required to join. Empty for none.",
		DotConVar.FLAG_PROTECTED | DotConVar.FLAG_ARCHIVE
	)

	_register_admission_cvars()
	_register_limit_cvars()

	# Bound onto the console rather than read here: the console is what applies it, on
	# every line, and a console with no server (an editor, a test) still answers from its
	# own exported default.
	console.chat_commands_cvar = console.cvar(
		"sv_chat_commands",
		"1" if config.chat_commands_open else "0",
		"Let a prefixed chat message run any command the speaker has the flag for.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)

	console.cvar("sv_lan", "0", "LAN mode: skip listing and heartbeat.", DotConVar.FLAG_ARCHIVE)
	Cvars.register_query(self)

	# Applying the cvar to the live config keeps the two views from drifting: a
	# reader of config.max_players must not see a stale value after an admin
	# changed sv_maxplayers.
	_cv_maxplayers.changed.connect(
		func(_old: String, value: String) -> void:
			config.max_players = value.to_int()
	)
	_cv_hostname.changed.connect(
		func(_old: String, value: String) -> void:
			config.hostname = value
	)
	_cv_timeout.changed.connect(
		func(_old: String, value: String) -> void:
			config.client_timeout_sec = value.to_float()
	)
	_cv_background_grace.changed.connect(
		func(_old: String, value: String) -> void:
			config.background_grace_max_sec = value.to_float()
	)

	# Live rather than startup-only: hibernating is a state the server moves in and out of
	# all day, and an operator switching it off wants the empty server's clock running now,
	# not after a restart.
	console.cvar(
		"sv_hibernate_when_empty",
		"1" if config.hibernate_when_empty else "0",
		"Idle at a reduced tickrate while nobody is connected; the map's clocks wait, and restart when somebody joins. 0 keeps an empty server running, and its map changes on its own.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).changed.connect(
		func(_old: String, value: String) -> void:
			if state == State.RUNNING or state == State.HIBERNATING:
				_apply_hibernate_setting(value.to_int() != 0)
			else:
				config.hibernate_when_empty = value.to_int() != 0
	)
	Cvars.register_threads(self)


func _register_admission_cvars() -> void:
	# Which kinds of client may join, all on by default (cross-play is the platform's default;
	# these are an owner's opt-out). REPLICATED so a listing can say which are open.
	_cv_single_seat = console.cvar(
		"sv_single_seat", "1",
		"One connection per account: signing in again replaces the older connection.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)

	_cv_allow_web = console.cvar(
		"sv_allow_web", "1",
		"Admit players in a web browser.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	_cv_allow_desktop = console.cvar(
		"sv_allow_desktop", "1",
		"Admit players on the desktop client (Windows, macOS, Linux).",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	_cv_allow_mobile = console.cvar(
		"sv_allow_mobile", "1",
		"Admit players on a phone or tablet.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)


func _register_limit_cvars() -> void:
	_cv_maxplayers = console.cvar(
		"sv_maxplayers",
		str(config.max_players),
		"Player slots.",
		DotConVar.FLAG_ARCHIVE
	).with_range(1, 4096)

	# Live, applied at a boundary. Before the listener it applies at once (server.cfg and
	# `+sv_tickrate` are unchanged); after it the value waits for the game's next boundary,
	# see [method apply_pending_tickrate].
	_cv_tickrate = console.cvar(
		"sv_tickrate",
		str(config.tickrate),
		"Server ticks per second. Set while running, it applies at the next map change.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	).with_range(10, 240)
	_cv_tickrate.changed.connect(
		func(_old: String, value: String) -> void:
			var rate := value.to_int()
			if state != State.RUNNING and state != State.HIBERNATING:
				config.tickrate = rate
				return
			_pending_tickrate = rate if rate != config.tickrate else -1
			if _pending_tickrate > 0:
				DotLog.info(CHANNEL, "tickrate change waiting for the next map change",
					{"now": config.tickrate, "next": rate})
				tickrate_pending.emit(rate)
	)

	_cv_timeout = console.cvar(
		"sv_timeout",
		str(config.client_timeout_sec),
		"Seconds of silence before a client is dropped.",
		DotConVar.FLAG_ARCHIVE
	).with_range(5, 600)

	_cv_background_grace = console.cvar(
		"sv_background_grace",
		str(config.background_grace_max_sec),
		"Seconds of silence allowed a client that says its tab is hidden. 0 refuses.",
		DotConVar.FLAG_ARCHIVE
	).with_range(0, 1800)


## Reads cvars back into the config after server.cfg has run.
func _apply_cvars_to_config() -> void:
	config.hostname = _cv_hostname.get_string()
	config.password = _cv_password.get_string()
	config.max_players = _cv_maxplayers.get_int()
	config.tickrate = _cv_tickrate.get_int()
	config.client_timeout_sec = _cv_timeout.get_float()
	config.background_grace_max_sec = _cv_background_grace.get_float()
	config.reserved_slots = console.get_int("sv_reserved_slots", config.reserved_slots)
	config.max_connections_per_ip = console.get_int(
		"sv_max_connections_per_ip", config.max_connections_per_ip
	)
	config.query_enabled = console.get_bool("sv_query", config.query_enabled)
	config.a2s_enabled = console.get_bool("sv_a2s", config.a2s_enabled)
	config.query_player_detail = console.get_string(
		"sv_query_players", config.query_player_detail
	)
	config.hibernate_when_empty = console.get_bool(
		"sv_hibernate_when_empty", config.hibernate_when_empty
	)
	config.worker_threads = console.get_int("sv_worker_threads", config.worker_threads)
	config.threads_net = console.get_bool("sv_threads_net", config.threads_net)
	config.threads_npc = console.get_bool("sv_threads_npc", config.threads_npc)
	config.net_native = console.get_bool("net_native", config.net_native)
	config.net_native_interest = console.get_bool("net_native_interest", config.net_native_interest)


func _register_commands() -> void:
	DotBuiltinCommands.register_all(self, console)
