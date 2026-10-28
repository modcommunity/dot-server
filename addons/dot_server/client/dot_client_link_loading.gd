@tool
extends "res://addons/dot_server/client/dot_client_link_state.gd"

## Loading the game scene, the early heartbeats and the round-trip estimate of [DotClientLink].


## Runs [code]cloud.warm_content[/code] and returns its loader, or null if the cloud is freed
## or the warm fails. Awaiting a coroutine of a freed object never returns, so it runs in a
## detached call and this polls; the caller then falls back to a plain load().
func _warm(cloud: Object, keys: PackedStringArray, gen: int) -> Variant:
	var state := {"done": false, "loader": null}
	_warm_run(cloud, keys, state)
	while not state["done"]:
		if not is_instance_valid(cloud) or gen != _load_gen or not is_inside_tree():
			return null
		await get_tree().process_frame
	return state["loader"]


func _warm_run(cloud: Object, keys: PackedStringArray, state: Dictionary) -> void:
	var on_progress := func(done: int, total: int) -> void:
		if total > 0:
			download_progress.emit(float(done) / float(total), "Preparing the game…")
	var wants_progress := false
	for m in cloud.get_method_list():
		if m["name"] == "warm_content":
			wants_progress = (m["args"] as Array).size() >= 4
	if wants_progress:
		state["loader"] = await cloud.call("warm_content", get_tree(), keys, false, on_progress)
	else:
		state["loader"] = await cloud.call("warm_content", get_tree(), keys)
	state["done"] = true


## Records the game the server named and tells the host before anything is loaded or freed,
## so a host supplying its own scene for a built-in game knows which one (and to drop the last).
func _begin_game(info: Dictionary) -> void:
	server_game_id = str(info.get("game_id", ""))
	server_content_id = str(info.get("content_id", ""))
	server_game_name = str(info.get("display_name", server_game_id))

	if server_content_id == "":
		server_content_id = server_game_id

	game_changed.emit(server_game_id, server_content_id, server_game_name)

	# The last game's RPC node must not hold the name the next one's needs.
	_free_game_children()


## The scene to load, or "" after failing the link: refused path, or missing from the content.
func _checked_scene(scene_path: String, info: Dictionary) -> String:
	var resolved := _resolve_scene(scene_path, info)

	if resolved == "":
		_fail(DotError.make(
			DotError.CODE_INVALID,
			"The server asked for a scene this client will not load.",
			scene_path
		))
		return ""

	if not ResourceLoader.exists(resolved):
		_fail(DotError.make(
			DotError.CODE_IO,
			"The game scene is missing from the downloaded content.",
			resolved
		))
		return ""
	return resolved


## Instantiates and adds the scene a frame apart so no frame carries both. Returns the
## timings in ms, or null when the load was superseded.
func _attach_scene(packed: PackedScene, gen: int) -> Variant:
	if is_inside_tree():
		await get_tree().process_frame
		if gen != _load_gen:
			return null

	var t1b := Time.get_ticks_usec()
	var instance := packed.instantiate()
	var t2 := Time.get_ticks_usec()

	# Held in a local until it is in the tree: a disconnect during this frame cannot see it.
	if is_inside_tree():
		await get_tree().process_frame
		if gen != _load_gen:
			instance.free()
			return null

	if _game_root == null:
		_game_root = game_root_ref.resolve_or_null(self, CHANNEL)

	_scene_instance = instance
	var t2b := Time.get_ticks_usec()
	_game_root.add_child(_scene_instance)
	var t3 := Time.get_ticks_usec()
	return {"instantiate_ms": (t2 - t1b) / 1000.0, "add_child_ms": (t3 - t2b) / 1000.0}


