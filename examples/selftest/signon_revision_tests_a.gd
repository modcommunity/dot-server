extends "res://examples/selftest/signon_revision_base.gd"

## signon_revision selftest sections, part a.

## [b]This is the section that would have prevented the bug.[/b]
##
## Every `@rpc` on [DotServer] has a counterpart on [DotClientLink] and every one on
## [DotChatManager] has one on [DotClientChat] -- not because it is tidy, but because
## Godot compares the name sets and refuses the pair when they differ. The suite asserts
## the sets rather than the count, so a rename is caught as loudly as an addition and
## the failure names the method.
func _test_the_two_sides_agree() -> void:
	_section("the two sides of the handshake declare the same methods")

	var server_names := DotSignon.rpc_method_names([DotServer, DotChatManager])
	var client_names := DotSignon.rpc_method_names([DotClientLink, DotClientChat])

	# [b]The surface is frozen, and this is the check that holds it.[/b] Exactly the six
	# envelope names on each end, and none at all on the chat pair that used to carry
	# two of their own: a feature is a kind now, and a seventh method is the protocol
	# break the envelope exists to end.
	var frozen := PackedStringArray(DotSignon.ENVELOPE)
	_check(
		server_names == frozen,
		"the server declares exactly the six envelope rpcs",
		"it declares: %s -- add a kind to DotServer.envelope, not an @rpc" % ", ".join(server_names)
	)
	_check(
		client_names == frozen,
		"and so does the client",
		"it declares: %s" % ", ".join(client_names)
	)
	_check(
		DotSignon.rpc_method_names([DotChatManager, DotClientChat]).is_empty(),
		"and the chat nodes declare none: chat is two kinds now"
	)

	_check(
		not server_names.is_empty(),
		"the server side declares rpc methods (%d)" % server_names.size()
	)
	_check(
		not client_names.is_empty(),
		"the client side declares rpc methods (%d)" % client_names.size()
	)

	var only_server := _missing_from(server_names, client_names)
	var only_client := _missing_from(client_names, server_names)

	_check(
		only_server.is_empty(),
		"every server rpc has a client counterpart",
		"DotClientLink/DotClientChat are missing: %s" % ", ".join(only_server)
	)
	_check(
		only_client.is_empty(),
		"every client rpc has a server counterpart",
		"DotServer/DotChatManager are missing: %s" % ", ".join(only_client)
	)

	# The consequence, stated as the thing a deployment actually depends on.
	_check(
		DotSignon.revision([DotServer]) == DotSignon.revision([DotClientLink]),
		"so a client built from this tree can join a server built from it"
	)

	_done()

func _test_the_revision_is_derived() -> void:
	_section("the revision is derived from the declaration, not written down")

	var rev := DotSignon.revision([DotServer, DotChatManager])

	_check(rev != "", "it is not empty (%s)" % rev)
	_check(
		rev.length() == DotSignon.REVISION_LENGTH,
		"and is %d characters" % DotSignon.REVISION_LENGTH
	)
	_check(
		rev == DotSignon.revision([DotChatManager, DotServer]),
		"the order the scripts are passed in does not change it",
		"two servers that loaded their scripts in different orders would disagree"
	)

	# [b]An empty answer must not be a hash.[/b] A build that cannot read the rpc
	# config -- an engine without `get_rpc_config` -- has to say so, because a hash of
	# nothing is a specific twelve characters that every other build would read as a
	# real revision and refuse.
	_check(
		DotSignon.revision([]) == "",
		"a side that cannot answer reports nothing rather than a hash of nothing"
	)

	# Empty on EITHER side is not a mismatch: a server older than this class sends no
	# revision, and refusing it would break every client against every server deployed
	# before this landed -- which is the failure this whole thing exists to prevent,
	# arrived at from the other direction.
	_check(DotSignon.compatible(rev, ""), "an older server is not refused")
	_check(DotSignon.compatible("", rev), "and neither is an older client")
	_check(DotSignon.compatible(rev, rev), "the same revision is compatible")
	_check(
		not DotSignon.compatible(rev, "0123456789ab"),
		"a different one is not"
	)

	var err := DotSignon.explain(rev, "0123456789ab")
	_check(
		err.code == DotError.CODE_UNSUPPORTED,
		"and explaining it gives CODE_UNSUPPORTED rather than a network error",
		"a player told 'connection failed' will retry for ever"
	)
	_check(
		err.detail.contains(rev) and err.detail.contains("0123456789ab"),
		"naming both revisions, because the next question is always which"
	)

	_done()

