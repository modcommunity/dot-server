@tool
class_name DotServer
extends "res://addons/dot_server/server/dot_server_tick.gd"

## The dedicated server. Place one in a scene and it boots.
##
## Owns the listener, the session table, the signon flow, the tick budget, and the
## subsystems — console, admins, bans, audit, RCON, chat, votes, games. Every
## subsystem is reached through a [DotNodeRef], so a host project can place them
## itself, point at ones it already has, or let this create them.
##
## [codeblock]
## var server := DotServer.new()
## server.config = my_config
## add_child(server)
## await server.boot()
## [/codeblock]
##
## [b]Boot order matters and is fixed.[/b] Config, then console and cvars, then
## [code]server.cfg[/code] (which may change any startup cvar), then the subsystems,
## then the listener, then [code]autoexec.cfg[/code], then
## [code]+command[/code] arguments. A cvar marked
## [constant DotConVar.FLAG_STARTUP_ONLY] is settable up to the point the listener
## opens and refused afterwards, which is why the config runs before it.
##
## Registers itself as [code]dot_server[/code] in [DotRegistry].

func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if auto_boot:
		await boot()


## Brings the server up. Idempotent.
func boot() -> DotResult:
	if state != State.IDLE and state != State.STOPPED:
		return DotResult.fail(
			DotError.CODE_STATE, "The server is already running."
		)

	_set_state(State.BOOTING)
	var configured := _load_boot_config()
	if not configured.ok:
		return _boot_failed(configured)

	DotRegistry.register(SERVICE, self)

	_resolve_log_sink()

	DotLog.info(
		CHANNEL,
		"booting",
		{
			"hostname": config.hostname,
			"port": config.port,
			"slots": config.max_players,
			"tickrate": config.tickrate,
		}
	)

	_resolve_console()
	_register_cvars()
	_register_commands()
	_watch_replicated_cvars()

	# server.cfg runs before the listener so FLAG_STARTUP_ONLY cvars are still
	# settable — that is the whole reason for the ordering.
	console.exec_config(config.startup_config, null, false)

	# The command line's CVAR half runs here too: `+sv_tickrate` is startup-only. The
	# `+command` half waits for the listener, below.
	console.execute_command_line(true)

	_apply_cvars_to_config()

	# Awaited: loading bans may hit a remote store, and the listener must not open
	# before the ban list is in force — a window where banned players can connect is
	# small but entirely avoidable.
	await _resolve_subsystems()

	_connect_limiter = DotRateLimiter.new(2.0, 10.0)

	# Built here rather than in _register_cvars so it reads the value server.cfg and
	# the command line actually settled on, not the exported default.
	address_guard = DotAddressGuard.new(config.max_connections_per_ip)
	address_guard.exempt_addresses = config.connection_limit_exempt_addresses

	var listening := _start_listening()
	if not listening.ok:
		return _boot_failed(listening)

	console.set_server_running(true)
	_started_at = int(Time.get_unix_time_from_system())

	console.exec_config(config.autoexec_config, null, false)
	console.execute_command_line()

	_set_state(State.RUNNING)
	_apply_tickrate()

	# Last, and deliberately: a query listener advertises this server to the
	# outside, and there is nothing worth advertising until everything above has
	# come up.
	_open_query_host()

	# Hibernate from the moment the server is up, so the first player's wake resets the map clocks.
	_maybe_hibernate()

	_log_ready()

	if events != null:
		events.fire("server_start", {"hostname": config.hostname})

	return DotResult.success(self)


func _load_boot_config() -> DotResult:
	if config == null:
		config = DotServerConfig.new()

	if config_file != "":
		var loaded := config.apply_json_file(config_file)
		if not loaded.ok:
			return loaded

	config.apply_env()
	config.apply_cli()

	var valid := config.validate()
	if not valid.ok:
		return valid

	config.warn_about_risky_settings()
	return DotResult.success()


func _log_ready() -> void:
	DotLog.info(
		CHANNEL,
		"ready",
		{
			"transport": _transport._transport_name(),
			"web_clients": _transport.supports_web_clients(),
			"enet_udp": enet_port(),
			"rcon": rcon != null and rcon.is_listening(),
			"query": query != null and bool(query.call("is_listening")),
			"a2s": a2s != null,
			"admins": admins.admin_count() if admins != null else 0,
			"bans": bans.count() if bans != null else 0,
		}
	)


func _boot_failed(res: DotResult) -> DotResult:
	_set_state(State.STOPPED)
	DotLog.fatal(
		CHANNEL,
		"boot failed: %s" % res.error.message,
		{"detail": res.error.detail}
	)
	return res