## The server telling us which scene to load.
##
## [b]This yields.[/b] It used to load, instantiate and add the scene in one call, so a
## browser (where that is many seconds of wasm) never painted the LOADING phase and the page
## went unresponsive. Two frames let a loading screen draw, the load is threaded where threads
## exist, and a frame separates instantiate from add_child. Callers must not assume the scene
## exists when this returns: wait for [signal spawned] or PLAYING.
func _on_load_game(_peer_id: int, info: Dictionary) -> void:
	_load_gen += 1
	var gen := _load_gen
	_set_phase(Phase.LOADING, "Loading…")
	if is_inside_tree():
		await get_tree().process_frame
		await get_tree().process_frame
		if gen != _load_gen:
			return

	var scene_path := str(info.get("scene", ""))
	var content_key := str(info.get("content_key", ""))
	_begin_game(info)

	if scene_path == "":
		# A lobby has no scene but must complete the join like any game, or the client sits in
		# LOADING sending no heartbeats until it is timed out.
		send_kind(DotEnvelope.LOADED)
		_enter_playing()
		return

	var resolved := _checked_scene(scene_path, info)
	if resolved == "":
		return

	_unload_scene()

	# Without threads load() compiles the game's whole script closure in one frame (5 s in a
	# browser); dot-cloud compiles it a slice per frame first. `warmed` holds it until we are done.
	var w0 := Time.get_ticks_usec()
	var warmed: Variant = null
	var cloud := DotRegistry.get_service(cloud_service)
	if content_key != "" and cloud != null and cloud.has_method("warm_content") and is_inside_tree():
		warmed = await _warm(cloud, PackedStringArray([content_key]) + content_extra, gen)
		if gen != _load_gen or not is_inside_tree():
			return

	var t0 := Time.get_ticks_usec()
	var packed: Variant = await _load_scene_resource(resolved, gen)
	if packed is bool:
		return
	var t1 := Time.get_ticks_usec()
	if not (packed is PackedScene):
		_fail(DotError.make(
			DotError.CODE_INVALID, "The game scene is not loadable.", resolved
		))
		return

	var timing: Variant = await _attach_scene(packed as PackedScene, gen)
	if timing == null:
		return

	DotLog.info(
		CHANNEL, "game loaded", {
			"scene": resolved, "content": content_key,
			"warm_ms": (t0 - w0) / 1000.0,
			"warmed": (warmed.get("loaded") as Array).size() if warmed is Object and warmed.get("loaded") is Array else 0,
			"load_ms": (t1 - t0) / 1000.0,
			"instantiate_ms": timing["instantiate_ms"],
			"add_child_ms": timing["add_child_ms"],
		}
	)

	send_kind(DotEnvelope.LOADED)
	_enter_playing()


## Loads the scene at [param resolved], threaded where the platform has threads and
## reporting progress. Returns the resource (null if it failed), or [code]false[/code] when
## the load was superseded or the link left the tree.
func _load_scene_resource(resolved: String, gen: int) -> Variant:
	if not (is_inside_tree() and DotPlatform.has_threads()
			and ResourceLoader.load_threaded_request(resolved) == OK):
		return load(resolved)
	var packed: Resource = null
	while true:
		var progress: Array = []
		var status := ResourceLoader.load_threaded_get_status(resolved, progress)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			if progress.size() > 0:
				download_progress.emit(float(progress[0]), "Loading…")
			await get_tree().process_frame
			if gen != _load_gen or not is_inside_tree():
				return false
			continue
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			packed = ResourceLoader.load_threaded_get(resolved)
		break
	return false if gen != _load_gen else packed


## Everything that has to happen once the join is complete.
##
## Factored out because there are two ways to finish loading — with a scene and
## without one — and they have to agree. They did not: the no-scene path skipped all
## three steps, which is a bug that only exists on a server with no game configured.
func _enter_playing() -> void:
	_set_phase(Phase.PLAYING, "")
	# A heartbeat now and three more a quarter of a second apart, then the usual interval.
	# Every game's clock takes its input lead from the round trip, and until the first
	# heartbeat came back -- two seconds after joining, at the earliest -- `ping_ms` was -1,
	# so the clock left the flight time out and every command of the first seconds arrived
	# after its tick: the player moved on their own screen and the server ran them on the
	# command before. Measured in game-arena over a real link: 46% of the first three
	# seconds' commands in time. A few early samples give the clock a round trip within one
	# round trip of joining, on WebSocket as well as ENet.
	_early_heartbeats = EARLY_HEARTBEATS
	_heartbeat.wait_time = EARLY_HEARTBEAT_SEC
	_heartbeat.start()
	_send_heartbeat()
	spawned.emit()


## Turns the server's scene path into one this client will load.
##
## [b]The server does not get to name an absolute path.[/b] A relative path resolves
## under dot-cloud's mount prefix for the content the server named; an absolute
## [code]res://[/code] path is accepted only when it is already inside a mount
## prefix. Otherwise a malicious server could ask a client to load
## [code]res://addons/…[/code] or any scene shipped in the build.
func _resolve_scene(scene_path: String, info: Dictionary) -> String:
	if not scene_path.contains("://"):
		var safe := DotPaths.safe_relative(scene_path)
		if not safe.ok:
			DotLog.warn(
				CHANNEL,
				"refusing an unsafe scene path from the server",
				{"path": scene_path}
			)
			return ""

		var content_key := str(info.get("content_key", ""))
		if content_key == "":
			# No content, so a relative path has nothing to resolve against.
			return ""

		var parts := content_key.split("@", true, 1)
		var content_id := parts[0]
		var version := parts[1] if parts.size() > 1 else "0.0.0"

		return "res://dot_cloud/%s/%s/%s" % [content_id, version, safe.value]

	if scene_path.begins_with("res://dot_cloud/"):
		return scene_path

	DotLog.warn(
		CHANNEL,
		"refusing an absolute scene path outside the content mount",
		{"path": scene_path}
	)
	return ""


func _unload_scene() -> void:
	# First, and whether or not this node built the scene: a shell that takes its game down
	# itself (on [signal game_changed]) leaves `_scene_instance` freed, which reads as null
	# here, and the game's RPC node under this link still has to go.
	_free_game_children()
	if _scene_instance == null:
		return
	if is_instance_valid(_scene_instance):
		_game_root.remove_child(_scene_instance)
		_scene_instance.free()
	_scene_instance = null