func _test_a_real_join_carries_it() -> bool:
	_section("a real join carries the revision")

	_link = DotClientLink.new()
	# "Server", the same as DotServer. The name is the routing.
	_link.name = "Server"
	_link.player_name = "Joiner"
	_client_side.add_child(_link)

	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _refused[0] = reason)

	var connecting: DotResult = await _link.connect_to_server("127.0.0.1:%d" % PORT)

	if not _check(connecting.ok, "the client connects", str(connecting.error)):
		_done()
		return false

	var admitted := await _until(
		func() -> bool: return _spawned[0] or _refused[0] != ""
	)

	if not _check(admitted, "and finishes signon", "refused: %s" % _refused[0]):
		_done()
		return false

	# The round trip is known within a second of joining, not after the first two-second
	# heartbeat: every game's clock takes its input lead from it (DotClientLink._enter_playing).
	var joined_ms := Time.get_ticks_msec()
	var measured := await _until(func() -> bool: return _link.ping_ms() >= 0, 1.0)
	_check(measured, "the client knows its round trip within a second of joining (%d ms after)" % (Time.get_ticks_msec() - joined_ms))
	_check(_link.rtt_ms() > 0.0 or _link.ping_ms() == 0, "and rtt_ms() answers (%.1f ms)" % _link.rtt_ms())

	# A dual-stack server and a native client: the join is over UDP unless told otherwise.
	_check(
		_link.transport_used == "enet" and _server.peer_transport(_first_peer()) == "enet",
		"over ENet, which a native client tries first (%s)" % _link.transport_used
	)

	_check(
		_link.server_signon == DotSignon.revision([DotServer]),
		"and kept the server's revision (%s)" % _link.server_signon,
		"the challenge did not carry one, so no browser can read it either"
	)
	_check(
		_link.envelope.knows_peer(1) and _server.envelope.knows_peer(_first_peer()),
		"and each end has the other's kinds",
		"the adverts did not ride the challenge and the credentials"
	)
	_check(
		_link.server_addons.size() == 1
			and str((_link.server_addons[0] as Dictionary).get("id", "")) == "modcommunity/dot-ui"
			and str((_link.server_addons[0] as Dictionary).get("version", "")) == "9.9.9",
		"and the addon versions the server runs rode the challenge",
		str(_link.server_addons)
	)

	# Nothing to announce is nothing on the wire: the next joins read an empty list.
	_server.addon_set = []

	_done()
	return true

