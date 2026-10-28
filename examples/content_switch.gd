extends "res://examples/selftest/content_switch_base.gd"

## Changing to a game whose content is DELIVERED, with a real client attached. Exits non-zero
## on any failure: [code]godot --headless --path . res://examples/content_switch.tscn[/code]
##
## Every other suite switches between games shipped in the build, where `manifest_url` is empty
## and [method DotGameManager.change_game] skips the whole content sync: announce, download,
## per-client readiness wait, timeout and re-load. This file is the first thing to run them.
## It guards: the server fetching its own content, a client reporting the right key during a
## sync (deliberately the OLD game's) not being kicked, a stale content key not passing for
## ready on the second change to a game, and the progress subscription being made only once.
##
## Two [MultiplayerAPI] instances in one process (one [member SceneTree.multiplayer] is not
## enough), with both link nodes named [code]Server[/code]: RPCs route by node path.

func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server: changing to DELIVERED content under a live client")

	DotPaths.remove_tree(DATA)

	if await _publish_content():
		if await _boot():
			if await _test_connect():
				await _test_switch_to_delivered()
				await _test_switch_back()
				await _test_switch_to_delivered_again()
				_check_bases_are_not_duplicated()
				await _test_disconnect_mid_load()
	_test_retire_timer_ids()

	_teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	_check(
		_passed + _failed + 1 == CHECKS,
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		"a section that aborted part-way stops adding checks, and only a total can show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


func _test_retire_timer_ids() -> void:
	_section("retire timers free by instance id, so a node freed early is not an error")
	for helper in [DotGameManager._free_ids, DotClientLink._free_ids]:
		var gone := Node.new()
		var live := Node.new()
		add_child(live)
		var ids := [gone.get_instance_id(), live.get_instance_id()]
		gone.free()
		helper.call(ids)
		_check(live.is_queued_for_deletion(), "the live retired node is freed")
		_check(true, "and an id already freed is skipped without an error")
		live.free()
	_completed += 1


func _test_connect() -> bool:
	_section("a client connects to the builtin game")

	_link = DotClientLink.new()
	# "Server", the same as DotServer. The name is the routing.
	_link.name = "Server"
	_link.player_name = "Downloader"
	_client_side.add_child(_link)

	_link.spawned.connect(func() -> void: _spawned[0] = true)
	_link.disconnected.connect(func(reason: String) -> void: _refused[0] = reason)
	_link.game_changed.connect(
		func(game_id: String, _content_id: String, _name: String) -> void:
			_games_seen.append(game_id)
	)
	# Kept even though the count is not asserted on: a sync of one small file off the
	# disk can finish inside `progress_interval_sec` and legitimately report nothing,
	# so the number is evidence and not a check. What IS checked is that the client
	# subscribes exactly once — see the end of the next section.
	_link.download_progress.connect(
		func(_fraction: float, _text: String) -> void:
			_progress_calls[0] += 1
	)

	var address := "127.0.0.1:%d" % PORT
	var connecting: DotResult = await _link.connect_to_server(address)

	if not _check(connecting.ok, "it starts connecting", str(connecting.error)):
		_done()
		return false

	var admitted := await _until(
		func() -> bool: return _spawned[0] or _refused[0] != ""
	)

	if not _check(admitted, "and finishes signon", "refused: %s" % _refused[0]):
		_done()
		return false

	# [b]The server's view, not only the client's.[/b] `spawned` fires when the client
	# has loaded and reported; the session reaches SPAWNED when that report arrives, a
	# round trip later. Changing the game in between is what caught the transition bug
	# above — legitimate, and worth keeping deterministic here so the sections after
	# it assert on one thing at a time.
	var seated := await _until(_client_playing)
	_check(seated, "and the server agrees it is playing")
	_check(_server.sessions().size() == 1, "the server has one session")
	_check(
		_games_seen.size() == 1 and _games_seen[0] == "lobby",
		"and it was told which game it is in (%s)" % [_games_seen]
	)
	_done()
	return true


## The switch nothing in this family had ever performed.
func _test_switch_to_delivered() -> void:
	_section("changelevel to a game the client has to download")

	var result := _server.console.execute("changelevel arena")
	_check(result.ok, "the command is accepted", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("arena"), 30.0)

	if not _check(
		arrived,
		"the server reaches the delivered game",
		"it fetched no content of its own, so the scene it loads does not exist"
	):
		_done()
		return

	# The server's own half of the download. Everything below is about the client's,
	# and for a long time this one did not happen at all.
	_check(
		ResourceLoader.exists(
			"res://dot_cloud/%s/%s/%s" % [PACK_ID, PACK_VERSION, PACK_SCENE]
		),
		"the pack is mounted on the server",
		"nothing here ever acquired it; the mount prefix was a path nobody wrote"
	)

	_check(
		_refused[0] == "",
		"the client was not disconnected",
		"reporting the NEW content while the server still runs the OLD one is "
		+ "correct, and used to be rejected: got '%s'" % _refused[0]
	)

	# [b]The client is told where the content is, because it cannot know.[/b] The
	# server is configured with the address and fetches from it; a shipped client
	# build can only guess, and the one guess a browser build makes is the origin its
	# page came from -- correct for a self-hosted deployment and wrong for every CDN.
	# The map the server had just mounted then 404'd on every client.
	var client_cloud := DotRegistry.get_service(&"dot_cloud_client")
	if _check(client_cloud != null, "the client's content service is resolvable"):
		var bases: PackedStringArray = client_cloud.get("http_base_urls")
		_check(
			bases.has(CONTENT_BASE),
			"the client adopted the server's content address",
			"it had %s" % str(Array(bases))
		)
		# Guarded: indexing an empty PackedStringArray is a runtime error, which
		# ABORTS THE SECTION rather than failing a check -- so the first version of
		# this took the remaining checks down with it and the section counter was the
		# only thing that said so.
		_check(
			not bases.is_empty() and bases[bases.size() - 1] == CONTENT_BASE,
			"and put it LAST, behind anything the client was already given",
			"a client with a mirror of its own meant it; this is a fallback"
		)

	await _test_delivered_client_told()

func _test_delivered_client_told() -> void:
	var told := await _until(func() -> bool: return _games_seen.has("arena"))
	_check(told, "the client was told about the change")
	_check(
		told and _games_seen[_games_seen.size() - 1] == "arena",
		"and told it last, not before the swap (%s)" % [_games_seen]
	)
	# One `_load_game` for the join and one for the change. A third means the client
	# was told to load the OLD game the moment it finished downloading the new one,
	# which is what `report_content_ready` used to do mid-sync.
	_check(
		_games_seen.size() == 2,
		"and told exactly once per change (%s)" % [_games_seen]
	)

	var back := await _until(_client_playing)

	var session: DotClientSession = (
		_server.sessions()[0] if _server.sessions().size() > 0 else null
	)
	_check(session != null, "the session survives the change")
	_check(
		back,
		"and is playing again (%s)"
			% [session.state_name() if session != null else "gone"]
	)
	_check(
		session != null
			and session.content_key == "%s@%s" % [PACK_ID, PACK_VERSION],
		"with the delivered content recorded against it (%s)"
			% [session.content_key if session != null else "-"]
	)

	await _test_delivered_client_mounted()

func _test_delivered_client_mounted() -> void:
	# The client half: it really downloaded, verified and mounted the pack, and the
	# scene it is showing came out of it rather than out of its own build.
	_check(
		bool(_client_cloud.call("is_mounted", PACK_ID, PACK_VERSION)),
		"the client mounted the pack it was sent to fetch"
	)
	# One process holds both ends here and the game manager fetches through the
	# registry's `dot_cloud_client`, so which CLIENT object mounted it cannot tell the
	# server from the client. A mount is process-wide, though, and the file being
	# readable at the dependency's own prefix is what the game will actually rely on.
	_check(
		FileAccess.file_exists("res://dot_cloud/%s/%s/shared.txt" % [DEP_ID, DEP_VERSION]),
		"the game's dependency is readable at its own mount prefix"
	)
	_check(
		bool(_client_cloud.call("is_mounted", DEP_ID, DEP_VERSION)),
		"and the client mounted it too, from the same content.sync"
	)
	_check(
		FileAccess.file_exists("res://dot_cloud/%s/%s/server.txt" % [SRV_ID, SRV_VERSION]),
		"the server-only pack is mounted for the game"
	)
	_check(
		Array(_link.content_extra) == ["%s@%s" % [DEP_ID, DEP_VERSION]],
		"and the client was told to fetch the shared one only (%s)" % [_link.content_extra]
	)
	_check(
		Array(_server.games.current_server_dependencies()) == ["%s@%s" % [SRV_ID, SRV_VERSION]],
		"the manager names the server-only pack (%s)" % [_server.games.current_server_dependencies()]
	)
	_check(
		Array(_server.games.current_maps()) == [MAP_KEY]
			and not DirAccess.dir_exists_absolute("res://dot_cloud/test/map_a/1.0.0"),
		"and offers the map without mounting it (%s)" % [_server.games.current_maps()]
	)
	# [b]One subscription, not one per change.[/b] The link connects a handler to the
	# cloud client's `progress_changed` every time a sync begins, guarded by
	# `is_connected` — and a fresh lambda is a fresh [Callable], so the guard never
	# matched its own handler and every game change added another subscriber. After
	# ten changes a client sent the server ten identical progress RPCs per tick, with
	# nothing anywhere reporting an error. Counted rather than inferred, because the
	# symptom is invisible until it is measured.
	_check(
		_client_cloud.get_signal_connection_list("progress_changed").size() == 1,
		"the client subscribed to download progress exactly once (%d)"
			% _client_cloud.get_signal_connection_list("progress_changed").size()
	)

	# What a game does once it is running: parent its RPC node under `Server` on both ends.
	_game_nodes = [_add_game_node(_server), _add_game_node(_link)]
	_done()


## Stands in for a game's RPC link: named, under `Server`, on one end.
func _add_game_node(parent: Node) -> Node:
	var node := Node.new()
	node.name = GAME_NODE
	parent.add_child(node)
	return node


func _test_switch_back() -> void:
	_section("and back to the builtin game")

	var result := _server.console.execute("changelevel lobby")
	_check(result.ok, "the command is accepted", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("lobby"), 30.0)
	_check(arrived, "the lobby comes back")
	_check(_refused[0] == "", "the client is still connected")

	var told := await _until(_told_lobby_again)
	_check(told, "and was told (%s)" % [_games_seen])

	# [b]The last game's RPC node must not keep the name the next game's needs.[/b] Nothing
	# freed it, on either end, so the same game loaded a second time got a link Godot had
	# renamed `@Node@<n>` beside the leftover, and every RPC between the two ends named a
	# path the other did not have. Retired, it is renamed out of the way at the change (and
	# freed a few seconds later, so packets already in flight still land on it).
	var server_node: Node = _game_nodes[0] if _game_nodes.size() > 0 else null
	var client_node: Node = _game_nodes[1] if _game_nodes.size() > 1 else null
	_check(
		server_node != null and is_instance_valid(server_node)
			and String(server_node.name) != GAME_NODE,
		"the server retired the last game's node (%s)"
			% (server_node.name if is_instance_valid(server_node) else &"freed")
	)
	_check(
		client_node != null and is_instance_valid(client_node)
			and String(client_node.name) != GAME_NODE,
		"the client retired the last game's node (%s)"
			% (client_node.name if is_instance_valid(client_node) else &"freed")
	)
	var again_server := _add_game_node(_server)
	var again_client := _add_game_node(_link)
	_check(
		String(again_server.name) == GAME_NODE and String(again_client.name) == GAME_NODE,
		"the next game's node gets the same name on both ends (%s, %s)"
			% [again_server.name, again_client.name],
		"a name collision renames it @Node@<n> and the two ends' RPC paths disagree"
	)
	again_server.queue_free()
	again_client.queue_free()
	_done()


## The change that a stale content key made look instant.
##
## Going back to a game the client has already played is the case where
## `session.content_key` still holds exactly the string the wait loop compares
## against. Without clearing it the client counted as ready on the first pass — before
## the RPC telling it to download had been processed at all — and the swap went out to
## a client that had not been asked for anything.
## The same address arrives on every game change, and a list that grows costs a
## request per entry on every miss.
func _check_bases_are_not_duplicated() -> void:
	var client_cloud := DotRegistry.get_service(&"dot_cloud_client")
	if client_cloud == null:
		return

	var bases: PackedStringArray = client_cloud.get("http_base_urls")
	var seen := 0
	for b in bases:
		if b == CONTENT_BASE:
			seen += 1

	_check(
		seen == 1,
		"the address is still there exactly once after three game changes",
		"it appears %d times" % seen
	)


func _test_switch_to_delivered_again() -> void:
	_section("changelevel back to the delivered game")

	var session: DotClientSession = (
		_server.sessions()[0] if _server.sessions().size() > 0 else null
	)

	if not _check(session != null, "there is still a session to change under"):
		_done()
		return

	# The stale value the wait loop used to match on, still in place from the first
	# change. This is the precondition, asserted rather than assumed.
	_check(
		session.content_key == "%s@%s" % [PACK_ID, PACK_VERSION],
		"the session still holds the delivered key from last time (%s)"
			% session.content_key
	)

	var seen_downloading := [false]
	var watcher := func(s: DotClientSession) -> void:
		if s.state == DotClientSession.State.DOWNLOADING:
			seen_downloading[0] = true
	_server.client_state_changed.connect(watcher)

	# Loading yields: LOADING is on screen for a frame before the scene exists. It used to
	# load, instantiate and add in the call that set the phase, so a browser never painted it.
	var load_seen := {"frame": -1, "old": null, "playing": -1}
	var on_phase := func(ph: DotClientLink.Phase, _t: String) -> void:
		if ph == DotClientLink.Phase.LOADING:
			load_seen["frame"] = Engine.get_process_frames()
			load_seen["old"] = _link._scene_instance
		elif ph == DotClientLink.Phase.PLAYING:
			load_seen["playing"] = Engine.get_process_frames()
	_link.phase_changed.connect(on_phase)

	var result := _server.console.execute("changelevel arena")
	_check(result.ok, "the command is accepted", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("arena"), 30.0)
	_check(arrived, "the server reaches it again")

	await _until(_client_playing)

	_link.phase_changed.disconnect(on_phase)
	_check(load_seen["frame"] >= 0, "the client entered LOADING")
	_check(
		load_seen["playing"] - load_seen["frame"] >= 1,
		"and LOADING lasts at least a frame before PLAYING (%d)" % (load_seen["playing"] - load_seen["frame"])
	)
	_check(
		_link._scene_instance != null and is_instance_valid(_link._scene_instance)
			and _link._scene_instance != load_seen["old"],
		"and a new scene replaced the old one by PLAYING"
	)

	_server.client_state_changed.disconnect(watcher)

	_check(
		seen_downloading[0],
		"the client was actually sent to download",
		"a stale content_key made it look ready before it had been told anything"
	)
	_check(_refused[0] == "", "and is still connected")
	_check(
		_server.sessions().size() == 1
			and _server.sessions()[0].state == DotClientSession.State.SPAWNED,
		"and playing"
	)
	_done()


## [b]A disconnect while the scene loads leaves no scene.[/b] The load awaits frames now, so
## it can be overtaken. Driven by calling the handler with what the server sent, then
## disconnecting a frame later (the load is by then in its wait); nothing may be added after.
func _test_disconnect_mid_load() -> void:
	_section("a disconnect during the load leaves no scene")

	var info: Dictionary = _server.games.load_info()
	_link.disconnect_from_server()
	_check(_link._scene_instance == null, "the link starts with no scene")
	_link._on_load_game(1, info)
	_check(_link.phase == DotClientLink.Phase.LOADING, "the load begins")
	await get_tree().process_frame
	_link.disconnect_from_server()
	await _until(func() -> bool: return false, 1.0)
	_check(_link._scene_instance == null, "a disconnect mid-load leaves no scene")
	_check(_link.phase == DotClientLink.Phase.IDLE, "and the phase stays IDLE")
	_done()
