extends RefCounted
## The PROFILE stage over a real socket, for signon_revision; [param h] is the suite.

var h: Node
var trails: Dictionary = {}
var spawned_names: Array[String] = []
var passer: DotClientLink
var passer_session: DotClientSession


func _init(host: Node) -> void:
	h = host


## Over a real socket, because the claim is about what a CLIENT sees: a held client waits in its
## refused one reads the module's sentence and never spawned.
func run() -> void:
	h._section("a module holds a joining player in PROFILE, and may refuse them unseen")

	# A replay keeps `int(session.state)`, so the stage went on the end of the enum. The
	# numbers already in records must not have moved.
	h._check(
		DotClientSession.State.CONNECTING == 0 and DotClientSession.State.AUTHENTICATING == 1
			and DotClientSession.State.DOWNLOADING == 2 and DotClientSession.State.LOADING == 3
			and DotClientSession.State.SPAWNED == 4 and DotClientSession.State.REJECTED == 5
			and DotClientSession.State.DISCONNECTED == 6 and DotClientSession.State.PROFILE == 7,
		"no stage a record already holds was renumbered"
	)

	# Each joiner's states as the server announced them, and who the server spawned.
	var holder := func(session: DotClientSession) -> void:
		if not trails.has(session.display_name):
			trails[session.display_name] = []
		(trails[session.display_name] as Array).append(session.state_name())
		if session.state == DotClientSession.State.PROFILE and session.display_name.begins_with("Held"):
			h._server.hold_profile(session, "test")
	var on_spawn := func(session: DotClientSession) -> void:
		spawned_names.append(session.display_name)
	h._server.client_state_changed.connect(holder)
	h._server.client_spawned.connect(on_spawn)

	await _passes()
	var held := await _held()
	var refused := await _refused()
	var stuck := await _stuck()

	h._server.client_state_changed.disconnect(holder)
	h._server.client_spawned.disconnect(on_spawn)
	for link in [passer, held, refused, stuck]:
		await h._drop_link(link)
	h._done()


## Nobody holds an ordinary player: the stage costs them nothing.
func _passes() -> void:
	passer = h._new_link("Passer", Callable())
	var passed: String = await h._join(passer)
	h._check(passed == "", "with nobody holding, a player passes straight through", passed)
	var trail: Array = trails.get("Passer", [])
	h._check(
		trail.find("PROFILE") >= 0 and trail.find("PROFILE") < trail.find("LOADING"),
		"and did pass through it, before content (%s)" % ", ".join(trail)
	)
	passer_session = h._server.session_of(h._peer_of("Passer"))
	h._check(
		passer_session != null and not h._server.hold_profile(passer_session, "test")
			and passer_session.profile_holds.is_empty(),
		"a player already past the stage cannot be held"
	)

	return


## Held: in the stage, and nothing moves it on; released, they spawn.
func _held() -> DotClientLink:
	var held: DotClientLink = h._new_link("HeldA", Callable())
	await held.connect_to_server("127.0.0.1:%d" % h.PORT)
	var reached: bool = await h._until(func() -> bool:
		var s: DotClientSession = h._server.session_of(h._peer_of("HeldA"))
		return s != null and s.state == DotClientSession.State.PROFILE, 5.0)
	var held_session: DotClientSession = h._server.session_of(h._peer_of("HeldA"))
	h._check(
		reached and held_session != null and held_session.profile_holds == PackedStringArray(["test"]),
		"a module's hold keeps the player in PROFILE, naming who holds it",
		held_session.state_name() if held_session != null else "no session"
	)
	await h._settle(0.75)
	var held_outcome: Array = h._outcomes["HeldA"]
	h._check(
		held_session.state == DotClientSession.State.PROFILE and not held_outcome[0]
			and not spawned_names.has("HeldA"),
		"and it stays there: no content, no load, no spawn on either end"
	)
	h._check(
		held.phase == DotClientLink.Phase.AUTHENTICATING,
		"the client waits in its own signing-in phase, as a client older than the stage would (%s)" % DotClientLink.phase_name(held.phase)
	)

	# A client that claims to have loaded without being sent a game must not appear.
	held.send_kind(DotEnvelope.LOADED, {})
	await h._settle(0.3)
	h._check(
		held_session.state == DotClientSession.State.PROFILE and not spawned_names.has("HeldA"),
		"a held client that says it has loaded is not spawned"
	)

	h._server.release_profile(held_session, "test")
	var released: bool = await h._until(func() -> bool: return held_outcome[0] and spawned_names.has("HeldA"), 5.0)
	h._check(released and held_session.state == DotClientSession.State.SPAWNED,
		"the last release sends the player on, and they spawn")
	h._check(held_session.profile_holds.is_empty(), "with no hold left on the session")
	var trail: Array = trails.get("HeldA", [])
	h._check(
		trail.find("PROFILE") >= 0 and trail.find("PROFILE") < trail.find("SPAWNED"),
		"through PROFILE, then content (%s)" % ", ".join(trail)
	)
	return held


## Refused while held: told why, and never in the game.
func _refused() -> DotClientLink:
	var refused: DotClientLink = h._new_link("HeldB", Callable())
	await refused.connect_to_server("127.0.0.1:%d" % h.PORT)
	await h._until(func() -> bool:
		var s: DotClientSession = h._server.session_of(h._peer_of("HeldB"))
		return s != null and s.state == DotClientSession.State.PROFILE, 5.0)
	var refused_session: DotClientSession = h._server.session_of(h._peer_of("HeldB"))
	h._check(
		refused_session != null and h._server.refuse_profile(refused_session, "Make an avatar first."),
		"a module can refuse a player it holds"
	)
	var refused_outcome: Array = h._outcomes["HeldB"]
	var heard: bool = await h._until(func() -> bool: return refused_outcome[1] != "", 5.0)
	h._check(heard and refused_outcome[1] == "Make an avatar first.",
		"and the client reads the module's own sentence", str(refused_outcome[1]))
	h._check(
		not refused_outcome[0] and not spawned_names.has("HeldB") and h._peer_of("HeldB") == 0
			and refused_session.state == DotClientSession.State.REJECTED,
		"and was never spawned, and the server has no session for them"
	)
	h._check(
		passer_session != null and not h._server.refuse_profile(passer_session, "too late"),
		"a player past the stage cannot be refused in it; that would be a kick"
	)
	return refused


## A hold nobody releases costs the player their join, never the server a slot.
func _stuck() -> DotClientLink:
	var budget: float = h._server.config.profile_timeout_sec
	h._server.config.profile_timeout_sec = 0.5
	var stuck: DotClientLink = h._new_link("HeldC", Callable())
	await stuck.connect_to_server("127.0.0.1:%d" % h.PORT)
	var stuck_outcome: Array = h._outcomes["HeldC"]
	var dropped: bool = await h._until(func() -> bool: return stuck_outcome[1] != "", 5.0)
	h._server.config.profile_timeout_sec = budget
	h._check(
		dropped and str(stuck_outcome[1]).contains("setting up a profile"),
		"a hold never released times out on the stage's own budget, in words",
		str(stuck_outcome[1])
	)
	h._check(not spawned_names.has("HeldC") and h._peer_of("HeldC") == 0, "and that player never appeared either")
	return stuck
