@tool
extends "res://addons/dot_server/server/dot_server_state.gd"

## Session queries, tick rate, hibernation and the status reports of [DotServer].

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


## Every active session connected from [param address]; what an address ban acts on.
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


## The rate the server plays at -- [code]sv_tickrate[/code] as last applied, not the
## engine's, which reads [member DotServerConfig.hibernate_tickrate] while it hibernates.
func tickrate() -> int:
	return config.tickrate


## A [code]sv_tickrate[/code] set while running and not yet applied, or -1.
func pending_tickrate() -> int:
	return _pending_tickrate


## Applies a pending [code]sv_tickrate[/code]. Returns whether the rate changed.
## Called at a boundary the GAME chooses (its map change), because changing the step under a
## moving player splits a run across two rates; a game change applies it regardless.
func apply_pending_tickrate() -> bool:
	if _pending_tickrate < 0:
		return false
	var rate := _pending_tickrate
	_pending_tickrate = -1
	if rate == config.tickrate:
		return false
	config.tickrate = rate
	_apply_tickrate()
	DotLog.info(CHANNEL, "tickrate changed", {"tickrate": rate})
	tickrate_changed.emit(rate)
	return true


func _apply_tickrate() -> void:
	var rate := config.tickrate

	if state == State.HIBERNATING:
		rate = config.hibernate_tickrate

	Engine.physics_ticks_per_second = maxi(1, rate)

	# An unbounded max_fps spins a core on a server with nothing to draw, so match the tickrate.
	# Hibernating, the frame rate is the socket rate: see DotServerConfig.hibernate_frame_rate.
	if DotPlatform.is_headless():
		var frames := rate
		if state == State.HIBERNATING:
			frames = maxi(rate, config.hibernate_frame_rate)
		Engine.max_fps = maxi(1, frames)

	DotLog.debug(CHANNEL, "tickrate applied", {"rate": rate})


## True while a game change is under way: see the connection in [method start].
var _loading_game: bool = false


func _begin_game_load() -> void:
	# A game change is a boundary for every game, including one that never asks.
	apply_pending_tickrate()
	_loading_game = true
	_wake_from_hibernation()


func _end_game_load() -> void:
	_loading_game = false
	call_deferred(&"_maybe_hibernate")


func _maybe_hibernate() -> void:
	if not config.hibernate_when_empty or _loading_game:
		return
	if state != State.RUNNING:
		return
	if player_count() > 0 or not _sessions.is_empty():
		return

	_set_state(State.HIBERNATING)
	_apply_tickrate()
	DotLog.info(CHANNEL, "hibernating (no players)")
	hibernation_changed.emit(true)


func _wake_from_hibernation() -> void:
	if state != State.HIBERNATING:
		return
	_set_state(State.RUNNING)
	_apply_tickrate()
	DotLog.info(CHANNEL, "woke from hibernation")
	hibernation_changed.emit(false)


## Whether the server is hibernating: up, empty, and ticking at
## [member DotServerConfig.hibernate_tickrate].
func is_hibernating() -> bool:
	return state == State.HIBERNATING


## Applies [code]sv_hibernate_when_empty[/code] to a running server at once. Turning it off
## wakes an empty server like any other wake; turning it on hibernates one that is empty now.
func _apply_hibernate_setting(enabled: bool) -> void:
	config.hibernate_when_empty = enabled

	if enabled:
		_maybe_hibernate()
	else:
		_wake_from_hibernation()


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