## [b]FLAG_REPLICATED meant nothing on the wire until this.[/b] A game rule a client predicts
## under (dot-combat's mp_teammate_passthrough) is a replicated cvar, and a client that never
## hears it predicts under its own default. The table rides before LOAD_GAME; a cvar a module
## registers later, and every change, arrives as a delta; a protected or plain cvar never does.
func _test_replicated_cvars_reach_the_client() -> void:
	_section("replicated cvars reach the client, live, and nothing else does")

	_check(_link.replicated_cvar("sv_cheats") == "0" and _link.replicated_cvar("sv_allow_web") == "1",
		"the join carried the server's replicated cvars (%s)" % str(_link.replicated_cvars))
	_check(not _link.replicated_cvars.has("hostname") and not _link.replicated_cvars.has("sv_password"),
		"and no cvar without the flag, protected or not")

	var heard: Array = []
	_link.replicated_cvar_changed.connect(func(n: String, v: String) -> void: heard.append([n, v]))

	var rule := _server.console.cvar("mp_signon_test_rule", "1", "a game rule a client predicts under",
		DotConVar.FLAG_REPLICATED | DotConVar.FLAG_NOTIFY)
	var secret := _server.console.cvar("mp_signon_test_secret", "hunter2", "replicated but protected",
		DotConVar.FLAG_REPLICATED | DotConVar.FLAG_PROTECTED)
	var plain := _server.console.cvar("mp_signon_test_plain", "5", "a server-only knob")

	_check(await _until(func() -> bool: return _link.replicated_cvar("mp_signon_test_rule") == "1", 5.0),
		"a replicated cvar a module registers mid-game reaches a playing client")

	var _set := rule.set_value("2")
	_check(await _until(func() -> bool: return _link.replicated_cvar("mp_signon_test_rule") == "2", 5.0),
		"and so does its change")
	_check(heard.has(["mp_signon_test_rule", "2"]), "announced by name and value (%s)" % str(heard))

	var _s2 := secret.set_value("swordfish")
	var _s3 := plain.set_value("6")
	var _s4 := rule.set_value("0")
	await _until(func() -> bool: return _link.replicated_cvar("mp_signon_test_rule") == "0", 5.0)
	_check(not _link.replicated_cvars.has("mp_signon_test_secret") and not _link.replicated_cvars.has("mp_signon_test_plain"),
		"a protected one and a plain one never arrive, registered or changed")

	var before := heard.size()
	_link._on_cvars(1, {"values": {"mp_signon_test_rule": "0"}, "full": false})
	_check(heard.size() == before, "a value that did not change is not announced again")
	_link._on_cvars(1, {"values": "not a table"})
	_link._on_cvars(1, {"values": {"x".repeat(200): "1", 7: "2"}})
	_check(_link.replicated_cvar("mp_signon_test_rule") == "0" and not _link.replicated_cvars.has("x".repeat(200)),
		"a malformed table, an oversized name and a non-string name change nothing")

	_server.console.unregister_cvar("mp_signon_test_rule")
	_server.console.unregister_cvar("mp_signon_test_secret")
	_server.console.unregister_cvar("mp_signon_test_plain")
	_done()

## [b]Driven through the challenge handler directly, and that is the only way to reach
## it.[/b] Producing a REAL mismatch would mean two builds of this addon in one process
## -- two scripts declaring different rpc sets under the same class names -- which
## GDScript cannot express. What can be exercised is the half that matters: a challenge
## carrying a revision this build does not match must be refused immediately, with an
## error that says what it is, rather than being answered and then falling silent.
func _test_a_mismatch_is_refused_at_once() -> void:
	_section("a client that cannot match the server is told so at once")

	_refused[0] = ""

	_link._on_challenge(1, {
		"protocol": DotSignon.PROTOCOL,
		"hostname": "Somewhere Else",
		"server_id": "",
		"needs_password": false,
		"auth": "none",
		"signon": "0123456789ab",
	})

	_check(
		_link.phase == DotClientLink.Phase.FAILED,
		"the client fails rather than answering",
		"phase is %s" % DotClientLink.phase_name(_link.phase)
	)
	_check(
		_link.last_error != null
			and _link.last_error.code == DotError.CODE_UNSUPPORTED,
		"with CODE_UNSUPPORTED",
		"got %s" % (str(_link.last_error) if _link.last_error != null else "nothing")
	)
	_check(
		_refused[0] != "",
		"and it disconnects rather than sitting on a socket that cannot work",
		"a client left connected is a slot the server holds until it times out"
	)
	# [b]The refusal must not throw away what it refused.[/b] A shell telling its page
	# "this server wants build X" reads `server_signon` off the link after the
	# disconnect, and this was assigned past the early return -- so the one case it
	# exists for was the one case it was empty.
	_check(
		_link.server_signon == "0123456789ab",
		"and it kept the revision the server asked for (%s)" % _link.server_signon,
		"a page cannot offer the right build if the client discarded its name"
	)

	# The one change names cannot express: the same revision, a different PROTOCOL.
	var protocol_link := DotClientLink.new()
	add_child(protocol_link)
	protocol_link._on_challenge(1, {
		"protocol": DotSignon.PROTOCOL + 1,
		"hostname": "Elsewhere",
		"signon": DotSignon.revision([DotClientLink]),
	})
	_check(
		protocol_link.phase == DotClientLink.Phase.FAILED
			and protocol_link.last_error != null
			and protocol_link.last_error.code == DotError.CODE_UNSUPPORTED,
		"a server on another signon protocol is refused the same way"
	)
	protocol_link.queue_free()

	_done()

