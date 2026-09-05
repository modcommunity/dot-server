@tool
class_name DotServer
extends Node

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

const CHANNEL := "server"
const SERVICE := &"dot_server"

## Registry name of an optional external ban list — dot-moderation registers under it.
##
## Whatever is registered here answers
## [code]check_admission(uid: String, address: String) -> DotResult[/code]. Neither
## addon imports the other, exactly as [code]dot_mute_source[/code] joins dot-moderation
## to dot-voice.
const BAN_SOURCE := &"dot_ban_source"

## Reported in `status`, in query responses and in the backbone stats report.
##
## One constant rather than the three string literals it used to be, because a
## version that disagrees with itself across three listings is worse than no
## version at all.
const VERSION := "0.1.0"

## Multiplayer channel used for the join handshake and console traffic.
const CHANNEL_CONTROL := DotTransport.Channel.CONTROL

enum State {
	IDLE,
	BOOTING,
	RUNNING,
	## No players connected; ticking at a reduced rate.
	HIBERNATING,
	SHUTTING_DOWN,
	STOPPED,
}

signal state_changed(state: State)

## A client finished the whole join flow.
signal client_spawned(session: DotClientSession)

## A client left, for any reason. [param reason] is empty on a clean disconnect.
signal client_disconnected(session: DotClientSession, reason: String)

## A client's signon state advanced.
signal client_state_changed(session: DotClientSession)

## Emitted before the game changes, so subsystems can prepare.
signal game_changing(from_key: String, to_key: String)

@export_group("Configuration")

@export var config: DotServerConfig = null

## JSON config layered over [member config]'s defaults.
@export var config_file: String = "user://cfg/server.json"

## Boot automatically on [method Node._ready].
##
## Off when a host project wants to configure subsystems first and call
## [method boot] itself.
@export var auto_boot: bool = true

@export_group("Subsystems")

## Where to find or create the console.
##
## Every subsystem ref defaults to creating a child, so a bare [DotServer] works.
## Point one at an existing node to share it — a listen server hosting and playing
## in one process wants one console, not two.
@export var console_ref: DotNodeRef = null
@export var admin_ref: DotNodeRef = null
@export var bans_ref: DotNodeRef = null
@export var audit_ref: DotNodeRef = null
@export var chat_ref: DotNodeRef = null
@export var rcon_ref: DotNodeRef = null
@export var games_ref: DotNodeRef = null
@export var votes_ref: DotNodeRef = null

## Where to find or create the query snapshot builder.
##
## Created when either query protocol is enabled, since both read from it.
@export var query_source_ref: DotNodeRef = null
@export var query_ref: DotNodeRef = null
@export var a2s_ref: DotNodeRef = null
@export var events_ref: DotNodeRef = null
@export var modules_ref: DotNodeRef = null

## Optional log sink. Created only if this ref resolves.
@export var log_sink_ref: DotNodeRef = null

var console: DotConsole = null
var admins: DotAdminManager = null
var bans: DotBanManager = null
var audit: DotAuditLog = null
var chat: DotChatManager = null
var rcon: DotRconServer = null
var games: DotGameManager = null
var votes: DotVoteManager = null
var events: DotEventBus = null
var modules: DotModuleHost = null
var query_source: DotQuerySource = null
var query: DotQueryServer = null
var a2s: DotA2SServer = null

var state: State = State.IDLE

## peer_id -> DotClientSession
var _sessions: Dictionary = {}

## userid -> peer_id, so `kickid` can find a session.
var _by_userid: Dictionary = {}

var _next_userid: int = 1
var _peer: MultiplayerPeer = null
var _transport: DotTransport = null
var _started_at: int = 0

## Cvars this node owns and reads on hot paths.
var _cv_hostname: DotConVar
var _cv_password: DotConVar
var _cv_maxplayers: DotConVar
var _cv_cheats: DotConVar
var _cv_tickrate: DotConVar
var _cv_timeout: DotConVar

var _connect_limiter: DotRateLimiter = null
var _warned_about_ban_source: bool = false

## How many clients one address may hold at once. See [DotAddressGuard].
var address_guard: DotAddressGuard = null

var _sweep_accum: float = 0.0


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if auto_boot:
		await boot()


# --- Boot ------------------------------------------------------------------

## Brings the server up. Idempotent.
func boot() -> DotResult:
	if state != State.IDLE and state != State.STOPPED:
		return DotResult.fail(
			DotError.CODE_STATE, "The server is already running."
		)

	_set_state(State.BOOTING)

	if config == null:
		config = DotServerConfig.new()

	if config_file != "":
		var loaded := config.apply_json_file(config_file)
		if not loaded.ok:
			return _boot_failed(loaded)

	config.apply_env()
	config.apply_cli()

	var valid := config.validate()
	if not valid.ok:
		return _boot_failed(valid)

	config.warn_about_risky_settings()

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

	# server.cfg runs before the listener so FLAG_STARTUP_ONLY cvars are still
	# settable — that is the whole reason for the ordering.
	console.exec_config(config.startup_config, null, false)

	# And so does the command line's CVAR half, for the same reason and with the
	# same force: `+sv_tickrate 128` is the most startup-ish input a server takes,
	# and running the whole command line after the listener made every startup-only
	# cvar unsettable from it — so an operator with the muscle memory of any other
	# server got one
	# that quietly ignored them. The `+command` half still runs after the listener,
	# below, because a `+map` or a `+say` needs the server up first.
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

	DotLog.info(
		CHANNEL,
		"ready",
		{
			"transport": _transport._transport_name(),
			"web_clients": _transport.supports_web_clients(),
			"rcon": rcon != null and rcon.is_listening(),
			"query": query != null and query.is_listening(),
			"a2s": a2s != null,
			"admins": admins.admin_count() if admins != null else 0,
			"bans": bans.count() if bans != null else 0,
		}
	)

	if events != null:
		events.fire("server_start", {"hostname": config.hostname})

	return DotResult.success(self)


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


