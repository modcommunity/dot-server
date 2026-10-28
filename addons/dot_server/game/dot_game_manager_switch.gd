@tool
extends "res://addons/dot_server/game/dot_game_manager_state.gd"

## Content fetch, client sync and scene swap of [DotGameManager].

## Fetches the content here first, then has every client fetch it.
##
## Server first, so a server that cannot get it abandons the change while nobody has been disturbed.
func _deliver_content(descriptor: DotGameDescriptor) -> DotResult:
	var have := await _acquire_content(descriptor)
	if not have.ok:
		return have

	return await _sync_clients(descriptor)


## Downloads and mounts the new game's content on this server, through dot-cloud from [DotRegistry].
## An absent cloud client is a refusal: a manifest_url says the content is delivered, and clients
## must not be asked for what the server cannot load.
func _acquire_content(descriptor: DotGameDescriptor) -> DotResult:
	var cloud := DotRegistry.get_service(&"dot_cloud_client")

	if cloud == null or not cloud.has_method("ensure"):
		return DotResult.fail(
			DotError.CODE_STATE,
			"'%s' is delivered content and dot-cloud is not installed."
				% descriptor.game_id,
			"add a DotCloudClient to this server, or ship the game inside the build "
			+ "by clearing its manifest_url"
		)

	DotLog.info(
		CHANNEL,
		"fetching the new game's content",
		{
			"game": descriptor.game_id,
			"content": descriptor.content_key(),
			"url": descriptor.manifest_url if descriptor.manifest_url != ""
				else "(by id)",
		}
	)

	var groups := PackedStringArray()
	for group in descriptor.content_groups:
		groups.append(String(group))

	# `ensure` is told the id and version too, so it refuses a manifest that does not answer to
	# them (a mirror serving one game's pack under another's name); `acquire` mounts anything.
	var acquired: Variant = await cloud.call(
		"ensure",
		descriptor.effective_content_id(),
		descriptor.version,
		groups,
		descriptor.manifest_url
	)

	if acquired is DotResult:
		var typed: DotResult = acquired
		if not typed.ok:
			return typed.wrap(
				"Could not get %s's content." % descriptor.game_id
			)

		# Dependencies and server-only packs are fetched here too, so an unobtainable one abandons
		# the change before any client downloads. Server-only ones never reach content.sync.
		for key in descriptor.dependencies + descriptor.server_dependencies:
			var parts := DotGameDescriptor.split_key(key)
			var dep: Variant = await cloud.call("ensure", parts[0], parts[1])
			if not (dep is DotResult) or not (dep as DotResult).ok:
				var why := (dep as DotResult) if dep is DotResult else DotResult.fail(
					DotError.CODE_INTERNAL, "The cloud client returned no result."
				)
				return why.wrap(
					"Could not get %s, which %s needs." % [key, descriptor.game_id]
				)

		return typed

	return DotResult.fail(
		DotError.CODE_INTERNAL,
		"The cloud client returned something that is not a DotResult.",
		str(acquired)
	)


## Tells every client to fetch the new content and waits for them.
func _sync_clients(descriptor: DotGameDescriptor) -> DotResult:
	phase = Phase.SYNCING
	_sync_deadline = int(Time.get_unix_time_from_system()) + int(sync_timeout_sec)

	# Built by the server: it is the same payload the join path sends, and a copy here drifted.
	var info := server.content_sync_info(
		descriptor.manifest_url,
		Array(descriptor.content_groups),
		descriptor.content_key(),
		descriptor.dependencies
	)

	var expected := 0

	for session in server.sessions():
		if _send_content_sync(session, info):
			expected += 1

	if expected == 0:
		return DotResult.success(0)

	DotLog.info(
		CHANNEL, "waiting for clients to sync", {"clients": expected}
	)

	while true:
		await get_tree().create_timer(0.5).timeout

		if not is_inside_tree():
			return DotResult.fail(
				DotError.CODE_CANCELLED, "The server is shutting down."
			)

		var ready_count := 0
		var waiting := 0

		for session in server.sessions():
			if not session.is_active():
				continue
			if session.content_key == descriptor.content_key():
				ready_count += 1
			elif session.state == DotClientSession.State.DOWNLOADING:
				waiting += 1

		change_progress.emit(ready_count, ready_count + waiting)

		# Off, the change waits out the whole timeout even when everybody is ready.
		if waiting == 0 and swap_when_all_ready:
			DotLog.info(CHANNEL, "all clients synced", {"clients": ready_count})
			return DotResult.success(ready_count)

		if int(Time.get_unix_time_from_system()) >= _sync_deadline:
			_on_sync_timeout(ready_count, waiting)
			# Proceeding, not failing: the ones who got the content keep their change.
			return DotResult.success(ready_count)

	return DotResult.success(0)


