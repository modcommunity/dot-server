@tool
extends "res://addons/dot_server/server/dot_server_admission.gd"

## Handshake, PROFILE stage, authentication and content sync of [DotServer].

func _handshake_challenge(session: DotClientSession) -> Dictionary:
	var challenge := _handshake_fields(session)

	# Which backbone target a join token must name to be spent here: an INTROSPECT client mints a
	# single-use token for this audience instead of handing over its access token. A field, so an
	# older client ignores it.
	var audience := _auth_join_audience()
	if audience != "":
		challenge["join_audience"] = audience

	# Added only when there is something to say: a field, so a client that predates it
	# ignores it -- the envelope's rule for changing a payload.
	if not addon_set.is_empty():
		challenge["addons"] = addon_set.duplicate(true)

				# Where to fetch them from, which a native client learns only with the first `content.sync`,
				# after this. Only addresses: packs still verify against a key the client already holds.
		if not config.content_base_urls.is_empty():
			challenge["content_base_urls"] = Array(config.content_base_urls)

	return challenge


func _handshake_fields(session: DotClientSession) -> Dictionary:
	return {
		"protocol": DotSignon.PROTOCOL,
				# The RPC surface, so a client that cannot finish this join can say why instead of timing out.
				# Godot refuses an RPC when the two ends declare different `@rpc` methods. It rides on the
				# challenge because that still arrives after the checksum has failed. See [DotSignon].
		"signon": DotSignon.revision([DotServer]),
		# [b]Everything this server can say and hear, and which of it a client must know.[/b]
		# The client answers with its own; the server compares them when the answer arrives
		# and refuses a pair that cannot play, with a sentence. See [DotEnvelope].
		"kinds": envelope.advert(),
		"hostname": _cv_hostname.get_string(),
		"server_id": config.server_id,
		"needs_password": _cv_password.get_string() != "",
		"userid": session.userid,
		# The strategy tells the client which credential to send. Without it a
		# client would have to guess, or send everything it has.
		"auth": _auth_strategy_name(),
		"ticket_nonce": _ticket_nonce_for(session),
	}


## The client asks for a ticket bound to this, so one copied off the wire is refused
## on every other connection.
func _ticket_nonce_for(session: DotClientSession) -> String:
	if session.ticket_nonce == "":
		session.ticket_nonce = DotHash.random_token(16)
	return session.ticket_nonce


func _auth_strategy_name() -> String:
	var auth := DotRegistry.get_service(&"dot_auth_server")
	if auth == null:
		return "none"
	if auth.has_method("strategy_name"):
		return str(auth.call("strategy_name")).to_lower()
	return "unknown"


func _auth_join_audience() -> String:
	var auth := DotRegistry.get_service(&"dot_auth_server")
	if auth == null or not auth.has_method("join_audience"):
		return ""
	return str(auth.call("join_audience"))


## A client's answer to the challenge. The one unauthenticated entry point, so everything it
## touches is bounded: fields are validated, the password compare is constant-time, and a failure
## closes the connection.
func _on_credentials(peer_id: int, payload: Dictionary) -> void:
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

	if not _accept_hello(session, peer_id, payload):
		return

	if _password_refused(session, payload):
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

	_take_seat(session)

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

	_enter_profile(session)


## False (and the session rejected) when the client's protocol or platform is refused.
func _accept_hello(session: DotClientSession, peer_id: int, payload: Dictionary) -> bool:
	# First, so a client too old to play reads "needs a newer game client" instead of
	# waiting out an auth timeout.
	var compatible := envelope.adopt(peer_id, payload.get("kinds"), true)
	if not compatible.ok:
		DotLog.info(CHANNEL, "client refused: it cannot speak this server's protocol", {
			"userid": session.userid,
			"from": session.address,
			"why": compatible.error.message,
			"detail": compatible.error.detail,
		})
		_reject_session(session, compatible.error.message, compatible.error)
		return false

	var requested_name := str(payload.get("name", "")).strip_edges()
	if requested_name != "":
		session.display_name = requested_name.substr(0, 32)

	# Before the password and authentication: no sign-in round trip for a refused platform.
	session.platform = str(payload.get("platform", "")).strip_edges().to_lower()
	var platform_refusal := platform_refusal_for(session.platform)
	if platform_refusal != "":
		DotLog.info(CHANNEL, "client refused: this server does not take its platform", {
			"userid": session.userid,
			"from": session.address,
			"platform": session.platform,
		})
		_reject_session(session, platform_refusal)
		return false
	return true