func _exit_tree() -> void:
	if state == State.RUNNING or state == State.HIBERNATING:
		shutdown("Server stopped")


# --- Subsystem wiring ------------------------------------------------------

func _resolve_console() -> void:
	if console_ref == null:
		console_ref = DotNodeRef.of_created(&"Console", DotConsole)
	console = _resolve(console_ref, "console") as DotConsole


func _resolve_log_sink() -> void:
	if log_sink_ref == null:
		return
	var node := log_sink_ref.resolve_or_null(self, CHANNEL)
	if node != null:
		DotLog.debug(CHANNEL, "log sink attached", {"node": node.name})


func _resolve_subsystems() -> void:
	if events_ref == null:
		events_ref = DotNodeRef.of_created(&"Events", DotEventBus)
	events = _resolve(events_ref, "events") as DotEventBus

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

	_resolve_query()

	# Record permission-carrying commands in the audit trail. Done here rather than
	# in the console so the console stays independent of moderation.
	if audit != null and console != null:
		console.command_executed.connect(_on_command_for_audit)


## Brings up whichever query listeners are enabled.
##
## The order matters. [DotQueryServer] binds first, and [DotA2SServer] then either
## shares that socket — when both are on the same port, which is the default — or
## binds its own. Two listeners cannot bind one UDP port, and the two protocols are
## distinguishable by their first four bytes, so sharing is both necessary and free.
func _resolve_query() -> void:
	if not config.query_enabled and not config.a2s_enabled:
		return

	if query_source_ref == null:
		query_source_ref = DotNodeRef.of_created(&"QuerySource", DotQuerySource)
	query_source = _resolve(query_source_ref, "query source") as DotQuerySource
	if query_source == null:
		return
	query_source.setup(self)

	if config.query_enabled:
		if config.effective_query_port() <= 0:
			# Same reasoning as RCON's: an ephemeral game port leaves nothing to
			# derive a query port from, and a listener on a port nobody was told
			# about answers nobody.
			DotLog.info(
				CHANNEL,
				"query listener disabled: set query_port, there is no fixed game "
				+ "port to derive one from"
			)
		else:
			if query_ref == null:
				query_ref = DotNodeRef.of_created(&"Query", DotQueryServer)
			query = _resolve(query_ref, "query") as DotQueryServer
			if query != null:
				query.setup(self, query_source)
				var opened := query.open()
				if not opened.ok:
					DotLog.warn(
						CHANNEL,
						"could not open the query listener",
						{"detail": opened.error.message}
					)

	if not config.a2s_enabled:
		return

	if config.effective_a2s_port() <= 0:
		DotLog.info(
			CHANNEL,
			"A2S disabled: set a2s_port, there is no fixed game port to derive "
			+ "one from"
		)
		return

	if a2s_ref == null:
		a2s_ref = DotNodeRef.of_created(&"A2S", DotA2SServer)
	a2s = _resolve(a2s_ref, "a2s") as DotA2SServer
	if a2s == null:
		return

	a2s.setup(self, query_source)

	var shared := query != null and query.is_listening() \
		and config.effective_query_port() == config.effective_a2s_port()

	if shared:
		query.attach_a2s(a2s)
		return

	var a2s_opened := a2s.open()
	if not a2s_opened.ok:
		DotLog.warn(
			CHANNEL,
			"could not open the A2S listener",
			{"detail": a2s_opened.error.message}
		)


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


# --- Listening -------------------------------------------------------------

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


# --- Sessions --------------------------------------------------------------

func _on_peer_connected(peer_id: int) -> void:
	var address := _address_of(peer_id)

	# Rate-limited before a session object exists, so a connect flood costs the
	# server a dictionary lookup rather than allocations and an auth timeout each.
	if not _connect_limiter.allow(DotBanManager.normalise_address(address)):
		DotLog.warn(
			CHANNEL, "connection refused: too many attempts", {"from": address}
		)
		_disconnect_peer(peer_id)
		return

	var admitted := check_address_admission(address)
	if not admitted.ok:
		DotLog.info(
			CHANNEL,
			"connection refused",
			{"from": address, "why": admitted.error.detail}
		)
		_reject_peer(peer_id, admitted.error.message)
		return

	var session := DotClientSession.new(_next_userid, peer_id)
	_next_userid += 1
	session.address = address

	_sessions[peer_id] = session
	_by_userid[session.userid] = peer_id

	session.transition_to(DotClientSession.State.AUTHENTICATING)

	DotLog.info(
		CHANNEL,
		"client connecting",
		{"userid": session.userid, "from": address}
	)

	client_state_changed.emit(session)

	if events != null:
		events.fire("client_connect", {"userid": session.userid, "address": address})

	# Ask the client to identify itself. Everything from here is driven by the
	# client's reply or by the auth timeout.
	_request_credentials.rpc_id(peer_id, _handshake_challenge(session))