## Retires what the game that just went parented under this link: its RPC node, above all.
##
## [b]A delivered game parents its own RPC node under this link[/b], named the same as the
## server's copy, because Godot routes an RPC by node path and this node is `Server` on
## both ends. No game freed it, so every game change left the old one here, and when the
## same game loaded again its node collided with the leftover's name and was renamed
## `@Node@<n>`: from then on the server could not find what this client sent ("Failed to
## get path from RPC: Server/@Node@2370"), in every game a rotation came back to.
## [DotGameManager] retires the server's copy the same way.
##
## [b]Renamed now and freed [constant RETIRED_SECONDS] later[/b], because a snapshot the
## server sent before the swap can still be in flight: Godot resolves a cached RPC path by the
## node's object and forgets it when the node leaves the tree, so a node freed at once turns
## each straggler into an engine error, while a renamed one drops it quietly and frees the
## name for the next game's node, which is added in this same call.
##
## Everything under this link that is not the link's own belongs to the game: the chat
## node, the two timers, and the game root when it is the default one under this node.
func _free_game_children() -> void:
	var retired: Array[Node] = []

	for child in get_children():
		if child == _chat or child == _heartbeat or child == _signon_watchdog:
			continue
		if _game_root != null and is_instance_valid(_game_root) \
				and (child == _game_root or child.is_ancestor_of(_game_root)):
			continue
		if String(child.name).contains("_retired_"):
			continue
		retired.append(child)
		child.name = "%s_retired_%d" % [child.name, child.get_instance_id()]

	if retired.is_empty() or not is_inside_tree():
		return

	DotLog.debug(CHANNEL, "retired what the game left under the link", {
		"nodes": retired.size(),
	})

	get_tree().create_timer(RETIRED_SECONDS, true, false, true).timeout.connect(
		_free_ids.bind(retired.map(func(n: Node) -> int: return n.get_instance_id())))


## Frees the nodes still alive by instance id; a lambda capturing them errors once one is freed early.
static func _free_ids(ids: Array) -> void:
	for id in ids:
		var node := instance_from_id(id) as Node
		if node != null and not node.is_queued_for_deletion():
			node.queue_free()


func _send_heartbeat() -> void:
	if not _connected:
		return
	_ping_sent_ms = Time.get_ticks_msec()
	send_kind(DotEnvelope.HEARTBEAT, {"t": _ping_sent_ms}, DotEnvelope.Lane.UNRELIABLE)

	if _early_heartbeats > 0:
		_early_heartbeats -= 1
		if _early_heartbeats == 0:
			_heartbeat.wait_time = heartbeat_interval_sec


## The server's reply, which is how ping is measured.
func _on_heartbeat_ack(_peer_id: int, payload: Dictionary) -> void:
	# Round trip measured from our own timestamp echoed back, so no clock
	# synchronisation is needed.
	var sent_ms := int(DotEnvelope.number(payload, "t", -1))
	if sent_ms < 0:
		return
	_ping_ms = Time.get_ticks_msec() - sent_ms
	send_kind(DotEnvelope.PING, {"ms": _ping_ms}, DotEnvelope.Lane.UNRELIABLE)

	var meter := net_meter()
	if meter != null:
		meter.note_rtt(float(_ping_ms))
		var sv: Variant = payload.get("sv")
		if sv is Dictionary:
			meter.note_remote(sv)


func ping_ms() -> int:
	return _ping_ms


## The round trip to the server in milliseconds, the best this link can say: ENet's own
## measure on UDP (it times every acknowledged packet from the connect on, so it is right
## before the first snapshot), and the heartbeat's otherwise. 0 when nothing is known yet.
## What a game's netcode clock should be fed rather than [method ping_ms].
func rtt_ms() -> float:
	var api := multiplayer
	var peer: Object = api.multiplayer_peer if api != null else null

	# Through the dual peer when there is one: it answers for whichever transport this
	# connection used. Duck-typed, because a web build has no ENet class to name.
	if peer != null and peer.has_method("get_peer") and ClassDB.class_exists(&"ENetPacketPeer"):
		var server: Variant = peer.call("get_peer", 1)
		if server is Object and (server as Object).has_method("get_statistic"):
			var stat := ClassDB.class_get_integer_constant(&"ENetPacketPeer", &"PEER_ROUND_TRIP_TIME")
			var rtt := float((server as Object).call("get_statistic", stat))
			if rtt > 0.0:
				return rtt

	return float(maxi(_ping_ms, 0))


## The meter the connection runs through, or null when there is no connection. What
## net_stat reads; see [DotMeteredPeer].
func net_meter() -> DotMeteredPeer:
	if multiplayer == null:
		return null
	return DotMeteredPeer.of(multiplayer.multiplayer_peer)