## True (and the session rejected) when the server has a password and the payload's differs.
## Checked before authentication so an unauthenticated client cannot probe the auth path.
func _password_refused(session: DotClientSession, payload: Dictionary) -> bool:
	var server_password := _cv_password.get_string()
	if server_password == "":
		return false
	var supplied := str(payload.get("password", ""))
	if DotHash.constant_time_equal(supplied.to_utf8_buffer(), server_password.to_utf8_buffer()):
		return false
	DotLog.info(CHANNEL, "wrong server password", {"userid": session.userid, "from": session.address})
	_reject_session(session, "Incorrect server password.")
	return true


## Puts an authenticated session in [constant DotClientSession.State.PROFILE] and lets it
## through at once unless something holds it. A stage, not a spawn hook: it is the last point at
## which a refusal takes nothing back. Holders claim it synchronously from [signal client_state_changed].
func _enter_profile(session: DotClientSession) -> void:
	# The credentials handler awaited authentication; the player may have gone meanwhile.
	if not session.is_active():
		return

	if not session.transition_to(DotClientSession.State.PROFILE):
		return

	client_state_changed.emit(session)

	# A holder may already have released, or refused, from inside its handler: a module
	# that decides synchronously. Only a session still in the stage with nobody holding
	# it moves on here, so it is never advanced twice.
	if session.state == DotClientSession.State.PROFILE and session.profile_holds.is_empty():
		_advance_to_content(session)
		return

	if session.state == DotClientSession.State.PROFILE:
		DotLog.debug(CHANNEL, "client held in the profile stage", {
			"user": session.label(),
			"by": ", ".join(session.profile_holds),
		})


## Holds [param session] in the PROFILE stage until [param holder] releases it.
## False, holding nothing, when the session is past PROFILE. Call it from a [signal client_state_changed]
## handler before awaiting; the stage has its own deadline, [member DotServerConfig.profile_timeout_sec].
func hold_profile(session: DotClientSession, holder: String) -> bool:
	if session == null or not session.is_active():
		return false
	if session.state != DotClientSession.State.PROFILE:
		return false
	if holder == "":
		push_error("hold_profile needs a holder name, so it can be released")
		return false
	if not session.profile_holds.has(holder):
		session.profile_holds.append(holder)
	return true


## Releases [param holder]'s hold. The last release sends the player on to content.
## Safe for a session that has left the stage, been refused or gone.
func release_profile(session: DotClientSession, holder: String) -> void:
	if session == null or session.state != DotClientSession.State.PROFILE:
		return

	var at := session.profile_holds.find(holder)
	if at < 0:
		return
	session.profile_holds.remove_at(at)

	if session.profile_holds.is_empty() and session.is_active():
		_advance_to_content(session)


## Refuses a player still in the PROFILE stage: they are told [param reason] and never appear.
## False when the session is past PROFILE and has to be kicked instead. A refusal, not a kick: the
## session is REJECTED, with no kicked event and no leave line, because nobody saw them join.
func refuse_profile(session: DotClientSession, reason: String, why: DotError = null) -> bool:
	if session == null or not session.is_active():
		return false
	if session.state != DotClientSession.State.PROFILE:
		return false

	DotLog.info(CHANNEL, "client refused in the profile stage", {
		"user": session.label(),
		"reason": reason,
	})
	_reject_session(session, reason, why)
	return true