func _on_peer_disconnected(peer_id: int) -> void:
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return

	session.transition_to(DotClientSession.State.DISCONNECTED)

	_sessions.erase(peer_id)
	_by_userid.erase(session.userid)

	DotLog.info(
		CHANNEL,
		"client disconnected",
		{
			"userid": session.userid,
			"name": session.display_name,
			"played": session.connected_seconds(),
		}
	)

	client_disconnected.emit(session, "")

	if events != null:
		events.fire("client_disconnect", {
			"userid": session.userid,
			"name": session.display_name,
		})

	_maybe_hibernate()


func _address_of(peer_id: int) -> String:
	if _peer == null:
		return ""

	# WebSocket and ENet expose the remote address through different methods, and
	# neither is on the MultiplayerPeer base class.
	if _peer.has_method("get_peer_address"):
		var address: Variant = _peer.call("get_peer_address", peer_id)
		if address != null and str(address) != "":
			return str(address)

	return "unknown"


func session_of(peer_id: int) -> DotClientSession:
	return _sessions.get(peer_id)


func session_by_userid(userid: int) -> DotClientSession:
	var peer_id: Variant = _by_userid.get(userid)
	if peer_id == null:
		return null
	return _sessions.get(int(peer_id))


func sessions() -> Array[DotClientSession]:
	var out: Array[DotClientSession] = []
	for peer_id in _sessions:
		out.append(_sessions[peer_id])
	return out


func playing_sessions() -> Array[DotClientSession]:
	var out: Array[DotClientSession] = []
	for session in sessions():
		if session.is_playing():
			out.append(session)
	return out


func player_count() -> int:
	return playing_sessions().size()


## Every active session connected from [param address].
##
## What an address ban has to act on: banning an address that nobody currently at it is
## removed from is a ban that takes effect the next time they connect, which from the
## moderator's seat looks exactly like the ban not working.
func sessions_from(address: String) -> Array[DotClientSession]:
	var out: Array[DotClientSession] = []
	var host := DotBanManager.normalise_address(address)

	if host == "":
		return out

	for session in sessions():
		if session.is_active() and DotBanManager.normalise_address(session.address) == host:
			out.append(session)

	return out


## The address of every session currently holding a slot, duplicates included.
##
## Duplicates are the point: this is what [DotAddressGuard] counts.
func addresses_in_use() -> PackedStringArray:
	var out := PackedStringArray()
	for session in sessions():
		if session.is_active():
			out.append(session.address)
	return out


## Whether a peer at [param address] may connect at all.
##
## Answered before a session exists, so it covers only what an address can be judged on:
## the ban list, an optional external ban source, and the per-address connection limit.
## The identity half is [method check_identity_admission], which cannot run until the
## client has said who it is.
func check_address_admission(address: String) -> DotResult:
	if bans != null:
		var banned := bans.check_address(address)
		if not banned.ok:
			return banned

	var source := _ban_source()
	if source != null:
		var external: Variant = source.call("check_admission", "", address)
		if external is DotResult and not (external as DotResult).ok:
			return external

	if address_guard != null:
		var allowed := address_guard.check(address, addresses_in_use())
		if not allowed.ok:
			return allowed

	return DotResult.success(null)


## Whether an authenticated session may stay.
##
## Both halves of a ban are checked here — the account and the address — because a
## client that connected before a ban was issued has already passed
## [method check_address_admission].
func check_identity_admission(session: DotClientSession) -> DotResult:
	if session == null:
		return DotResult.fail(DotError.CODE_INVALID, "No session.")

	if bans != null:
		var banned := bans.check_session(session)
		if not banned.ok:
			return banned

	var source := _ban_source()
	if source != null:
		var external: Variant = source.call(
			"check_admission", session.uid(), session.address
		)
		if external is DotResult and not (external as DotResult).ok:
			return external

	return DotResult.success(null)


## An externally registered ban list, or null.
##
## [b]The same shape dot-voice and dot-moderation already meet through.[/b] A deployment
## keeping its punishments in dot-moderation registers it under [code]dot_ban_source[/code]
## and this server enforces them without either addon importing the other; a deployment
## using only [DotBanManager] registers nothing and nothing changes.
##
## The method is checked rather than assumed. Four call sites in this family have found a
## service that did not answer the method they called, in every case with no error — so a
## registration that cannot answer is reported once, loudly, instead of being skipped.
func _ban_source() -> Object:
	var source := DotRegistry.get_service(BAN_SOURCE)

	if source == null:
		return null

	if not source.has_method("check_admission"):
		if not _warned_about_ban_source:
			_warned_about_ban_source = true
			DotLog.error(
				CHANNEL,
				"a dot_ban_source is registered but cannot answer check_admission(uid, address); "
				+ "its bans are enforced by nothing",
				{"service": str(source)}
			)
		return null

	return source


## Re-checks every connected player against the ban list and removes those now banned.
##
## A ban issued against somebody already connected — by address, by account, or in a
## shared store by another server — otherwise takes effect on their next connection,
## which is indistinguishable from it not working. Returns how many were removed.
func enforce_bans(reason: String = "") -> int:
	var removed := 0

	for session in sessions():
		if not session.is_active():
			continue

		var admitted := check_identity_admission(session)
		if admitted.ok:
			continue

		kick(session, reason if reason != "" else admitted.error.message)
		removed += 1

	return removed