## Shuts down cleanly: tells clients, reports offline, flushes logs.
func shutdown(reason: String = "Server shutting down") -> void:
	if state == State.SHUTTING_DOWN or state == State.STOPPED:
		return

	_set_state(State.SHUTTING_DOWN)
	DotLog.info(CHANNEL, "shutting down", {"reason": reason})

	if events != null:
		events.fire("server_shutdown", {"reason": reason})

	# Tell everyone before closing the socket. A client that is told why it was
	# disconnected shows a message; one whose socket just closes shows "connection
	# lost", which players report as a crash.
	for session in sessions():
		_notify_disconnect(session, reason)

	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

	_peer = null
	_sessions.clear()
	_by_userid.clear()

	if bans != null:
		bans.save_bans()

	_set_state(State.STOPPED)
	DotRegistry.unregister_instance(SERVICE, self)

	# Last, and after the final state change, so the shutdown itself is in the file.
	# Records still sitting in a buffer when the process goes are the ones that would
	# have explained why it went.
	flush_log()


## Writes out whatever the log destination is holding.
##
## Called on shutdown, and worth calling from anything that is about to do something it
## might not come back from. A remote destination is started rather than waited for — the
## only thing that can honestly be promised to a process that is stopping — and dot-log's
## own [code]shutdown()[/code] is the path that waits.
func flush_log() -> void:
	if log_node == null or not is_instance_valid(log_node):
		return
	if log_node.has_method("flush_all"):
		log_node.call("flush_all")
	elif log_node.has_method("flush"):
		log_node.call("flush")


func _exit_tree() -> void:
	if state == State.RUNNING or state == State.HIBERNATING:
		shutdown("Server stopped")


func _resolve_console() -> void:
	if console_ref == null:
		console_ref = DotNodeRef.of_created(&"Console", DotConsole)
	console = _resolve(console_ref, "console") as DotConsole


## Applies the configured levels, then attaches or creates somewhere for the log to go.
##
## Runs before the first line this boot emits, which is the whole point: a level applied
## after the subsystems have started is a level that did not apply to the interesting
## part.
func _resolve_log_sink() -> void:
	_apply_log_levels()

	if log_sink_ref != null:
		log_node = log_sink_ref.resolve_or_null(self, CHANNEL)

	if log_node == null and config.log_file_enabled:
		log_node = _create_log_sink()

	if log_node == null:
		return

	# A router is anything that can be asked what it is doing and told to flush — which
	# is dot-log's, and could be somebody else's. Probed rather than named: naming it
	# would make an optional addon a hard dependency of every server in the family.
	log_is_router = (
		log_node.has_method("describe_lines") and log_node.has_method("flush_all")
	)

	if log_is_router and log_node.has_method("set_tag"):
		# The tags a collector needs to tell four servers apart. Set here rather than by
		# the host because the server is the only thing that knows them.
		log_node.call("set_tag", "hostname", config.hostname)
		log_node.call("set_tag", "port", config.port)

	DotLog.debug(
		CHANNEL,
		"log destination attached",
		{"node": log_node.name, "router": log_is_router}
	)


func _apply_log_levels() -> void:
	var level: int = DotServerConfig.parse_log_level(config.log_level)
	if level >= 0:
		DotLog.set_level(level)

	var mirror: int = DotServerConfig.parse_log_level(config.log_mirror_min_level)
	if mirror >= 0:
		DotLog.mirror_min_level = mirror

	for entry in config.log_channel_levels:
		var parts: PackedStringArray = String(entry).split("=", false, 1)
		if parts.size() != 2:
			continue
		var parsed: int = DotServerConfig.parse_log_level(parts[1])
		if parsed >= 0:
			DotLog.set_channel_level(parts[0].strip_edges(), parsed)


## The plain file sink every server gets when nothing better was placed.
func _create_log_sink() -> Node:
	var sink := DotLogSink.new()
	sink.name = "LogSink"
	sink.directory = config.log_directory
	sink.basename = config.log_basename
	sink.json_lines = config.log_json
	sink.max_file_bytes = config.log_max_file_bytes
	sink.max_files = config.log_max_files
	# The file keeps whatever DotLog itself let through: a second threshold here would
	# mean an operator who raised the level still found nothing in the file, with two
	# places to look before working out why.
	sink.level = DotLog.Level.TRACE
	add_child(sink)
	return sink


func _resolve_subsystems() -> void:
	if events_ref == null:
		events_ref = DotNodeRef.of_created(&"Events", DotEventBus)
	events = _resolve(events_ref, "events") as DotEventBus

	await _resolve_moderation()
	_resolve_game_subsystems()
	_resolve_operator_io()