## The `status` command's output.
func status_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("hostname: %s" % _cv_hostname.get_string())
	# The game's version first: it is the release an operator restarted to get, and the
	# framework constant beside it never changes.
	var game_version := ""
	if games != null and games.current() != null:
		game_version = games.current().version
	out.append("version : %s(dot-server %s, %s)" % [
		(game_version + " ") if game_version != "" else "", VERSION, DotPlatform.kind_name()
	])
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
	out.append("# userid name                 state      time   ping  flags uid                    addr")

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
		"query": query != null and bool(query.call("is_listening")),
		"a2s": a2s != null,
		"per_ip_limit": address_guard.limit if address_guard != null else 0,
		"per_ip_refused": address_guard.refused if address_guard != null else 0,
		"ban_source": DotRegistry.get_service(BAN_SOURCE) != null,
		"log_level": DotLog.level_name(DotLog.get_level()),
		# Named rather than a bool, because "where does the log go" is a question an
		# operator asks of a server that has just lost something, and "true" is not an
		# answer to it.
		"log": _log_destination(),
		"threads": describe_threads(),
	}


## One line: the worker count and cores, what is pooled, and the physics engine, read-only
## from the project because nothing in the process can change it. The figures come from
## dot-core's [DotParallel], whose labels the threaded subsystems name ("net.snapshot").
func describe_threads() -> String:
	var workers := config.worker_threads if config != null else 0
	var resolved := DotParallel.resolve_workers(workers)
	var labels: Dictionary = DotParallel.describe()["labels"]
	var parts := PackedStringArray()
	parts.append("workers %d of %d cores%s" % [
		resolved, OS.get_processor_count(),
		"" if DotParallel.available() else " (no worker pool here)",
	])
	for which: Array in [["net", "net.snapshot", config != null and config.threads_net],
			["npc", "npc.think", config != null and config.threads_npc]]:
		var entry: Dictionary = labels.get(which[1], {})
		if not bool(which[2]):
			parts.append("%s inline (off)" % which[0])
		elif entry.is_empty() or int(entry["pooled"]) == 0:
			parts.append("%s on, nothing pooled yet" % which[0])
		else:
			parts.append("%s pooled (%d items a call, %.1f ms join, p99 %.1f)" % [
				which[0], int(entry["items"]) / maxi(1, int(entry["calls"])),
				float(entry["mean_usec"]) / 1000.0, float(entry["p99_usec"]) / 1000.0,
			])
	var engine := str(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"))
	var separate := bool(ProjectSettings.get_setting("physics/3d/run_on_separate_thread", false))
	parts.append("physics %s, %s" % [engine, "own thread" if separate else "main thread"])
	return "threads: " + "; ".join(parts)


func _log_destination() -> String:
	if log_node == null or not is_instance_valid(log_node):
		return "stdout only"
	if log_is_router:
		return "router: %s" % log_node.name
	if log_node.has_method("describe"):
		var d: Variant = log_node.call("describe")
		if d is Dictionary and (d as Dictionary).has("path"):
			return str((d as Dictionary)["path"])
	return log_node.name


## The shape [code]DotBackboneClient.report_stats[/code] expects.
func to_stats_report() -> Dictionary:
	return {
		"online": state == State.RUNNING or state == State.HIBERNATING,
		"curUsers": player_count(),
		"maxUsers": _cv_maxplayers.get_int(),
		# The one place that can know: only a game knows which of its entities are
		# bots, and it says so through a query provider (dot-server-query). Without
		# one this is still 0, which is at least honest about not knowing.
		"bots": _bot_count(),
		# null, never "": the backbone's IngestServerStatsInput takes `map` as a
		# non-empty string or null, and a server between games sending "" would
		# have its whole report refused.
		"map": _report_map(),
		"password": _cv_password.get_string() != "",
		"dedicated": DotPlatform.is_headless(),
		"version": VERSION,
	}


## Bots, from the query snapshot (duck-typed). Zero with no query addon or no provider.
func _bot_count() -> int:
	if query_source == null or not is_instance_valid(query_source):
		return 0

	var snap: Object = query_source.call("snapshot")
	if snap == null or not snap.has_method("bot_count"):
		return 0

	return int(snap.call("bot_count"))


## The shape [code]DotBackboneClient.report_users[/code] expects.
func _report_map() -> Variant:
	var id := games.reported_map() if games != null else ""
	return id if id != "" else null


func to_roster_report() -> Array:
	var out: Array = []
	for session in playing_sessions():
		out.append(session.to_roster_entry())
	return out