## Adds a session this server did not create from a socket.
##
## The transport creates sessions on connect and that is the normal path. This is for a
## host that owns its own admission — a server-side bot, a listen server's local player,
## or a test that needs the session table populated without a socket — and it exists
## because everything that counts players (slots, the per-address limit, the roster,
## queries) counts sessions, so a participant with no session is invisible to all of it.
##
## Refuses a peer id already in use: two sessions on one peer id would silently make the
## second unreachable by every lookup here.
func adopt_session(session: DotClientSession) -> DotResult:
	if session == null:
		return DotResult.fail(DotError.CODE_INVALID, "No session.")

	if _sessions.has(session.peer_id):
		return DotResult.fail(
			DotError.CODE_STATE,
			"That peer id already has a session.",
			"peer %d" % session.peer_id
		)

	if session.userid <= 0:
		session.userid = _next_userid
		_next_userid += 1

	session.local = true

	_sessions[session.peer_id] = session
	_by_userid[session.userid] = session.peer_id

	client_state_changed.emit(session)

	return DotResult.success(session)


## Removes a session without touching the transport. The counterpart to
## [method adopt_session]; use [method kick] for a real client.
func release_session(peer_id: int) -> DotResult:
	var session: DotClientSession = _sessions.get(peer_id)

	if session == null:
		return DotResult.fail(DotError.CODE_INVALID, "No session on that peer id.")

	_sessions.erase(peer_id)
	_by_userid.erase(session.userid)

	return DotResult.success(session)


## Finds sessions by userid, name, username, account id or address.
##
## The lookup every admin command needs. Returns every match so a command can
## refuse an ambiguous target rather than acting on whichever happened to be first
## — kicking the wrong player because two names shared a substring is the classic
## admin-tool bug.
##
## In precedence order, because a moderator types the shortest thing that identifies
## somebody and the exact forms must win over the fuzzy one:
##
## [codeblock]
## #12              userid, the id `kickid` takes
## 12               userid
## @me              the caller, when a session is asking
## ip:203.0.113.9   everybody at that address — several matches on purpose
## Player One       display name, exact (case-insensitive)
## playerone        username from their account, exact
## backbone:abc123  account id
## play             display name, substring — the only ambiguous form
## [/codeblock]
##
## [b]The exact forms are matched before the substring one[/b] for the reason the
## ambiguity check exists: a player whose whole name is another player's prefix is
## otherwise unbannable, because naming them exactly matches two people.
func find_sessions(target: String, caller: DotClientSession = null) -> Array[DotClientSession]:
	var out: Array[DotClientSession] = []
	var query := target.strip_edges()

	if query == "":
		return out

	# A leading # means a userid, the same id `kickid` takes.
	if query.begins_with("#") and query.substr(1).is_valid_int():
		var by_id := session_by_userid(query.substr(1).to_int())
		if by_id != null:
			out.append(by_id)
		return out

	if query.is_valid_int():
		var by_id2 := session_by_userid(query.to_int())
		if by_id2 != null:
			out.append(by_id2)
			return out

	var lowered := query.to_lower()

	if lowered == "@me" or lowered == "@self":
		if caller != null:
			out.append(caller)
		return out

	# Deliberately returns everybody at the address rather than the first of them:
	# an address is a household, and a command acting on one of three players at it
	# without saying so is the kind of mistake that ends an appeal badly.
	if lowered.begins_with("ip:") or lowered.begins_with("@ip:"):
		var host := query.substr(query.find(":") + 1)
		return sessions_from(host)

	for session in sessions():
		if session.display_name.to_lower() == lowered:
			# An exact name match wins outright: it is unambiguous by definition.
			return [session]

	# The account name, which is what a player is called on the site and what an
	# appeal, a report or a ticket names them by. Their display name can be anything.
	for session in sessions():
		var username := session.username()
		if username != "" and username.to_lower() == lowered:
			return [session]

	for session in sessions():
		if session.uid() == query:
			return [session]

	for session in sessions():
		if session.display_name.to_lower().contains(lowered):
			out.append(session)

	return out


## Resolves a target for an admin command, checking immunity.
##
## Returns a failure with a message the caller can show for every refusal reason:
## nobody matched, several matched, or the target outranks the caller.
func resolve_target(
	ctx: DotCmdContext,
	target: String
) -> DotResult:
	var matches := find_sessions(target, ctx.session)

	if matches.is_empty():
		return DotResult.fail(
			DotError.CODE_INVALID, "No player matching '%s'." % target
		)

	if matches.size() > 1:
		var names := PackedStringArray()
		for session in matches:
			names.append("#%d %s" % [session.userid, session.display_name])
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' matches several players." % target,
			", ".join(Array(names))
		)

	var session := matches[0]

	if not ctx.outranks(session.immunity):
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"%s has equal or higher immunity than you." % session.display_name,
			"their immunity %d, yours %d" % [session.immunity, ctx.immunity]
		)

	return DotResult.success(session)


# --- Handshake -------------------------------------------------------------

func _handshake_challenge(session: DotClientSession) -> Dictionary:
	return {
		"protocol": 1,
		"hostname": _cv_hostname.get_string(),
		"server_id": config.server_id,
		"needs_password": _cv_password.get_string() != "",
		"userid": session.userid,
		# The strategy tells the client which credential to send. Without it a
		# client would have to guess, or send everything it has.
		"auth": _auth_strategy_name(),
	}


func _auth_strategy_name() -> String:
	var auth := DotRegistry.get_service(&"dot_auth_server")
	if auth == null:
		return "none"
	if auth.has_method("strategy_name"):
		return str(auth.call("strategy_name")).to_lower()
	return "unknown"


