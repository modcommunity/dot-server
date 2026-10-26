extends RefCounted
## The cvars [DotServer] registers that only write through to its config: the thread opt-ins
## and the query and connection-limit settings. Split out of the server to keep it small.


## Live; the game wiring reads the config each snapshot or tick, so writing it is all applying is.
static func register_threads(server: DotServer) -> void:
	server.console.cvar(
		"sv_worker_threads", str(server.config.worker_threads),
		"Worker threads each threaded subsystem may use. -1 automatic (cores less one, at most 8; set it when several servers share a machine), 0 runs everything on the main thread.",
		DotConVar.FLAG_ARCHIVE
	).with_range(-1, 64).changed.connect(
		func(_old: String, value: String) -> void:
			server.config.worker_threads = value.to_int()
	)
	server.console.cvar(
		"sv_threads_net", "1" if server.config.threads_net else "0",
		"Build each player's snapshot on worker threads (sv_worker_threads of them).",
		DotConVar.FLAG_ARCHIVE
	).changed.connect(
		func(_old: String, value: String) -> void:
			server.config.threads_net = value.to_int() != 0
	)
	server.console.cvar(
		"sv_threads_npc", "1" if server.config.threads_npc else "0",
		"Run NPC decisions and path searches on worker threads, for brains that support it.",
		DotConVar.FLAG_ARCHIVE
	).changed.connect(
		func(_old: String, value: String) -> void:
			server.config.threads_npc = value.to_int() != 0
	)
	server.console.cvar(
		"net_native", "1" if server.config.net_native else "0",
		"Build snapshots in dot-net's native library (same bytes; GDScript if it cannot load).",
		DotConVar.FLAG_ARCHIVE
	).changed.connect(
		func(_old: String, value: String) -> void:
			server.config.net_native = value.to_int() != 0
	)
	server.console.cvar(
		"net_native_interest", "1" if server.config.net_native_interest else "0",
		"With net_native, also pick each peer's relevant entities in the native library (GDScript for a strategy it cannot port).",
		DotConVar.FLAG_ARCHIVE
	).changed.connect(
		func(_old: String, value: String) -> void:
			server.config.net_native_interest = value.to_int() != 0
	)


## The query protocols, reserved slots and the per-address limit.
static func register_query(server: DotServer) -> void:
	# Registered before server.cfg runs so a server.cfg file can set them; at runtime they stop
	# the listener answering rather than closing its socket.
	server.console.cvar(
		"sv_query",
		"1" if server.config.query_enabled else "0",
		"Answer dot query protocol requests.",
		DotConVar.FLAG_ARCHIVE
	)

	server.console.cvar(
		"sv_a2s",
		"1" if server.config.a2s_enabled else "0",
		"Answer A2S query requests.",
		DotConVar.FLAG_ARCHIVE
	)

	server.console.cvar(
		"sv_query_players",
		server.config.query_player_detail,
		"How much of the player list a query may see: full, names, count or none.",
		DotConVar.FLAG_ARCHIVE
	).with_validator(
		func(value: String) -> DotResult:
			if ["full", "names", "count", "none"].has(value):
				return DotResult.success(value)
			return DotResult.fail(
				DotError.CODE_INVALID,
				"sv_query_players must be full, names, count or none.",
				"got '%s'" % value
			)
	)

	server.console.cvar(
		"sv_reserved_slots",
		str(server.config.reserved_slots),
		"Slots kept for players with the reservation flag.",
		DotConVar.FLAG_ARCHIVE
	).with_range(0, 64)

	# Live: a limit that needs a restart arrives after the server has already been filled.
	server.console.cvar(
		"sv_max_connections_per_ip",
		str(server.config.max_connections_per_ip),
		"Simultaneous connections allowed from one address. 0 for no limit.",
		DotConVar.FLAG_ARCHIVE
	).with_range(0, 64).changed.connect(
		func(_old: String, value: String) -> void:
			server.config.max_connections_per_ip = value.to_int()
			if server.address_guard != null:
				server.address_guard.limit = value.to_int()
	)