func _resolve_moderation() -> void:
	if audit_ref == null:
		audit_ref = DotNodeRef.of_created(&"Audit", DotAuditLog)
	audit = _resolve(audit_ref, "audit") as DotAuditLog
	if audit != null:
		audit.config = config
		# Opened here, not in its `_ready`. A created node has already run `_ready` by the
		# time this line assigns the config, so the log resolved no path, returned, and
		# nothing recorded anything — in every configuration that did not place its own
		# audit node, which is every default one. Same reason `admins.load_admins()` is
		# explicit below.
		audit.open_log()

		if not audit.is_recording():
			DotLog.warn(
				CHANNEL,
				"no audit log; administrative actions will not be recorded",
				{"setting": "audit_log_path"}
			)

	if admin_ref == null:
		admin_ref = DotNodeRef.of_created(&"Admins", DotAdminManager)
	admins = _resolve(admin_ref, "admins") as DotAdminManager
	if admins != null:
		admins.config = config
		# Created nodes have already run _ready() by the time we set config, so the
		# load is triggered explicitly rather than relying on _ready ordering.
		admins.load_admins()
		_attach_auth_admin_source()

	if bans_ref == null:
		bans_ref = DotNodeRef.of_created(&"Bans", DotBanManager)
	bans = _resolve(bans_ref, "bans") as DotBanManager
	if bans != null:
		bans.config = config
		bans.audit = audit
		await bans.load_bans()


func _resolve_game_subsystems() -> void:
	if chat_ref == null:
		chat_ref = DotNodeRef.of_created(&"Chat", DotChatManager)
	chat = _resolve(chat_ref, "chat") as DotChatManager
	if chat != null:
		chat.setup(self)

	if games_ref == null:
		games_ref = DotNodeRef.of_created(&"Games", DotGameManager)
	games = _resolve(games_ref, "games") as DotGameManager
	if games != null:
		games.setup(self)
		# Awake while a game loads: a game reads its tick rate from the engine as it starts,
		# and a server that hibernated from boot (or emptied before a vote's change) had the
		# engine at hibernate_tickrate, so the delivered playground's netcode refused to start
		# at 5 Hz ("snapshot_rate must not exceed tick_rate"). Back to sleep after the load,
		# deferred, so a host's own game_loaded handler (which loads the module) runs awake.
		game_changing.connect(func(_from: String, _to: String) -> void: _begin_game_load())
		games.game_loaded.connect(func(_key: String) -> void: _end_game_load())
		games.game_load_failed.connect(func(_key: String, _error: DotError) -> void: _end_game_load())

	if votes_ref == null:
		votes_ref = DotNodeRef.of_created(&"Votes", DotVoteManager)
	votes = _resolve(votes_ref, "votes") as DotVoteManager
	if votes != null:
		votes.setup(self)

	if modules_ref == null:
		modules_ref = DotNodeRef.of_created(&"Modules", DotModuleHost)
	modules = _resolve(modules_ref, "modules") as DotModuleHost
	if modules != null:
		modules.setup(self)


func _resolve_operator_io() -> void:
	if config.rcon_password != "":
		if rcon_ref == null:
			rcon_ref = DotNodeRef.of_created(&"Rcon", DotRconServer)
		rcon = _resolve(rcon_ref, "rcon") as DotRconServer
		if rcon != null:
			rcon.setup(self)
	else:
		DotLog.info(
			CHANNEL, "RCON is disabled (no rcon_password set)"
		)

	# [b]The console an operator standing at the machine actually has.[/b] Built
	# unconditionally: it reports no terminal and does nothing when there is none --
	# a unit file, a container without `-i`, CI -- so there is no setting to get
	# wrong and no deployment it costs anything on.
	#
	# `stdin_console_enabled` exists for the one case that is a real decision rather
	# than an environment: a server whose stdin carries something that is not
	# commands.
	if config.stdin_console_enabled:
		if stdin_ref == null:
			stdin_ref = DotNodeRef.of_created(&"StdinConsole", DotStdinConsole)
		stdin_console = _resolve(stdin_ref, "stdin_console") as DotStdinConsole
		if stdin_console != null:
			stdin_console.read_pipes = config.stdin_console_pipes
			var reading := stdin_console.setup(self)
			if not reading.ok:
				DotLog.warn(CHANNEL, "the stdin console did not start", {
					"error": str(reading.error)
				})

	# Record permission-carrying commands in the audit trail. Done here rather than
	# in the console so the console stays independent of moderation.
	if audit != null and console != null:
		console.command_executed.connect(_on_command_for_audit)