## Asks a client to identify itself.
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _request_credentials(_challenge: Dictionary) -> void:
	# Server-side stub. The implementation lives on the client; declaring it here
	# is what lets Godot's RPC layer route the call.
	pass


## A client's answer to the challenge.
##
## The one unauthenticated entry point, so everything it touches is bounded: the
## payload is validated field by field, the password comparison is constant-time,
## and a failure closes the connection rather than allowing another attempt on the
## same peer.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func submit_credentials(payload: Dictionary) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	var session: DotClientSession = _sessions.get(peer_id)

	if session == null:
		return

	session.touch()

	if session.state != DotClientSession.State.AUTHENTICATING:
		DotLog.warn(
			CHANNEL,
			"credentials submitted in the wrong state",
			{"userid": session.userid, "state": session.state_name()}
		)
		return

	var requested_name := str(payload.get("name", "")).strip_edges()
	if requested_name != "":
		session.display_name = requested_name.substr(0, 32)

	var server_password := _cv_password.get_string()
	if server_password != "":
		var supplied := str(payload.get("password", ""))
		if not DotHash.constant_time_equal(
			supplied.to_utf8_buffer(), server_password.to_utf8_buffer()
		):
			# Checked before authentication so an unauthenticated client cannot use
			# the auth path to probe anything, and after the name so the log line
			# says who tried.
			DotLog.info(
				CHANNEL,
				"wrong server password",
				{"userid": session.userid, "from": session.address}
			)
			_reject_session(session, "Incorrect server password.")
			return

	var identity := await _authenticate(session, payload)

	if identity == null:
		return

	session.identity = identity

	if admins != null:
		admins.resolve(session)

	var admitted := check_identity_admission(session)
	if not admitted.ok:
		DotLog.info(
			CHANNEL,
			"banned player refused",
			{"user": session.label(), "why": admitted.error.detail}
		)
		_reject_session(session, admitted.error.message)
		return

	if not _claim_slot(session):
		return

	if identity.has_method("get"):
		var name_value: Variant = identity.get("display_name")
		if name_value != null and str(name_value) != "":
			session.display_name = str(name_value)

	DotLog.info(
		CHANNEL,
		"client authenticated",
		{
			"user": session.label(),
			"admin": session.is_admin(),
			"immunity": session.immunity,
		}
	)

	_advance_to_content(session)


## Runs dot-auth if it is present, or admits everyone as a guest if it is not.
##
## Returns null after rejecting the session, so the caller stops.
func _authenticate(
	session: DotClientSession,
	payload: Dictionary
) -> Object:
	var auth := DotRegistry.get_service(&"dot_auth_server")

	if auth == null or not auth.has_method("authenticate"):
		# No dot-auth installed. Everyone is a guest, which is the only honest
		# option — inventing an identity would make bans look like they work.
		return _guest_identity(session, payload)

	var credential := {
		"ticket": str(payload.get("ticket", "")),
		"access_token": str(payload.get("access_token", "")),
		"username": str(payload.get("username", "")),
		"password": str(payload.get("auth_password", "")),
		"device_id": str(payload.get("device_id", "")),
		"name": session.display_name,
	}

	var res: Variant = await auth.call(
		"authenticate", credential, session.address
	)

	if not (res is DotResult):
		DotLog.error(
			CHANNEL, "the auth service returned something unexpected"
		)
		_reject_session(session, "Server authentication is misconfigured.")
		return null

	var result := res as DotResult

	if not result.ok:
		_reject_session(session, result.error.message)
		return null

	return result.value


## A minimal identity for servers running without dot-auth.
##
## Duck-typed to what [DotClientSession] reads, so the rest of the server does not
## branch on whether dot-auth is installed. See [DotGuestIdentity].
func _guest_identity(
	session: DotClientSession,
	payload: Dictionary
) -> Object:
	return DotGuestIdentity.from_device(
		str(payload.get("device_id", "")), session.display_name
	)


## Enforces the slot limit, honouring reserved slots.
func _claim_slot(session: DotClientSession) -> bool:
	var occupied := 0
	for other in sessions():
		if other.peer_id != session.peer_id and other.is_active():
			occupied += 1

	var max_players := _cv_maxplayers.get_int()

	if occupied < config.public_slots():
		return true

	if occupied < max_players and session.has_permission(DotAdminFlags.RESERVATION):
		session.used_reserved_slot = true
		DotLog.info(
			CHANNEL, "reserved slot used", {"user": session.label()}
		)
		return true

	DotLog.info(
		CHANNEL,
		"server full",
		{"user": session.label(), "occupied": occupied, "max": max_players}
	)
	_reject_session(session, "The server is full.")
	return false


## Moves an authenticated client into content sync, or straight to loading.
func _advance_to_content(session: DotClientSession) -> void:
	var manifest_url := ""
	if games != null:
		manifest_url = games.current_manifest_url()
	if manifest_url == "":
		manifest_url = config.content_manifest_url

	if manifest_url == "":
		session.transition_to(DotClientSession.State.LOADING)
		client_state_changed.emit(session)
		_send_load_game(session)
		return

	session.transition_to(DotClientSession.State.DOWNLOADING)
	session.content_progress = 0.0
	client_state_changed.emit(session)

	_begin_content_sync.rpc_id(session.peer_id, {
		"manifest_url": manifest_url,
		# Documented on the descriptor since the first version and sent by nothing,
		# so a game that named optional groups had every client fetch only the
		# required set and then miss the assets the groups held.
		"content_groups": games.current_content_groups() if games != null else [],
		"content_key": games.current_content_key() if games != null else "",
		"allow_netchan": config.allow_netchan_content,
		"chunk_bytes": config.netchan_chunk_bytes,
	})


