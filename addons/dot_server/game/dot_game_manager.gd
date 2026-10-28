@tool
class_name DotGameManager
extends "res://addons/dot_server/game/dot_game_manager_switch.gd"

## Loads and switches the running game while clients stay connected.
##
## [b]This is the flow the whole family exists to support.[/b] A `changelevel` on a
## dot-server is not a scene swap — it is: announce the new content, wait for every
## client to download and mount it, tear down the old scene, load the new one, and
## re-spawn everyone. Any of those can fail per-client, and a client that cannot get
## the new content has to be dropped rather than left in a world nobody else is in.
##
## [codeblock]
## announce -> clients DOWNLOADING -> all ready (or timeout) -> swap -> re-spawn
## [/codeblock]
##
## Server-side content handling delegates to dot-cloud when it is installed, which is
## discovered through [DotRegistry] rather than imported — a server whose games ship
## inside the build needs none of it.
##
## [b]On unloading.[/b] Godot cannot unmount a resource pack, so "unload" means
## freeing the scene and dropping references; dot-cloud's version-namespaced mount
## paths are what make that sufficient. See dot-cloud's docs/mounting.md.


func setup(p_server: DotServer) -> void:
	server = p_server
	DotRegistry.register(SERVICE, self)

	if game_root_ref == null:
		game_root_ref = DotNodeRef.of_created(&"GameRoot", Node)
	_game_root = game_root_ref.resolve_or_null(self, CHANNEL)

	server.client_state_changed.connect(_on_client_state_changed)

	if initial_game != "":
		var res := await change_game(initial_game, "boot")
		if not res.ok:
			DotLog.error(
				CHANNEL,
				"could not load the initial game",
				{"game": initial_game, "why": res.error.message}
			)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


## Switches to a game, syncing clients first.
##
## Returns when the new game is live, or with a failure that leaves the previous
## game running — a failed change must never leave the server with no game.
func change_game(game_id: String, by: String = "console") -> DotResult:
	if phase != Phase.IDLE:
		return DotResult.fail(
			DotError.CODE_STATE,
			"A game change is already in progress.",
			_pending.game_id if _pending != null else ""
		)

	var resolved := resolve_game(game_id)
	if not resolved.ok:
		return resolved

	var descriptor := resolved.value as DotGameDescriptor
	# Canonical id from here on, whichever spelling was typed.
	game_id = descriptor.game_id

	if _current != null and _current.game_id == game_id:
		return DotResult.fail(
			DotError.CODE_STATE, "'%s' is already running." % game_id
		)

	var validated := descriptor.validate()
	if not validated.ok:
		return validated

	if server.events != null:
		var event := server.events.fire("game_changing", {
			"from": current_content_key(),
			"to": descriptor.content_key(),
			"by": by,
		})
		if event.cancelled:
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				"The game change was blocked.",
				event.cancel_reason
			)

	_pending = descriptor

	DotLog.info(
		CHANNEL,
		"changing game",
		{"to": descriptor.game_id, "by": by, "clients": server.player_count()}
	)

	server.game_changing.emit(current_content_key(), descriptor.content_key())

	if server.chat != null:
		server.chat.broadcast_system(
			"Changing to %s…" % descriptor.display_name_or_id()
		)

	# A game shipped inside the build has no content to fetch and swaps at once.
	if descriptor.needs_delivered_content():
		var delivered := await _deliver_content(descriptor)
		if not delivered.ok:
			phase = Phase.IDLE
			_pending = null
			game_load_failed.emit(descriptor.content_key(), delivered.error)
			return delivered

	var swapped := await _swap_to(descriptor)

	phase = Phase.IDLE
	_pending = null

	if not swapped.ok:
		game_load_failed.emit(descriptor.content_key(), swapped.error)
		return swapped

	return swapped


## Switches to the next game in the rotation.
func next_game(by: String = "console") -> DotResult:
	var order := rotation if not rotation.is_empty() else game_ids()

	if order.is_empty():
		return DotResult.fail(
			DotError.CODE_STATE, "No games are configured."
		)

	# Start from the current game's position so the rotation is stable across a
	# change made by any other means.
	if _current != null:
		var current_index := Array(order).find(_current.game_id)
		if current_index >= 0:
			_rotation_index = current_index

	_rotation_index = (_rotation_index + 1) % order.size()

	return await change_game(order[_rotation_index], by)

func _on_client_state_changed(session: DotClientSession) -> void:
	if phase != Phase.SYNCING:
		return
	if session.state != DotClientSession.State.LOADING:
		return

	# A client that reached LOADING during a sync has the content. The waiting loop
	# reads content_key, so nothing more is needed here than the log line.
	DotLog.debug(
		CHANNEL, "client synced during change", {"user": session.label()}
	)