## The sentence a client of [param platform] is refused with, or "" to admit it.
## A client naming no platform, or an unrecognised one, is admitted: this is an owner's switch,
## not a whitelist, and old builds send none.
func platform_refusal_for(platform: String) -> String:
	match platform:
		"web":
			if _cv_allow_web != null and not _cv_allow_web.get_bool():
				return "This server does not take players in a web browser. Join it from the TMC desktop app."
		"desktop":
			if _cv_allow_desktop != null and not _cv_allow_desktop.get_bool():
				return "This server does not take players on the desktop client. Join it from the website."
		"mobile":
			if _cv_allow_mobile != null and not _cv_allow_mobile.get_bool():
				return "This server does not take players on a phone or tablet."
	return ""


## The platforms this server admits right now, for a query answer or a listing.
func allowed_platforms() -> PackedStringArray:
	var out := PackedStringArray()
	for pair in [["web", _cv_allow_web], ["desktop", _cv_allow_desktop], ["mobile", _cv_allow_mobile]]:
		var cv: DotConVar = pair[1]
		if cv == null or cv.get_bool():
			out.append(pair[0])
	return out


## Runs dot-auth if it is present, or admits everyone as a guest. Null after rejecting the session.
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

	# Our own copy of the challenge nonce, never the client's; an older dot-auth takes two.
	var res: Variant
	if auth.get_method_argument_count("authenticate") >= 3:
		res = await auth.call("authenticate", credential, session.address, session.ticket_nonce)
	else:
		res = await auth.call("authenticate", credential, session.address)

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
## Duck-typed to what [DotClientSession] reads. See [DotGuestIdentity].
func _guest_identity(
	session: DotClientSession,
	payload: Dictionary
) -> Object:
	return DotGuestIdentity.from_device(
		str(payload.get("device_id", "")), session.display_name
	)


## Under `sv_single_seat`, an account signing in again replaces its older connection:
## newest wins, so a player whose old connection is still timing out can come back.
func _take_seat(session: DotClientSession) -> void:
	if _cv_single_seat == null or not _cv_single_seat.get_bool() or not session.is_account():
		return
	var uid := session.uid()
	if uid == "":
		return
	for other in sessions():
		if other != session and other.is_active() and other.is_authenticated() and other.uid() == uid:
			DotLog.info(CHANNEL, "account signed in again; replacing its older connection", {
				"user": session.label(), "old_userid": other.userid,
			})
			kick(other, "You signed in from another connection.")


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

		# Having an address is not the same as having content to fetch: a pack is findable by id, so a
		# delivered game needs no URL. The game says whether it is delivered; the URL only says where from.
	var delivered := games != null and games.current_needs_content()

	if manifest_url == "" and not delivered:
		session.transition_to(DotClientSession.State.LOADING)
		client_state_changed.emit(session)
		_send_load_game(session)
		return

	session.transition_to(DotClientSession.State.DOWNLOADING)
	session.content_progress = 0.0
	client_state_changed.emit(session)

	send_kind(session.peer_id, DotEnvelope.CONTENT_SYNC, content_sync_info(
		manifest_url,
		# Documented on the descriptor since the first version and sent by nothing,
		# so a game that named optional groups had every client fetch only the
		# required set and then miss the assets the groups held.
		games.current_content_groups() if games != null else [],
		games.current_content_key() if games != null else "",
		games.current_dependencies() if games != null else PackedStringArray()
	))


## The payload that tells a client what to download and where from.
## Built here because the join path and [DotGameManager] both send it; two copies of config-derived
## fields drifted (`content_base_urls` reached only the join path). There is one copy.
func content_sync_info(
	manifest_url: String,
	content_groups: Array,
	content_key: String,
	dependencies: PackedStringArray = PackedStringArray()
) -> Dictionary:
	return {
		"manifest_url": manifest_url,
		"content_groups": content_groups,
		"content_key": content_key,
		# The game's other packs, `<id>@<version>` each. A payload field rather than an
		# RPC, so the signon revision does not move: a shell from before this ignores
		# it and still joins a game that has no dependencies.
		"content_extra": Array(dependencies),
		"allow_netchan": config.allow_netchan_content,
		"chunk_bytes": config.netchan_chunk_bytes,
				# Sent with every sync, not once at the handshake: a client that connected before an
				# operator corrected the setting would otherwise keep the old answer until it reconnected.
		"content_base_urls": config.content_base_urls,
	}