@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _begin_content_sync(_info: Dictionary) -> void:
	pass


## A client reporting content-sync progress.
##
## Progress is advisory — it drives `status` output and nothing else — so it is
## clamped rather than validated. A client that lies about it only lies about a
## number an admin sees.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func report_content_progress(fraction: float) -> void:
	var session: DotClientSession = _sessions.get(
		multiplayer.get_remote_sender_id()
	)
	if session == null:
		return

	session.touch()
	session.content_progress = clampf(fraction, 0.0, 1.0)


## A client reporting that content is ready.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func report_content_ready(content_key: String) -> void:
	var session: DotClientSession = _sessions.get(
		multiplayer.get_remote_sender_id()
	)
	if session == null:
		return

	session.touch()

	if session.state != DotClientSession.State.DOWNLOADING:
		return

	# [b]The pending game counts, not only the current one.[/b] A `changelevel` sends
	# every client to fetch the NEW game's content and only swaps once they have it —
	# so for the whole of that window the key a client correctly reports is the one
	# the server is not running yet. Comparing against the current game alone rejected
	# every client on every content-bearing game change, with
	# "Your game content does not match the server's", which is the one message that
	# makes it look like the client's fault.
	#
	# Nothing could see it: `_sync_clients` is skipped entirely for a game that ships
	# inside the build, and every game in every suite in this family is one. The live
	# switch test connects a real client over a real socket and still misses it,
	# because its three games are all `kind: builtin`.
	var acceptable := PackedStringArray()

	if games != null:
		var current := games.current_content_key()
		if current != "":
			acceptable.append(current)
		var pending := games.pending_content_key()
		if pending != "":
			acceptable.append(pending)

	if not acceptable.is_empty() and not (content_key in acceptable):
		# The client has different content from the one the server is running.
		# Admitting it would mean a player in a world made of the wrong assets.
		DotLog.warn(
			CHANNEL,
			"client reported the wrong content",
			{
				"user": session.label(),
				"reported": content_key,
				"expected": ", ".join(Array(acceptable)),
			}
		)
		_reject_session(
			session, "Your game content does not match the server's."
		)
		return

	session.content_key = content_key
	session.content_progress = 1.0
	session.transition_to(DotClientSession.State.LOADING)
	client_state_changed.emit(session)

	# [b]Not while a change is still syncing.[/b] `load_info()` describes the game
	# this server is running, and during a change that is deliberately the OLD one —
	# the swap happens after every client has the new content, which is what this
	# client just finished reporting. Sending it here told the first client to finish
	# downloading to go and load the game it was already in, and on a change between
	# two delivered games that is a scene out of content it is about to stop holding.
	#
	# [DotGameManager._swap_to] sends the real one to every session in LOADING once
	# the new scene is live, so nothing is lost by waiting — the session simply sits
	# in LOADING for the rest of the sync, which is exactly what it is doing.
	if games != null and games.phase == DotGameManager.Phase.SYNCING:
		return

	_send_load_game(session)


func _send_load_game(session: DotClientSession) -> void:
	var info := {}
	if games != null:
		info = games.load_info()

	_load_game.rpc_id(session.peer_id, info)


@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _load_game(_info: Dictionary) -> void:
	pass


## A client reporting that it has finished loading and is ready to play.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func report_loaded() -> void:
	var session: DotClientSession = _sessions.get(
		multiplayer.get_remote_sender_id()
	)
	if session == null:
		return

	session.touch()

	if not session.transition_to(DotClientSession.State.SPAWNED):
		return

	DotLog.info(
		CHANNEL,
		"client spawned",
		{"user": session.label(), "took": session.connected_seconds()}
	)

	client_state_changed.emit(session)
	client_spawned.emit(session)

	if events != null:
		events.fire("client_spawn", {
			"userid": session.userid,
			"name": session.display_name,
		})

	if chat != null:
		chat.announce_join(session)

	_wake_from_hibernation()


## A client's keepalive and ping sample.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_CONTROL)
func heartbeat(client_time_ms: int) -> void:
	var peer_id := multiplayer.get_remote_sender_id()
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return

	session.touch()
	_heartbeat_ack.rpc_id(peer_id, client_time_ms)


@rpc("authority", "unreliable", "call_remote", CHANNEL_CONTROL)
func _heartbeat_ack(_client_time_ms: int) -> void:
	pass


## A client reporting its measured round-trip time.
@rpc("any_peer", "unreliable", "call_remote", CHANNEL_CONTROL)
func report_ping(ping_ms: int) -> void:
	var session: DotClientSession = _sessions.get(
		multiplayer.get_remote_sender_id()
	)
	if session == null:
		return
	session.touch()
	session.ping_ms = clampi(ping_ms, 0, 60_000)


# --- Kicking ---------------------------------------------------------------

## Disconnects a client with a reason they will see.
func kick(session: DotClientSession, reason: String = "Kicked") -> DotResult:
	if session == null or not session.is_active():
		return DotResult.fail(DotError.CODE_INVALID, "No such player.")

	DotLog.info(
		CHANNEL, "kicked", {"user": session.label(), "reason": reason}
	)

	_notify_disconnect(session, reason)

	session.transition_to(DotClientSession.State.DISCONNECTED)
	_disconnect_peer(session.peer_id)

	_sessions.erase(session.peer_id)
	_by_userid.erase(session.userid)

	client_disconnected.emit(session, reason)

	if events != null:
		events.fire("client_kicked", {
			"userid": session.userid,
			"name": session.display_name,
			"reason": reason,
		})

	return DotResult.success(session)