## Moves one session to DOWNLOADING and sends it the sync. False when it is not waited for.
func _send_content_sync(session: DotClientSession, info: Dictionary) -> bool:
	if not session.is_active():
		return false
	# A client still authenticating, or held in PROFILE, reaches the new content through the
	# normal join flow; moving a held one to DOWNLOADING would let it past its holder.
	if session.state == DotClientSession.State.CONNECTING \
		or session.state == DotClientSession.State.AUTHENTICATING \
		or session.state == DotClientSession.State.PROFILE:
		return false

	session.content_progress = 0.0
	# Cleared, not left: the wait loop compares content_key, and a client that played this game
	# earlier still holds the new key, so it would be counted ready before the RPC even arrived.
	session.content_key = ""

	if not session.transition_to(DotClientSession.State.DOWNLOADING):
		DotLog.warn(
			CHANNEL,
			"a client could not be sent to download",
			{"user": session.label(), "state": session.state_name()}
		)
		return false

	# Announced like every other state change; modules and admin panels hear it from the signal.
	server.client_state_changed.emit(session)
	server.send_kind(session.peer_id, DotEnvelope.CONTENT_SYNC, info)
	return true


func _on_sync_timeout(ready_count: int, waiting: int) -> void:
	DotLog.warn(
		CHANNEL,
		"content sync timed out",
		{"ready": ready_count, "waiting": waiting}
	)

	if not kick_on_content_timeout:
		return

	for session in server.sessions():
		if session.state == DotClientSession.State.DOWNLOADING:
			server.kick(session, "Could not download the new game content in time")


## Frees the old scene and instantiates the new one.
func _swap_to(descriptor: DotGameDescriptor) -> DotResult:
	phase = Phase.SWAPPING

	var previous := _current

	_unload_current()

	var scene_path := descriptor.resolve_scene_path()

	if scene_path == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' has no scene to load." % descriptor.game_id
		)

	if not ResourceLoader.exists(scene_path):
		# Restore the previous game so a wrong scene name inside synced content leaves a game.
		DotLog.error(
			CHANNEL,
			"the game scene is missing",
			{"game": descriptor.game_id, "path": scene_path}
		)

		if previous != null:
			DotLog.info(CHANNEL, "restoring the previous game")
			_current = previous
			_instantiate(previous.resolve_scene_path())

		return DotResult.fail(
			DotError.CODE_IO, "The game scene is missing.", scene_path
		)

	var instantiated := _instantiate(scene_path)
	if not instantiated.ok:
		return instantiated

	_current = descriptor

	# Through `set_cvar`, so validators and the `changed` signal apply; a direct write moves nobody.
	_apply_descriptor_cvars(descriptor, false)

	if server.console != null:
		server.console.exec_config(
			server.config.game_config_prefix + descriptor.game_id, null, false
		)

	DotLog.info(
		CHANNEL,
		"game loaded",
		{"game": descriptor.game_id, "scene": scene_path}
	)

	_restart_loading(descriptor)

	if server.events != null:
		server.events.notify("game_changed", {
			"game": descriptor.game_id,
			"content_key": descriptor.content_key(),
		})

	game_loaded.emit(descriptor.content_key())

	if server.chat != null:
		server.chat.broadcast_system(
			"Now playing %s." % descriptor.display_name_or_id()
		)

	return DotResult.success(descriptor)


## Puts everyone who has the content back through loading so the client rebuilds its scene.
##
## Only sessions that got as far as loading once: one still connecting is sent the game by the join flow.
func _restart_loading(descriptor: DotGameDescriptor) -> void:
	for session in server.sessions():
		if not session.is_active():
			continue
		if session.state != DotClientSession.State.DOWNLOADING \
			and session.state != DotClientSession.State.LOADING \
			and session.state != DotClientSession.State.SPAWNED:
			continue
		if session.content_key == descriptor.content_key() \
			or not descriptor.needs_delivered_content():
			session.transition_to(DotClientSession.State.LOADING)
			server._send_load_game(session)