## [b]An older client meets a newer server.[/b] The client has never heard of notices or
## chat lines -- an older build that predates them -- and the server has a kind of its own
## the client has never heard of. The join must complete, the server must not send what the
## client does not know, and what arrives anyway must be dropped rather than break
## anything.
func _test_an_older_client_on_a_newer_server() -> void:
	_section("an older client joins a newer server")

	_server.envelope.register(&"skew.server_news")

	var old := _new_link("OldClient", func(link: DotClientLink) -> void:
		link.envelope.unregister(DotEnvelope.NOTICE)
		link.envelope.unregister(DotEnvelope.CHAT_LINE)
		link.envelope.unregister(DotEnvelope.CVARS)
	)

	var joined := await _join(old)
	if not _check(joined == "", "it joins and plays", joined):
		_server.envelope.unregister(&"skew.server_news")
		_done()
		return

	_check(old.server_addons.is_empty(), "a server announcing no addons sends no list", str(old.server_addons))

	var peer := _peer_of("OldClient")
	var session: DotClientSession = _server.session_of(peer)

	_check(
		not _server.envelope.peer_knows(peer, DotEnvelope.NOTICE),
		"the server knows this client has no notices"
	)
	var skipped := _server.envelope.skipped_sends
	_check(
		not _server.send_notice(session, DotNotice.make(&"cue", "not for you")),
		"so a notice to it is not sent"
	)
	_check(
		not _server.send_kind(peer, &"skew.server_news", {"x": 1}, DotEnvelope.Lane.EVENT),
		"and nor is the newer server's own kind"
	)
	_check(
		_server.envelope.skipped_sends == skipped + 2,
		"and both are counted as not sent (%d)" % (_server.envelope.skipped_sends - skipped)
	)
	_check(
		old.replicated_cvars.is_empty() and not _server._send_replicated_cvars(session),
		"a client without the cvars kind is sent no table and keeps its own defaults"
	)

	# Put an unknown kind on the wire anyway, as a server that did not filter would.
	var dropped := old.envelope.dropped_arrivals
	_server._dot_down_event.rpc_id(peer, "skew.server_news", {"x": 1})
	_server._dot_down.rpc_id(peer, String(DotEnvelope.NOTICE), {"cue": "raw"})
	var ignored := await _until(func() -> bool: return old.envelope.dropped_arrivals >= dropped + 2, 5.0)
	_check(ignored, "what it has never heard of is dropped on arrival (%d)" % (old.envelope.dropped_arrivals - dropped))

	# And it is still in the game: its heartbeat still reaches the server.
	old._send_heartbeat()
	var alive := await _until(func() -> bool: return old.ping_ms() >= 0, 5.0)
	_check(alive and old.is_playing(), "and it goes on playing (ping %d ms)" % old.ping_ms())
	# net_stat's source: the link's peer is metered, and the heartbeat fed it.
	var meter := old.net_meter()
	_check(meter != null and meter.bytes_in > 0 and meter.bytes_out > 0 and meter.rtt_ms >= 0.0,
		"its connection is metered, and the heartbeat gave the meter its ping (%s)" % [meter.describe() if meter != null else "no meter"])
	_check(meter != null and int(meter.remote.get("tick", 0)) > 0 and meter.remote.has("fps"),
		"and the server's own frame rate and tick came back with it (%s)" % [meter.remote if meter != null else {}])
	_check(
		session != null and session.is_playing(),
		"without the server having dropped it"
	)

	_drop_link(old)
	_server.envelope.unregister(&"skew.server_news")
	_done()

