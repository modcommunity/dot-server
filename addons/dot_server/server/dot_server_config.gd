@tool
class_name DotServerConfig
extends "res://addons/dot_server/server/dot_server_config_base.gd"

## Everything configurable about the server itself, layered like every [DotConfig].
## Most fields are also [DotConVar]s on [DotServer]; this is the boot-time source, cvars the live view.
## Anything not changeable on a running server carries [constant DotConVar.FLAG_STARTUP_ONLY].


## Parses one of the level names this config accepts, or -1.
static func parse_log_level(name: String) -> int:
	var trimmed: String = name.strip_edges().to_lower()
	if trimmed == "warning":
		trimmed = "warn"
	return DotLog.parse_level(trimmed)


func env_prefix() -> String:
	return "DOT_SERVER_"


func cli_prefix() -> String:
	return "--sv-"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["rcon_password", "password", "query_secret"])


func validate() -> DotResult:
	for check: Callable in [_validate_logging, _validate_ports, _validate_transport]:
		var res: DotResult = check.call()
		if not res.ok:
			return res

	return DotResult.success(null)


func _validate_logging() -> DotResult:
	if worker_threads < -1:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"worker_threads must be -1 (automatic), 0 (main thread only) or a count.",
			str(worker_threads)
		)
	if parse_log_level(log_level) < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Unknown log_level '%s'." % log_level,
			"trace, debug, info, warn, error, fatal or off"
		)

	if parse_log_level(log_mirror_min_level) < 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Unknown log_mirror_min_level '%s'." % log_mirror_min_level,
			"trace, debug, info, warn, error, fatal or off"
		)

	for entry: String in log_channel_levels:
		var parts: PackedStringArray = entry.split("=", false, 1)
		if parts.size() != 2 or parse_log_level(parts[1]) < 0:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A channel level must be written channel=level.",
				entry
			)
	return DotResult.success(null)


func _validate_ports() -> DotResult:
	if port < 0 or port > 65535:
		return DotResult.fail(
			DotError.CODE_INVALID, "port must be between 0 and 65535."
		)

	# With an ephemeral game port there is nothing to derive an RCON port from, and
	# port + 1 would be 1 — privileged, and almost certainly not what was meant.
	if port == 0 and rcon_password != "" and rcon_port <= 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"An explicit rcon_port is required when port is 0.",
			"there is no fixed game port to derive one from"
		)

	if reserved_slots >= max_players:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"reserved_slots must be fewer than max_players.",
			"otherwise no ordinary player can ever join"
		)

	if tickrate < 1:
		return DotResult.fail(
			DotError.CODE_INVALID, "tickrate must be at least 1."
		)

	if rcon_password != "" and rcon_password.length() < 8:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"rcon_password must be at least 8 characters.",
			"RCON is a remote shell; a short password is guessed in minutes"
		)

	if effective_rcon_port() == port:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The RCON port must differ from the game port.",
			"both are %d" % port
		)
	return DotResult.success(null)


func _validate_transport() -> DotResult:
	if not ["full", "names", "count", "none"].has(query_player_detail):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"query_player_detail must be full, names, count or none.",
			"got '%s'" % query_player_detail
		)

	if not ["dual", "websocket", "enet"].has(transport_mode):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"transport_mode must be dual, websocket or enet.",
			"got '%s'" % transport_mode
		)

	if enet_port < 0 or enet_port > 65535:
		return DotResult.fail(
			DotError.CODE_INVALID, "enet_port must be between 0 and 65535."
		)

	# Only TCP listeners can collide; query, A2S and ENet ports are UDP. ENet may share the A2S/DQP port
	# through DotTransportDual's demux (enet_share_udp_port); with sharing off the clash is caught at bind time.
	if query_enabled and query_websocket:
		var ws_port := effective_query_websocket_port()
		for taken in [
			["the game port", port],
			["the RCON port", effective_rcon_port()],
			["the RCON WebSocket port", effective_rcon_websocket_port() if rcon_websocket else 0],
		]:
			if ws_port > 0 and ws_port == int(taken[1]):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"The query WebSocket port must differ from %s." % str(taken[0]),
					"both are %d" % ws_port
				)
	return DotResult.success(null)