func _reject_session(session: DotClientSession, reason: String) -> void:
	session.reject(reason)
	client_state_changed.emit(session)

	_notify_disconnect(session, reason)
	_disconnect_peer(session.peer_id)

	_sessions.erase(session.peer_id)
	_by_userid.erase(session.userid)


func _reject_peer(peer_id: int, reason: String) -> void:
	_notify_peer_disconnect(peer_id, reason)
	_disconnect_peer(peer_id)


func _notify_disconnect(session: DotClientSession, reason: String) -> void:
	_notify_peer_disconnect(session.peer_id, reason)


func _notify_peer_disconnect(peer_id: int, reason: String) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	var session: DotClientSession = _sessions.get(peer_id)
	if session != null and session.local:
		# Adopted sessions have no peer. Sending to one is an engine error on a path
		# that is otherwise working perfectly, which is how error output stops being
		# read at all.
		return
	# Sent before closing so the client can show why. Reliable, but the close
	# follows on a deferred call to give the packet a frame to leave.
	_disconnected.rpc_id(peer_id, reason)


@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _disconnected(_reason: String) -> void:
	pass


func _disconnect_peer(peer_id: int) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	var session: DotClientSession = _sessions.get(peer_id)
	if session != null and session.local:
		return
	# Deferred so a rejection message sent in the same frame actually goes out;
	# closing immediately drops it.
	multiplayer.multiplayer_peer.disconnect_peer.call_deferred(peer_id)


# --- Broadcast -------------------------------------------------------------

## Sends a system message to every playing client.
func broadcast_message(text: String) -> void:
	if chat != null:
		chat.broadcast_system(text)


## Sends a message to clients holding a permission flag.
##
## What makes admin chat work: the message goes only to the peers entitled to see
## it, decided server-side rather than by asking clients to filter.
func broadcast_to_permission(flag: String, text: String) -> void:
	if chat == null:
		return
	for session in playing_sessions():
		if session.has_permission(flag):
			chat.send_system_to(session, text)


# --- Tick and timeouts ----------------------------------------------------

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if state != State.RUNNING and state != State.HIBERNATING:
		return

	_sweep_accum += delta
	if _sweep_accum >= 1.0:
		_sweep_accum = 0.0
		_sweep_timeouts()


## Drops clients that have been stuck in a stage too long.
##
## Per-stage timeouts, because the right budget for downloading 400 MB and for
## replying to an auth challenge differ by three orders of magnitude, and one
## timeout for both is either useless or hostile.
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
			DotClientSession.State.DOWNLOADING:
				limit = config.download_timeout_sec
			DotClientSession.State.LOADING:
				limit = config.load_timeout_sec
			DotClientSession.State.SPAWNED:
				# Spawned clients are judged on silence, not on time in state.
				if session.idle_seconds() > _cv_timeout.get_float():
					kick(session, "Timed out")
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
				}
			)
			kick(session, "Timed out while %s" % session.state_name().to_lower())


func _apply_tickrate() -> void:
	var rate := _cv_tickrate.get_int()

	if state == State.HIBERNATING:
		rate = config.hibernate_tickrate

	Engine.physics_ticks_per_second = maxi(1, rate)

	# A dedicated server has no frames to draw, so an unbounded max_fps spins a
	# core for nothing. Matching it to the tickrate is what keeps an idle server
	# near zero CPU.
	if DotPlatform.is_headless():
		Engine.max_fps = maxi(1, rate)

	DotLog.debug(CHANNEL, "tickrate applied", {"rate": rate})


func _maybe_hibernate() -> void:
	if not config.hibernate_when_empty:
		return
	if state != State.RUNNING:
		return
	if player_count() > 0 or not _sessions.is_empty():
		return

	_set_state(State.HIBERNATING)
	_apply_tickrate()
	DotLog.info(CHANNEL, "hibernating (no players)")


func _wake_from_hibernation() -> void:
	if state != State.HIBERNATING:
		return
	_set_state(State.RUNNING)
	_apply_tickrate()
	DotLog.info(CHANNEL, "woke from hibernation")


func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(new_state)


func state_name() -> String:
	return State.keys()[state]


func uptime_seconds() -> int:
	if _started_at == 0:
		return 0
	return int(Time.get_unix_time_from_system()) - _started_at