## [b]A newer client meets an older server.[/b] The client has a kind of its own the server
## has never heard of, and sends it; the server has no notices (an older build). The join
## completes and the newer kind is ignored.
func _test_a_newer_client_on_an_older_server() -> void:
	_section("a newer client joins an older server")

	_server.envelope.unregister(DotEnvelope.NOTICE)

	var heard := [0]
	var newer := _new_link("NewClient", func(link: DotClientLink) -> void:
		link.envelope.register(&"skew.client_news")
		link.envelope.register(&"skew.server_only_reply", func(_p: int, _d: Dictionary) -> void: heard[0] += 1)
	)

	var joined := await _join(newer)
	if not _check(joined == "", "it joins and plays", joined):
		_server.envelope.register(DotEnvelope.NOTICE)
		_done()
		return

	_check(
		not newer.send_kind(&"skew.client_news", {"hello": true}),
		"the client does not send the server what it does not know"
	)

	var dropped := _server.envelope.dropped_arrivals
	newer._dot_up.rpc_id(1, "skew.client_news", {"hello": true})
	var ignored := await _until(func() -> bool: return _server.envelope.dropped_arrivals > dropped, 5.0)
	_check(ignored, "and one that arrives anyway is dropped by the server")

	var session: DotClientSession = _server.session_of(_peer_of("NewClient"))
	_check(
		session != null and session.is_playing(),
		"which goes on serving it"
	)
	_check(
		not newer.envelope.peer_knows(1, DotEnvelope.NOTICE),
		"and the client knows this server has no notices"
	)

	_drop_link(newer)
	_server.envelope.register(DotEnvelope.NOTICE)
	_done()

## [b]A newer client REQUIRES a kind the server does not have.[/b] Refused by the server in
## words, and quickly -- not left to the auth timeout.
func _test_a_required_kind_the_server_lacks() -> void:
	_section("a client that requires a kind this server lacks is refused in words")

	var strict := _new_link("StrictClient", func(link: DotClientLink) -> void:
		link.envelope.register(&"skew.vital", Callable(), true)
	)

	var started := Time.get_ticks_msec()
	var outcome := await _join(strict)
	var took := (Time.get_ticks_msec() - started) / 1000.0

	_check(outcome != "", "it does not join")
	_check(
		strict.phase == DotClientLink.Phase.FAILED,
		"its phase says it failed (%s)" % DotClientLink.phase_name(strict.phase)
	)
	_check(
		strict.last_error != null and strict.last_error.code == DotError.CODE_VERSION,
		"as a version problem, not a kick",
		str(strict.last_error)
	)
	_check(
		outcome == "This server is older than this game client and cannot host it.",
		"with a sentence a player can act on",
		outcome
	)
	_check(
		strict.last_error != null and strict.last_error.detail.contains("skew.vital"),
		"naming the kind where an operator reads it"
	)
	_check(took < 5.0, "in %.1f s, not an auth timeout" % took)

	_drop_link(strict)
	_done()

## [b]The server REQUIRES a kind an older client does not have.[/b]
func _test_a_required_kind_the_client_lacks() -> void:
	_section("a server that requires a kind this client lacks refuses it in words")

	_server.envelope.register(&"skew.must", Callable(), true)

	var older := _new_link("OlderClient", Callable())

	var started := Time.get_ticks_msec()
	var outcome := await _join(older)
	var took := (Time.get_ticks_msec() - started) / 1000.0

	_check(
		outcome == "This server needs a newer game client.",
		"refused with a sentence a player can act on",
		outcome
	)
	_check(
		older.last_error != null and older.last_error.code == DotError.CODE_VERSION
			and older.last_error.detail.contains("skew.must"),
		"as a version problem naming the kind",
		str(older.last_error)
	)
	_check(took < 5.0, "in %.1f s" % took)
	_check(
		_server.sessions().size() == _playing_before_refusals,
		"and the server holds no slot for it"
	)

	_drop_link(older)
	_server.envelope.unregister(&"skew.must")
	_done()