func warn_about_risky_settings() -> void:
	if rcon_password != "" and rcon_allowed_addresses.is_empty():
		DotLog.warn(
			"server",
			"RCON is enabled with no address allow-list — the password is the "
			+ "only thing protecting it",
			{"setting": "rcon_allowed_addresses"}
		)

	# An entry that can never match is worse than none: the operator believes they have an allow-list.
	# "192.168" is the typical case, a subnet prefix without the trailing dot.
	for raw in rcon_allowed_addresses:
		var entry := DotBanManager.normalise_address(raw)
		if entry == "":
			DotLog.warn(
				"server",
				"an RCON allow-list entry is empty and matches nothing",
				{"setting": "rcon_allowed_addresses"}
			)
			continue

		# A trailing dot is a deliberate prefix; a colon is IPv6; four octets is a
		# whole address. None of those is the mistake being looked for.
		if entry.ends_with(".") or entry.contains(":"):
			continue

		var parts := entry.split(".", false)
		if parts.size() >= 4:
			continue

		var numeric := not parts.is_empty()
		for part in parts:
			if not part.is_valid_int():
				numeric = false
				break

		if numeric:
			DotLog.warn(
				"server",
				"an RCON allow-list entry looks like a subnet prefix but does "
				+ "not end in a dot, so it matches nothing",
				{"entry": raw, "did you mean": entry + "."}
			)

	if bind_address == "*" and password == "":
		DotLog.info(
			"server",
			"listening on every interface with no password (a public server)"
		)

	if a2s_enabled and query_player_detail == "full":
		# A2S publishes names, scores and connection times to anyone who asks, and
		# always has. Worth saying out loud once, because an operator who turned
		# A2S on to be listed may not have meant to publish a roster.
		DotLog.info(
			"server",
			"A2S is enabled: player names, scores and connection times are public",
			{"setting": "query_player_detail"}
		)


func effective_rcon_port() -> int:
	return rcon_port if rcon_port > 0 else port + 1


func effective_rcon_websocket_port() -> int:
	return rcon_websocket_port if rcon_websocket_port > 0 else effective_rcon_port() + 1


## UDP port A2S answers on. 0 when there is none to derive.
## Defaults to the game port, the only one a tracker tries; with a UDP game transport set one explicitly.
func effective_a2s_port() -> int:
	if a2s_port > 0:
		return a2s_port
	return port


## UDP port the dot query protocol answers on. 0 when there is none to derive.
## The same port as A2S by default: the first four bytes tell the two apart, so one socket serves both.
func effective_query_port() -> int:
	if query_port > 0:
		return query_port
	return effective_a2s_port()


## The interface every query listener binds. See [member query_bind_address].
func effective_query_bind_address() -> String:
	var chosen := query_bind_address.strip_edges()

	if chosen != "":
		return chosen

	return bind_address


## TCP port the WebSocket query listener answers on. 0 when there is none to derive.
func effective_query_websocket_port() -> int:
	if query_websocket_port > 0:
		return query_websocket_port
	# +1 and +2 are RCON's. A derived port has to come from somewhere, and the
	# family already derives RCON's from the game port the same way.
	return port + 3 if port > 0 else 0


## Slots available to players without a reservation.
func public_slots() -> int:
	return maxi(0, max_players - reserved_slots)


## The worker count for dot-net's snapshot build: 0 unless [member threads_net] is on, then
## [member worker_threads] (-1 automatic, 0 inline). Never more than DotParallel allows on
## this machine, which it decides itself.
func net_snapshot_workers() -> int:
	return worker_threads if threads_net else 0


## The worker count for NPC decisions and paths, the same way as [method net_snapshot_workers].
func npc_workers() -> int:
	return worker_threads if threads_npc else 0


## UDP port ENet listens on in [code]dual[/code] and [code]enet[/code] modes.
func effective_enet_port() -> int:
	return enet_port if enet_port > 0 else port


## The interface ENet binds. See [member enet_bind_address].
func effective_enet_bind_address() -> String:
	var chosen := enet_bind_address.strip_edges()
	return chosen if chosen != "" else effective_query_bind_address()


## Whether ENet's UDP port is also a query protocol's, so the two need the demux.
func enet_shares_query_port() -> bool:
	var udp := effective_enet_port()
	if udp <= 0:
		return false
	return (a2s_enabled and effective_a2s_port() == udp) \
		or (query_enabled and effective_query_port() == udp)


## The transport, creating one from [member transport_mode] if none was configured.
func resolve_transport() -> DotTransport:
	if transport == null:
		transport = _build_transport()

	transport.max_clients = max_players
	return transport


func _build_transport() -> DotTransport:
	var can_enet := DotPlatform.has_udp() and ClassDB.class_exists("ENetMultiplayerPeer")

	if transport_mode == "enet" and can_enet:
		return DotTransportENet.new()

	if transport_mode == "dual" and can_enet:
		var dual := DotTransportDual.new()
		dual.enet_port = effective_enet_port()
		dual.enet_bind_address = effective_enet_bind_address()
		# The demux costs a relay hop per ENet packet; pay it only when a query
		# protocol really is on the same UDP port.
		dual.share_udp_port = enet_share_udp_port and enet_shares_query_port()
		return dual

	if transport_mode != "websocket":
		DotLog.warn(
			"server",
			"transport_mode %s needs ENet, which this build has not got; using WebSocket"
			% transport_mode
		)

	var auto := DotTransportAuto.new()
	auto.require_web_clients = true
	return auto