## Applies a descriptor's [member DotGameDescriptor.cvars].
## An unregistered name is counted, not wrong, on the first pass (its module loads after [signal game_loaded]);
## [method reapply_descriptor_cvars] is where it is wrong. A registered cvar refusing its value always warns.
func _apply_descriptor_cvars(descriptor: DotGameDescriptor, unknown_is_wrong: bool) -> int:
	if server.console == null or descriptor.cvars.is_empty():
		return 0

	var applied := 0
	var unknown := PackedStringArray()

	for name: Variant in descriptor.cvars:
		var cvar_name := str(name)
		var value := str(descriptor.cvars[name])

		if server.console.find_cvar(cvar_name) == null:
			unknown.append(cvar_name)

			if unknown_is_wrong:
				DotLog.warn(CHANNEL, "a game names a cvar nothing registers", {
					"game": descriptor.game_id, "cvar": cvar_name, "value": value,
					"hint": "a typo, or a module that did not load",
				})

			continue

		var result := server.console.set_cvar(cvar_name, value)

		if result.ok:
			applied += 1
			continue

		DotLog.warn(CHANNEL, "a game's cvar was refused its value", {
			"game": descriptor.game_id, "cvar": cvar_name, "value": value,
			"why": result.error.message,
		})

	DotLog.info(CHANNEL, "the game's cvars were applied", {
		"game": descriptor.game_id,
		"applied": applied,
		"of": descriptor.cvars.size(),
		"not_registered_yet": Array(unknown),
	})

	return applied


## Applies the running game's cvars again. For a host that has just loaded its module.
##
## The first pass runs before a host registers the module's cvars, so those were refused as unknown.
func reapply_descriptor_cvars() -> int:
	if _current == null:
		return 0

	return _apply_descriptor_cvars(_current, true)


func _instantiate(scene_path: String) -> DotResult:
	var packed := load(scene_path)
	if not (packed is PackedScene):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The game scene is not a PackedScene.",
			scene_path
		)

	var instance := (packed as PackedScene).instantiate()
	if instance == null:
		return DotResult.fail(
			DotError.CODE_INTERNAL,
			"The game scene could not be instantiated.",
			scene_path
		)

	if _game_root == null:
		_game_root = game_root_ref.resolve_or_null(self, CHANNEL)
	if _game_root == null:
		instance.queue_free()
		return DotResult.fail(
			DotError.CODE_STATE, "There is no game root node to add the scene to."
		)

	if server != null:
		_server_children_before_game = server.get_children()

	_scene_instance = instance
	_game_root.add_child(instance)

	return DotResult.success(instance)


## Frees the running scene.
##
## Freed at once, not queued: two games in the tree for a frame duplicate nodes, groups and physics.
func _unload_current() -> void:
	if _scene_instance == null:
		return

	var previous_key := current_content_key()

	if is_instance_valid(_scene_instance):
		_game_root.remove_child(_scene_instance)
		_scene_instance.free()

	_scene_instance = null

	_free_game_children()

	# The map belonged to the game that just went. Cleared here rather than when the
	# next one loads, because the next game's module is what sets it again and it does
	# so from `game_loaded`, after this.
	_current_map = ""

	# Release the old content's cache references so dot-cloud may evict it. The
	# pack's file table stays mounted — the engine offers no way to remove it — but
	# nothing points at those paths any more.
	var cloud := DotRegistry.get_service(&"dot_cloud_client")
	if cloud != null and previous_key != "" and cloud.has_method("release"):
		cloud.call("release", previous_key)

	DotLog.debug(CHANNEL, "previous game unloaded", {"was": previous_key})


## Retires what the game that just went put under the server: its RPC link, above all.
## Renamed now, freed [constant RETIRED_SECONDS] later: left in place, the next load of the same game was
## renamed `@Node@<n>` and the RPC paths disagreed; freed at once, in-flight requests were engine errors.
func _free_game_children() -> void:
	if server == null or not is_instance_valid(server):
		_server_children_before_game.clear()
		return

	var retired: Array[Node] = []

	for child in server.get_children():
		if child in _server_children_before_game:
			continue
		retired.append(child)
		child.name = "%s_retired_%d" % [child.name, child.get_instance_id()]

	_server_children_before_game.clear()

	if retired.is_empty() or not server.is_inside_tree():
		return

	DotLog.debug(CHANNEL, "retired what the game left under the server", {
		"nodes": retired.size(),
	})

	server.get_tree().create_timer(RETIRED_SECONDS, true, false, true).timeout.connect(
		_free_ids.bind(retired.map(func(n: Node) -> int: return n.get_instance_id())))


## Frees the nodes still alive by instance id; a lambda capturing them errors once one is freed early.
static func _free_ids(ids: Array) -> void:
	for id in ids:
		var node := instance_from_id(id) as Node
		if node != null and not node.is_queued_for_deletion():
			node.queue_free()