## A client reporting content-sync progress.
## Advisory (it drives `status` only), so it is clamped rather than validated.
func _on_content_progress(peer_id: int, payload: Dictionary) -> void:
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return

	session.touch()
	session.content_progress = clampf(DotEnvelope.number(payload, "fraction", 0.0), 0.0, 1.0)


## A client reporting that content is ready.
func _on_content_ready(peer_id: int, payload: Dictionary) -> void:
	var content_key := DotEnvelope.text(payload, "content_key")
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return

	session.touch()

	if session.state != DotClientSession.State.DOWNLOADING:
		return

		# The pending game counts, not only the current one: during a `changelevel` the key a client
		# correctly reports is the one the server is not running yet. Comparing the current game alone
		# rejected every client on every content-bearing change; builtin-only suites cannot see it.
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

		# Not while a change is still syncing: `load_info()` describes the OLD game until the swap,
		# so sending it told the first finisher to load the game it was in. [DotGameManager._swap_to]
		# sends the real one to every session in LOADING once the new scene is live.
	if games != null and games.phase == DotGameManager.Phase.SYNCING:
		return

	_send_load_game(session)


func _send_load_game(session: DotClientSession) -> void:
	var info := {}
	if games != null:
		info = games.load_info()

	# The rules first, on the same reliable ordered lane, so a client's scene starts with
	# the server's values already in its link rather than predicting a few ticks under its
	# own defaults. Again on every game change: the new game's module registered its own.
	_send_replicated_cvars(session)
	send_kind(session.peer_id, DotEnvelope.LOAD_GAME, info)


# Replicated cvars: the whole FLAG_REPLICATED table goes before each LOAD_GAME, and a change or a
# late-registered cvar goes as a delta to every client that has had the table. A client that does
# not know the kind keeps its own defaults.


## A client reporting that it has finished loading and is ready to play.
func _on_loaded(peer_id: int, _payload: Dictionary) -> void:
	var session: DotClientSession = _sessions.get(peer_id)
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
		# Before the join line, not after: the first thing a client hears about chat
		# should be what is carrying it, so it can decide whether to draw a box at all
		# rather than drawing one and taking it away a moment later.
		chat.greet(session)
		chat.announce_join(session)

	_wake_from_hibernation()


## A client's keepalive and ping sample.
func _on_heartbeat(peer_id: int, payload: Dictionary) -> void:
	var client_time_ms := int(DotEnvelope.number(payload, "t", 0))
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return

	session.touch()

		# A heartbeat means the client's main loop is running, whatever it last announced. Self-correcting
		# on purpose: the "I am back" announcement can be missed, and a session left flagged would keep
		# a grace it no longer needs.
	if session.backgrounded:
		session.backgrounded = false
		session.background_grace_sec = 0.0

		# "sv" is the server's own frame for net_stat: frames a second, their deviation in ms and the
		# tick rate. A new key in a Dictionary, so an older client or server is unaffected.
	send_kind(peer_id, DotEnvelope.HEARTBEAT_ACK, {
		"t": client_time_ms,
		"sv": {
			"fps": snappedf(1000.0 / _frame_ms, 0.1) if _frame_ms > 0.0 else 0.0,
			"var_ms": snappedf(_frame_dev_ms, 0.01),
			"tick": tickrate(),
		},
	}, DotEnvelope.Lane.UNRELIABLE)


## A client reporting its measured round-trip time.
func _on_ping(peer_id: int, payload: Dictionary) -> void:
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return
	session.touch()
	session.ping_ms = clampi(int(DotEnvelope.number(payload, "ms", 0)), 0, 60_000)