# --- Cvars ----------------------------------------------------------------

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

	_cv_maxplayers = console.cvar(
		"sv_maxplayers",
		str(config.max_players),
		"Player slots.",
		DotConVar.FLAG_ARCHIVE
	).with_range(1, 4096)

	_cv_tickrate = console.cvar(
		"sv_tickrate",
		str(config.tickrate),
		"Server ticks per second.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_STARTUP_ONLY
	).with_range(10, 240)

	_cv_timeout = console.cvar(
		"sv_timeout",
		str(config.client_timeout_sec),
		"Seconds of silence before a client is dropped.",
		DotConVar.FLAG_ARCHIVE
	).with_range(5, 600)

	console.cvar(
		"sv_lan",
		"0",
		"LAN mode: skip listing and heartbeat.",
		DotConVar.FLAG_ARCHIVE
	)

	# Registered here, before server.cfg runs, so a config file can turn either
	# query protocol on or off — the same layering promise every other setting
	# makes. At runtime they stop the listener answering rather than closing its
	# socket, so toggling one back on is immediate.
	console.cvar(
		"sv_query",
		"1" if config.query_enabled else "0",
		"Answer dot query protocol requests.",
		DotConVar.FLAG_ARCHIVE
	)

	console.cvar(
		"sv_a2s",
		"1" if config.a2s_enabled else "0",
		"Answer A2S query requests.",
		DotConVar.FLAG_ARCHIVE
	)

	console.cvar(
		"sv_query_players",
		config.query_player_detail,
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

	console.cvar(
		"sv_reserved_slots",
		str(config.reserved_slots),
		"Slots kept for players with the reservation flag.",
		DotConVar.FLAG_ARCHIVE
	).with_range(0, 64)

	# Live, not startup-only: an operator turns this on because something is happening
	# right now, and a limit they have to restart to apply is one that arrives after the
	# server has already been filled.
	console.cvar(
		"sv_max_connections_per_ip",
		str(config.max_connections_per_ip),
		"Simultaneous connections allowed from one address. 0 for no limit.",
		DotConVar.FLAG_ARCHIVE
	).with_range(0, 64).changed.connect(
		func(_old: String, value: String) -> void:
			config.max_connections_per_ip = value.to_int()
			if address_guard != null:
				address_guard.limit = value.to_int()
	)

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


## Reads cvars back into the config after server.cfg has run.
func _apply_cvars_to_config() -> void:
	config.hostname = _cv_hostname.get_string()
	config.password = _cv_password.get_string()
	config.max_players = _cv_maxplayers.get_int()
	config.tickrate = _cv_tickrate.get_int()
	config.client_timeout_sec = _cv_timeout.get_float()
	config.reserved_slots = console.get_int("sv_reserved_slots", config.reserved_slots)
	config.max_connections_per_ip = console.get_int(
		"sv_max_connections_per_ip", config.max_connections_per_ip
	)
	config.query_enabled = console.get_bool("sv_query", config.query_enabled)
	config.a2s_enabled = console.get_bool("sv_a2s", config.a2s_enabled)
	config.query_player_detail = console.get_string(
		"sv_query_players", config.query_player_detail
	)


func _register_commands() -> void:
	DotBuiltinCommands.register_all(self, console)


# --- Reporting ------------------------------------------------------------

## The `status` command's output.
func status_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("hostname: %s" % _cv_hostname.get_string())
	out.append("version : dot-server %s (%s)" % [VERSION, DotPlatform.kind_name()])
	out.append("udp/ip  : %s:%d (%s)" % [
		config.bind_address, config.port, _transport._transport_name()
			if _transport != null else "not listening",
	])
	out.append("state   : %s, up %s" % [
		state_name().to_lower(), DotBanManager.format_duration(uptime_seconds())
	])

	if games != null:
		out.append("game    : %s" % games.describe_current())

	out.append("players : %d playing, %d connecting, %d max" % [
		player_count(), _sessions.size() - player_count(), _cv_maxplayers.get_int()
	])

	if _cv_password.get_string() != "":
		out.append("password: yes")

	if address_guard != null and address_guard.limit > 0:
		# Shown only when it is on. A limit that is refusing players is the first thing
		# to look at when the server "will not let anybody in", and nothing else here
		# would say so.
		out.append("per-ip  : %d max, %d refused" % [
			address_guard.limit, address_guard.refused
		])

	out.append("")
	out.append("# userid name                 state      time   ping  flags addr")

	for session in sessions():
		out.append(session.status_line())

	return out


func describe() -> Dictionary:
	return {
		"state": state_name(),
		"hostname": config.hostname if config != null else "",
		"uptime": uptime_seconds(),
		"players": player_count(),
		"sessions": _sessions.size(),
		"max_players": _cv_maxplayers.get_int() if _cv_maxplayers != null else 0,
		"transport": _transport._transport_name() if _transport != null else "",
		"web_clients": _transport.supports_web_clients() if _transport != null else false,
		"query": query != null and query.is_listening(),
		"a2s": a2s != null,
		"per_ip_limit": address_guard.limit if address_guard != null else 0,
		"per_ip_refused": address_guard.refused if address_guard != null else 0,
		"ban_source": DotRegistry.get_service(BAN_SOURCE) != null,
	}


## The shape [code]DotBackboneClient.report_stats[/code] expects.
func to_stats_report() -> Dictionary:
	return {
		"online": state == State.RUNNING or state == State.HIBERNATING,
		"curUsers": player_count(),
		"maxUsers": _cv_maxplayers.get_int(),
		# The one place that can know: only a game knows which of its entities are
		# bots, and it says so through a DotQueryProvider. Without one this is
		# still 0, which is at least honest about not knowing.
		"bots": query_source.snapshot().bot_count() if query_source != null else 0,
		# null, never "": the backbone's IngestServerStatsInput takes `map` as a
		# non-empty string or null, and a server between games sending "" would
		# have its whole report refused.
		"map": _report_map(),
		"password": _cv_password.get_string() != "",
		"dedicated": DotPlatform.is_headless(),
		"version": VERSION,
	}


## The shape [code]DotBackboneClient.report_users[/code] expects.
func _report_map() -> Variant:
	var id := games.current_content_id() if games != null else ""
	return id if id != "" else null


func to_roster_report() -> Array:
	var out: Array = []
	for session in playing_sessions():
		out.append(session.to_roster_entry())
	return out