## An access token is a bearer secret and ENet is cleartext: a server whose sign-in
## wants one gets it over WebSocket, and the UDP connection carries nothing at all.
func _test_a_secret_never_rides_udp() -> void:
	_section("a sign-in that sends a secret never sends it over UDP")

	var seen: Array[Dictionary] = []
	var server_auth := StandIns._AuthStandIn.new()
	server_auth.on_authenticate = func(credential: Dictionary) -> void:
		var counts: Dictionary = _server.multiplayer.multiplayer_peer.call("peer_counts")
		seen.append({"token": credential.get("access_token", ""), "enet": counts["enet"]})
	var client_auth := StandIns._TokenStandIn.new()
	DotRegistry.register(&"dot_auth_server", server_auth)
	DotRegistry.register(&"dot_auth_client", client_auth)

	var link := _new_link("Secretive", Callable())
	await _join(link)
	await _until(func() -> bool: return not seen.is_empty(), 5.0)

	_check(link.transport_used == "websocket", "the client rejoined over WebSocket (%s)" % link.transport_used)
	var over_udp := seen.filter(func(c: Dictionary) -> bool: return c["enet"] > 0)
	var with_join := seen.filter(func(c: Dictionary) -> bool: return c["token"] == StandIns._TokenStandIn.JOIN)
	var with_secret := seen.filter(func(c: Dictionary) -> bool: return c["token"] == StandIns._TokenStandIn.SECRET)
	_check(over_udp.is_empty(), "no credentials at all arrived while it was on ENet (%d)" % over_udp.size())
	_check(with_join.size() == 1, "and a join token arrived once, over WebSocket")
	_check(with_secret.is_empty(), "and the account's access token never arrived at all")
	_check(
		client_auth.minted_for == [StandIns._AuthStandIn.AUDIENCE],
		"minted for the audience the server announced", str(client_auth.minted_for)
	)

	DotRegistry.unregister_instance(&"dot_auth_server", server_auth)
	DotRegistry.unregister_instance(&"dot_auth_client", client_auth)
	_drop_link(link)
	_done()

## [b]An INTROSPECT server the client does not list as first-party gets nothing.[/b]
## No join token is minted for it, no access token is sent, and with no ticket issuer
## the join fails in words rather than leaking the account's credential.
func _test_introspect_refuses_a_server_not_ours() -> void:
	_section("an introspect server not on the first-party list never gets a token")

	var seen: Array[Dictionary] = []
	var server_auth := StandIns._AuthStandIn.new()
	server_auth.audience = "server:999"
	server_auth.on_authenticate = func(credential: Dictionary) -> void:
		seen.append(credential.duplicate())
	var client_auth := StandIns._TokenStandIn.new()
	DotRegistry.register(&"dot_auth_server", server_auth)
	DotRegistry.register(&"dot_auth_client", client_auth)

	var link := _new_link("Stranger", func(l: DotClientLink) -> void:
		l.transport_preference = "ws")
	var outcome := await _join(link)

	_check(
		link.last_error != null and link.last_error.code == DotError.CODE_FORBIDDEN,
		"the join failed as forbidden", str(link.last_error)
	)
	_check(outcome != "", "with a sentence for the player", outcome)
	_check(seen.is_empty(), "and the server received no credentials (%d)" % seen.size())
	_check(client_auth.minted_for.is_empty(), "and no join token was minted")

	DotRegistry.unregister_instance(&"dot_auth_server", server_auth)
	DotRegistry.unregister_instance(&"dot_auth_client", client_auth)
	_drop_link(link)
	_done()

## A ticket server: the client must ask for its ticket by the address it dialled,
## never by an id the server announced (a hostile server would name a victim's).
## Armed by asking by [code]server_id[/code]: the address check fails.
func _test_a_ticket_is_asked_for_by_the_dialled_address() -> void:
	_section("a ticket is asked for by the address the client dialled")

	var seen: Array[Dictionary] = []
	var server_auth := StandIns._AuthStandIn.new()
	server_auth.strategy = "ticket"
	server_auth.on_authenticate = func(credential: Dictionary) -> void:
		seen.append(credential.duplicate())
	var client_auth := StandIns._TicketStandIn.new()
	DotRegistry.register(&"dot_auth_server", server_auth)
	DotRegistry.register(&"dot_auth_client", client_auth)

	var link := _new_link("Ticketed", func(l: DotClientLink) -> void:
		l.transport_preference = "ws")
	await _join(link)

	_check(client_auth.addresses == ["127.0.0.1:%d" % PORT],
		"the ticket was asked for by the dialled address", str(client_auth.addresses))
	_check(client_auth.ids.is_empty(), "never by an id the server announced", str(client_auth.ids))
	_check(seen.size() == 1 and str(seen[0].get("ticket", "")) == StandIns._TicketStandIn.TICKET
			and str(seen[0].get("access_token", "")) == "",
		"and the server got the ticket and no token", str(seen))
	_check(client_auth.nonces.size() == 1 and client_auth.nonces[0].length() >= 16,
		"the ticket was bound to the challenge's nonce", str(client_auth.nonces))
	_check(server_auth.nonces == client_auth.nonces and not seen.is_empty()
			and not seen[0].has("ticket_nonce"),
		"and the server checked it against its own copy, not the client's", str(server_auth.nonces))

	DotRegistry.unregister_instance(&"dot_auth_server", server_auth)
	DotRegistry.unregister_instance(&"dot_auth_client", client_auth)
	_drop_link(link)
	_done()

