@tool
extends "res://addons/dot_server/server/dot_server_signon.gd"

## Peer connect and disconnect, session adoption and target lookup of [DotServer].

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

	# Awake from the connect, not the spawn: the client syncs its clock and sends commands long
	# before it spawns, and a server still at hibernate_tickrate starved on them. A connect that
	# never spawns sleeps again on its disconnect.
	_wake_from_hibernation()

	client_state_changed.emit(session)

	if events != null:
		events.fire("client_connect", {"userid": session.userid, "address": address})

	# Ask the client to identify itself. Everything from here is driven by the
	# client's reply or by the auth timeout.
	send_kind(peer_id, DotEnvelope.CHALLENGE, _handshake_challenge(session))


func _on_peer_disconnected(peer_id: int) -> void:
	envelope.forget(peer_id)
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


## Registers a connectionless protocol on the game's UDP port when the transport demuxes it.
## Returns false when it does not, and the caller binds its own socket.
## Duck-typed like [method attach_query_host].
func share_udp_port(port: int, claim: Callable, handle: Callable) -> bool:
	if _transport == null or not _transport.has_method("add_datagram_handler"):
		return false
	return bool(_transport.call("add_datagram_handler", port, claim, handle))


## Removes a handler [method share_udp_port] registered.
func unshare_udp_port(handle: Callable) -> void:
	if _transport == null or not _transport.has_method("demux"):
		return
	var demux: Variant = _transport.call("demux")
	if demux != null:
		demux.remove_handler(handle)


## The UDP port native clients reach ENet on, or 0 when this server has no ENet.
## Advertised by the query protocols so a native client knows to try it.
func enet_port() -> int:
	if _transport == null:
		return 0
	if _transport.has_method("advertised_enet_port"):
		return int(_transport.call("advertised_enet_port"))
	if _transport.scheme() == "udp":
		return config.port
	return 0


## Which backend a peer is on: "websocket", "enet", or "" when the transport has
## only one.
func peer_transport(peer_id: int) -> String:
	if _peer != null and _peer.has_method("backend_name"):
		return str(_peer.call("backend_name", peer_id))
	return ""


func _address_of(peer_id: int) -> String:
	if _peer == null:
		return ""

	# WebSocket and ENet expose the remote address through different methods, and
	# neither is on the MultiplayerPeer base class. DotDualPeer answers for both.
	if _peer.has_method("get_peer_address"):
		var address: Variant = _peer.call("get_peer_address", peer_id)
		if address != null and str(address) != "":
			return str(address)

	# ENet alone: the address is on the packet peer, not the multiplayer peer.
	# Before this a native-only server logged, rate-limited and banned "unknown".
	if _peer.has_method("get_peer"):
		var packet_peer: Variant = _peer.call("get_peer", peer_id)
		if packet_peer is Object and packet_peer.has_method("get_remote_address"):
			return str(packet_peer.call("get_remote_address"))

	return "unknown"


## Adds a session this server did not create from a socket (a bot, a local player, a test).
## Everything that counts players counts sessions, so a participant without one is invisible.
## Refuses a peer id already in use.
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


## Runs a console command as the person a uid names, and returns the reply lines.
## For a relay with no game connection. Permissions are the uid's own from the admin file, not ROOT's;
## [param source] defaults to [code]CHAT[/code], so [method DotConCommand.no_chat] commands stay withheld.
func run_command_as_uid(
	uid: String,
	command: String,
	args: PackedStringArray,
	source: DotCmdContext.Source = DotCmdContext.Source.CHAT
) -> PackedStringArray:
	var lines := PackedStringArray()

	if console == null or admins == null:
		return lines

	var held: Dictionary = admins.uid_permissions(uid)

	var ctx := DotCmdContext.new()
	ctx.source = source
	ctx.command_name = command
	ctx.arguments = args
	ctx.permissions = held["flags"] as PackedStringArray
	ctx.immunity = int(held["immunity"])
	ctx.reply_sink = func(line: String) -> void: lines.append(line)

	var line := command

	for arg in args:
		line += " " + arg

	console.execute(line, ctx)

	if audit != null:
		audit.record("command_as_uid", uid, command, {
			"args": Array(args),
			"flags": Array(held["flags"]),
		})

	return lines


## Finds sessions by userid, name, username, account id or address; every match, so a command can refuse an ambiguous one.
## Precedence: `#12`/`12` userid, `@me`, `ip:ADDR` (several on purpose), exact name, exact username, `backbone:<id>`, then substring.
## Exact forms win, or a name that is another's prefix is unbannable.
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
## Fails with a showable message when nobody matched, several matched, or the target outranks the caller.
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