func _resolve(ref: DotNodeRef, what: String) -> Node:
	var res := ref.resolve(self)
	if not res.ok:
		DotLog.error(
			CHANNEL,
			"could not resolve the %s node" % what,
			{"ref": ref.describe(), "detail": res.error.message}
		)
		return null
	return res.value


## Attaches dot-auth's admin source when that addon is present.
##
## Discovered through [DotRegistry] rather than imported, so dot-server has no
## dependency on dot-auth and works without it.
func _attach_auth_admin_source() -> void:
	var auth := DotRegistry.get_service(&"dot_auth_server")
	if auth == null:
		return

	var source_class := "DotAuthAdminSource"
	if not ClassDB.class_exists(source_class) and not _script_class_exists(source_class):
		return

	DotLog.debug(
		CHANNEL,
		"dot-auth is present; attach a DotAuthAdminSource to map site groups "
		+ "to server permissions"
	)


static func _script_class_exists(name: String) -> bool:
	for entry in ProjectSettings.get_global_class_list():
		if str(entry.get("class")) == name:
			return true
	return false


func _on_command_for_audit(ctx: DotCmdContext) -> void:
	var cmd := console.find_command(ctx.command)
	if cmd != null:
		audit.record_command(ctx, cmd.permission)


func _start_listening() -> DotResult:
	_transport = config.resolve_transport()

	var created := _transport.create_server(config.port, config.bind_address)
	if not created.ok:
		return created.wrap("Could not start listening.")

	_peer = created.value
	multiplayer.multiplayer_peer = _peer

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	if not _transport.supports_web_clients():
		DotLog.warn(
			CHANNEL,
			"this transport cannot accept browser clients — set "
			+ "require_web_clients on DotTransportAuto if you need them",
			{"transport": _transport._transport_name()}
		)

	return DotResult.success(_peer)


func _make_envelope() -> DotEnvelope:
	var env := DotEnvelope.new()
	env.register_core()
	env.handle(DotEnvelope.CREDENTIALS, _on_credentials)
	env.handle(DotEnvelope.CONTENT_PROGRESS, _on_content_progress)
	env.handle(DotEnvelope.CONTENT_READY, _on_content_ready)
	env.handle(DotEnvelope.LOADED, _on_loaded)
	env.handle(DotEnvelope.HEARTBEAT, _on_heartbeat)
	env.handle(DotEnvelope.PING, _on_ping)
	env.handle(DotEnvelope.VISIBILITY, _on_visibility)
	env.handle(DotEnvelope.CHAT_SUBMIT, _on_chat_submit)
	env.handle(DotEnvelope.SCOREBOARD_WANT, _on_scoreboard_want)
	return env


## Contract in dot_server_wire.gd; the lanes are the three `_dot_down` RPCs below.
func send_kind(
	peer_id: int,
	kind: StringName,
	payload: Dictionary = {},
	lane: DotEnvelope.Lane = DotEnvelope.Lane.CONTROL
) -> bool:
	if peer_id <= 0 or multiplayer == null or multiplayer.multiplayer_peer == null:
		return false
	if not envelope.should_send(peer_id, kind):
		return false

	match lane:
		DotEnvelope.Lane.UNRELIABLE:
			_dot_down_unreliable.rpc_id(peer_id, String(kind), payload)
		DotEnvelope.Lane.EVENT:
			_dot_down_event.rpc_id(peer_id, String(kind), payload)
		_:
			_dot_down.rpc_id(peer_id, String(kind), payload)
	return true


## [b]The six RPCs, and the only six this node will ever declare.[/b] Server to client on
## the `_dot_down` three, client to server on the `_dot_up` three; one per lane. Their
## NAMES are what Godot checksums and [DotSignon] hashes. Adding a seventh is a protocol
## break for every shipped client -- add a kind to [member envelope] instead.
## `signon_revision` fails on the commit that adds one.
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _dot_down(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("authority", "unreliable", "call_remote", CHANNEL_CONTROL)
func _dot_down_unreliable(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("authority", "reliable", "call_remote", CHANNEL_EVENT)
func _dot_down_event(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func _dot_up(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(multiplayer.get_remote_sender_id(), kind, payload)


@rpc("any_peer", "unreliable", "call_remote", CHANNEL_CONTROL)
func _dot_up_unreliable(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(multiplayer.get_remote_sender_id(), kind, payload)


@rpc("any_peer", "reliable", "call_remote", CHANNEL_EVENT)
func _dot_up_event(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(multiplayer.get_remote_sender_id(), kind, payload)