## [b]One account, one seat:[/b] signing in again replaces the older connection, so a
## player whose old connection is still timing out comes straight back. Armed by
## `sv_single_seat 0`, under which both stay.
func _test_an_account_holds_one_seat() -> void:
	_section("an account signing in again replaces its older connection")

	var auth := StandIns._SameAccountStandIn.new()
	DotRegistry.register(&"dot_auth_server", auth)
	var same := func() -> int:
		return _server.sessions().filter(func(x: DotClientSession) -> bool:
			return x.is_active() and x.uid() == "tmc:the-same-account").size()

	var first := _new_link("TwinA", func(l: DotClientLink) -> void: l.transport_preference = "ws")
	var lost := [""]
	first.disconnected.connect(func(reason: String) -> void: lost[0] = reason)
	_check(await _join(first) == "", "the account joins")
	var second := _new_link("TwinB", func(l: DotClientLink) -> void: l.transport_preference = "ws")
	_check(await _join(second) == "", "and joins again from another connection")
	await _until(func() -> bool: return lost[0] != "", 3.0)
	_check(same.call() == 1, "leaving one seat (%d)" % same.call())
	_check(lost[0] != "", "and the older connection was told why", lost[0])

	_server.console.set_cvar("sv_single_seat", "0")
	var third := _new_link("TwinC", func(l: DotClientLink) -> void: l.transport_preference = "ws")
	_check(await _join(third) == "", "with sv_single_seat 0 a third joins")
	_check(same.call() == 2, "and both seats stay (%d)" % same.call())
	_server.console.set_cvar("sv_single_seat", "1")

	DotRegistry.unregister_instance(&"dot_auth_server", auth)
	_drop_link(first)
	_drop_link(second)
	_drop_link(third)
	await _settle(0.5)
	_done()

## The warm feeds the loading bar, and a cloud freed mid-warm must not leave the join in
## LOADING: the link falls back to a plain load().
func _test_the_warm_feeds_progress_and_survives_the_cloud() -> void:
	_section("The content warm: progress reaches the bar, and a freed cloud does not strand the join")

	var dir := "res://dot_cloud/_warmtest/0.0.0"
	DirAccess.make_dir_recursive_absolute(dir)
	var scene := PackedScene.new()
	var node := Node.new()
	scene.pack(node)
	node.free()
	ResourceSaver.save(scene, dir + "/s.tscn")
	var info := {"scene": "s.tscn", "content_key": "_warmtest@0.0.0"}

	var cloud := FakeCloud.new()
	add_child(cloud)
	DotRegistry.register(&"dot_cloud_client", cloud)

	var link := DotClientLink.new()
	add_child(link)
	var seen: Array = []
	link.download_progress.connect(func(fraction: float, _text: String) -> void: seen.append(fraction))
	link._on_load_game(0, info)
	await _until(func() -> bool: return link.get("_scene_instance") != null, 5.0)
	_check(seen.has(0.5) and seen.has(1.0), "warm progress reaches download_progress", str(seen))
	_check(link.get("_scene_instance") != null, "and the scene loads after the warm")
	link.queue_free()

	cloud.hang = true
	var link2 := DotClientLink.new()
	add_child(link2)
	link2._on_load_game(0, info)
	for i in 8:
		await get_tree().process_frame
	cloud.free()
	var loaded := await _until(func() -> bool: return link2.get("_scene_instance") != null, 3.0)
	_check(loaded, "a cloud freed mid-warm falls back to a plain load() of the scene")
	_check(link2.phase != DotClientLink.Phase.LOADING or loaded, "and the join is not left in LOADING")
	link2.queue_free()

	DotRegistry.unregister(&"dot_cloud_client")
	DirAccess.remove_absolute(dir + "/s.tscn")
	DirAccess.remove_absolute(dir)
	DirAccess.remove_absolute("res://dot_cloud/_warmtest")
	_done()
