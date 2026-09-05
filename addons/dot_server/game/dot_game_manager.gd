@tool
class_name DotGameManager
extends Node

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
## paths are what make that sufficient. See dot-cloud's CLAUDE.md.

const CHANNEL := "games"
const SERVICE := &"dot_game_manager"

## Emitted once the new game's scene is live.
signal game_loaded(content_key: String)

## Emitted when a change fails; the previous game is still running.
signal game_load_failed(content_key: String, error: DotError)

## Per-client readiness during a change.
signal change_progress(ready_count: int, total: int)

enum Phase {
	IDLE,
	## Clients are being told to fetch content.
	SYNCING,
	## Everyone is ready; the scene is being swapped.
	SWAPPING,
}

@export_group("Games")

## Games this server can run, by id.
@export var games: Array[DotGameDescriptor] = []

## Game loaded at boot. Empty means none.
@export var initial_game: String = ""

## Rotation used by `nextgame`. Empty falls back to [member games] order.
@export var rotation: PackedStringArray = PackedStringArray()

@export_group("Switching")

## Where the game's scene is added.
##
## Defaults to a child of this node. Point it at the host project's own container
## when the game scene must sit somewhere specific in the tree.
@export var game_root_ref: DotNodeRef = null

## Seconds to wait for every client to have the new content.
##
## Generous, because it covers a full download. Clients still syncing when it
## expires are dropped — see [member kick_on_content_timeout].
@export_range(10.0, 7200.0, 10.0) var sync_timeout_sec: float = 900.0

## Drop clients that have not got the content when the timeout expires.
##
## On, because the alternative is a player in a game whose world they do not have.
## Off keeps them connected in [constant DotClientSession.State.DOWNLOADING], which
## is only sensible while debugging.
@export var kick_on_content_timeout: bool = true

## Swap as soon as everyone is ready rather than waiting out the timeout.
@export var swap_when_all_ready: bool = true

var server: DotServer = null

var phase: Phase = Phase.IDLE

var _current: DotGameDescriptor = null
var _pending: DotGameDescriptor = null
var _scene_instance: Node = null
var _game_root: Node = null
var _sync_deadline: int = 0
var _rotation_index: int = 0


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


# --- Descriptors -----------------------------------------------------------

func find_game(game_id: String) -> DotGameDescriptor:
	for descriptor in games:
		if descriptor != null and descriptor.game_id == game_id:
			return descriptor
	return null


func game_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for descriptor in games:
		if descriptor != null:
			out.append(descriptor.game_id)
	return out


## Registers a game at runtime, for modules that add content.
func add_game(descriptor: DotGameDescriptor) -> DotResult:
	if descriptor == null or descriptor.game_id == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "A game descriptor needs a game_id."
		)

	if find_game(descriptor.game_id) != null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"A game with id '%s' is already registered." % descriptor.game_id
		)

	games.append(descriptor)
	return DotResult.success(descriptor)


# --- Changing --------------------------------------------------------------

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

	var descriptor := find_game(game_id)
	if descriptor == null:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"No game with id '%s'." % game_id,
			"known: %s" % ", ".join(Array(game_ids()))
		)

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

	# Clients only need to sync when the new game has content they must fetch. A
	# game shipped inside the build swaps immediately.
	if descriptor.manifest_url != "":
		# [b]The server fetches it first, and used to fetch it never.[/b] This class
		# has always announced the content, waited for every client to have it, and
		# then loaded `res://dot_cloud/<id>/<version>/<scene>` — a path that exists
		# only because something mounted the pack, and nothing here ever did. So a
		# delivered game could not be loaded by the server at all: every client
		# downloaded the content correctly, reported ready, and the swap then failed
		# with "the game scene is missing" and restored the previous game.
		#
		# Before the clients rather than after, because a server that cannot get the
		# content should abandon the change while nobody has been disturbed — the same
		# reason the scene is loaded before the old one is freed.
		var have := await _acquire_content(descriptor)
		if not have.ok:
			phase = Phase.IDLE
			_pending = null
			game_load_failed.emit(descriptor.content_key(), have.error)
			return have

		var synced := await _sync_clients(descriptor)
		if not synced.ok:
			phase = Phase.IDLE
			_pending = null
			game_load_failed.emit(descriptor.content_key(), synced.error)
			return synced

	var swapped := await _swap_to(descriptor)

	phase = Phase.IDLE
	_pending = null

	if not swapped.ok:
		game_load_failed.emit(descriptor.content_key(), swapped.error)
		return swapped

	return swapped


## Downloads and mounts the new game's content on this server.
##
## dot-cloud is found in [DotRegistry] rather than imported, for the family reason: a
## script naming a [code]class_name[/code] the project does not have fails to parse and
## takes everything referencing it down with it. A server whose games all ship inside
## its build never installs dot-cloud and never reaches this.
##
## [b]An absent cloud client is a refusal here, not a shrug.[/b] Everywhere else in the
## family that reads this service treats null as "this deployment ships its content in
## the build", which is a legitimate configuration — but not for a descriptor that
## names a [member DotGameDescriptor.manifest_url], because that says in so many words
## that this game's content is delivered. Falling through would leave the server asking
## clients to download something it cannot load itself.
func _acquire_content(descriptor: DotGameDescriptor) -> DotResult:
	var cloud := DotRegistry.get_service(&"dot_cloud_client")

	if cloud == null or not cloud.has_method("acquire"):
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
		{"game": descriptor.game_id, "url": descriptor.manifest_url}
	)

	var groups := PackedStringArray()
	for group in descriptor.content_groups:
		groups.append(String(group))

	var acquired: Variant = await cloud.call(
		"acquire", descriptor.manifest_url, groups
	)

	if acquired is DotResult:
		var typed: DotResult = acquired
		if not typed.ok:
			return typed.wrap(
				"Could not get %s's content." % descriptor.game_id
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

	var info := {
		"manifest_url": descriptor.manifest_url,
		"content_groups": Array(descriptor.content_groups),
		"content_key": descriptor.content_key(),
		"allow_netchan": server.config.allow_netchan_content,
		"chunk_bytes": server.config.netchan_chunk_bytes,
	}

	var expected := 0

	for session in server.sessions():
		if not session.is_active():
			continue
		# A client still authenticating will be sent to the new content by the
		# normal join flow when it gets there, so it is not waited for.
		if session.state == DotClientSession.State.CONNECTING \
			or session.state == DotClientSession.State.AUTHENTICATING:
			continue

		session.content_progress = 0.0
		# [b]Cleared, not left.[/b] The wait loop below decides a client is ready by
		# comparing `content_key` with the new game's — and a client that played this
		# game earlier in the session still holds exactly that string from the last
		# time it reported. So `lobby -> hungry -> lobby -> hungry` had every client
		# counted as ready on the first pass of the loop, before the RPC telling them
		# to download had even arrived, and the swap went out to clients still
		# mid-`acquire`. On a loopback the download finishes inside the first half
		# second and it looks like it worked.
		session.content_key = ""

		if not session.transition_to(DotClientSession.State.DOWNLOADING):
			# A session the state machine will not move is one this change cannot
			# include, and sending it the sync anyway is how a client ends up
			# downloading content nothing will ever ask it to load. Counted as
			# neither ready nor waiting is what the loop below already does with it;
			# saying so is what makes it findable.
			DotLog.warn(
				CHANNEL,
				"a client could not be sent to download",
				{"user": session.label(), "state": session.state_name()}
			)
			continue

		# [b]Announced, like every other state change.[/b] `client_state_changed` is
		# how a module, an admin panel or this manager's own hook learns what a
		# session is doing, and the join path emits it at every step — but the game
		# change, which is the one that moves everybody at once, emitted nothing. A
		# `status` listing showed the right state because it reads the field directly;
		# anything that reacted to the signal never saw a game change happen.
		server.client_state_changed.emit(session)
		server._begin_content_sync.rpc_id(session.peer_id, info)
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

		# `swap_when_all_ready` is what this reads. Off, the change waits out the whole
		# of `sync_timeout_sec` even when everybody already has the content, which is
		# what an operator wants when they are timing a change against something else
		# and nothing else. It used to be tested one line below an unconditional
		# `return` on the same condition, so it was a documented setting that decided
		# nothing — this family's most repeated bug.
		if waiting == 0 and swap_when_all_ready:
			DotLog.info(CHANNEL, "all clients synced", {"clients": ready_count})
			return DotResult.success(ready_count)

		if int(Time.get_unix_time_from_system()) >= _sync_deadline:
			DotLog.warn(
				CHANNEL,
				"content sync timed out",
				{"ready": ready_count, "waiting": waiting}
			)

			if kick_on_content_timeout:
				for session in server.sessions():
					if session.state == DotClientSession.State.DOWNLOADING:
						server.kick(
							session,
							"Could not download the new game content in time"
						)

			# Proceeding rather than failing: the players who did get the content
			# should not be denied the map change by the ones who could not.
			return DotResult.success(ready_count)

	return DotResult.success(0)


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
		# Restore the previous game so a typo'd path does not leave the server
		# empty. This is the case where content synced but the scene name inside it
		# is wrong.
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

	# Per-game config, so an operator can set different rules per map without a
	# module. The usual per-map cfg convention.
	if server.console != null:
		server.console.exec_config(
			server.config.game_config_prefix + descriptor.game_id, null, false
		)

	DotLog.info(
		CHANNEL,
		"game loaded",
		{"game": descriptor.game_id, "scene": scene_path}
	)

	# Everyone who has the content is put back through loading, so the client
	# rebuilds its own scene and reports ready. Clients still downloading are left
	# alone and will follow when they finish.
	#
	# [b]Only sessions that have got as far as loading once.[/b] A client still
	# connecting or authenticating has no scene to rebuild and is going to be sent
	# through the join flow — which ends in `_send_load_game` — the moment it gets
	# there. Sweeping the whole session list caught those too: for a game that ships
	# inside the build every session matched, so a client halfway through the
	# handshake was forced to LOADING (an illegal transition out of CONNECTING, so a
	# warning and nothing else) and sent a scene before it had submitted a
	# credential.
	for session in server.sessions():
		if not session.is_active():
			continue
		if session.state != DotClientSession.State.DOWNLOADING \
			and session.state != DotClientSession.State.LOADING \
			and session.state != DotClientSession.State.SPAWNED:
			continue
		if session.content_key == descriptor.content_key() \
			or descriptor.manifest_url == "":
			session.transition_to(DotClientSession.State.LOADING)
			server._send_load_game(session)

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

	_scene_instance = instance
	_game_root.add_child(instance)

	return DotResult.success(instance)


## Frees the running scene.
##
## Freed immediately rather than queued: the next scene is added in the same call,
## and two games in the tree at once means duplicate nodes, duplicate groups and
## duplicate physics for a frame.
func _unload_current() -> void:
	if _scene_instance == null:
		return

	var previous_key := current_content_key()

	if is_instance_valid(_scene_instance):
		_game_root.remove_child(_scene_instance)
		_scene_instance.free()

	_scene_instance = null

	# Release the old content's cache references so dot-cloud may evict it. The
	# pack's file table stays mounted — the engine offers no way to remove it — but
	# nothing points at those paths any more.
	var cloud := DotRegistry.get_service(&"dot_cloud_client")
	if cloud != null and previous_key != "" and cloud.has_method("release"):
		cloud.call("release", previous_key)

	DotLog.debug(CHANNEL, "previous game unloaded", {"was": previous_key})


# --- Rotation --------------------------------------------------------------

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


# --- Client sync tracking -------------------------------------------------

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


# --- Queries --------------------------------------------------------------

func current() -> DotGameDescriptor:
	return _current


func current_content_key() -> String:
	return _current.content_key() if _current != null else ""


## The content key of the game being changed to, while a change is in progress.
##
## [b]dot-server needs this to admit a client mid-change.[/b] `report_content_ready`
## checks what a client says it has against what this server is running, and for the
## whole of a sync those are deliberately different: the point of the sync is that
## clients get the new content [i]before[/i] the server swaps to it. Without the
## pending key to compare against, the correct answer looked like the wrong one and
## every client was dropped on every content-bearing game change.
func pending_content_key() -> String:
	return _pending.content_key() if _pending != null else ""


## The game being changed to, or null when no change is in progress.
func pending() -> DotGameDescriptor:
	return _pending


func current_content_id() -> String:
	return _current.game_id if _current != null else ""


func current_manifest_url() -> String:
	return _current.manifest_url if _current != null else ""


## The optional content groups the running game asks clients to fetch.
func current_content_groups() -> Array:
	return Array(_current.content_groups) if _current != null else []


## What a joining client is told to load.
func load_info() -> Dictionary:
	if _current == null:
		return {"game_id": "", "content_id": "", "scene": "", "content_key": ""}

	return {
		"game_id": _current.game_id,
		# [b]What the client is made of, as opposed to what this server calls it.[/b]
		# `game_id` is the operator's — it is what they type at the console and, in a
		# deployment that scans a directory, it is a directory name they chose. A client
		# holding a table of the games built into it cannot be keyed on that: renaming
		# `content/lobby` to `content/foyer` would leave every client unable to find the
		# scene for a game it has.
		#
		# `content_id` is the game's own identity and defaults to `game_id`, and its
		# documented purpose is exactly this case — "one content set backs several game
		# modes", which is what two modes sharing one client is.
		"content_id": _current.effective_content_id(),
		"scene": _current.client_scene_or_scene(),
		"content_key": _current.content_key(),
		"display_name": _current.display_name_or_id(),
	}


func describe_current() -> String:
	if _current == null:
		return "none"

	var s := _current.display_name_or_id()
	if _current.version != "":
		s += " (%s)" % _current.version
	if phase != Phase.IDLE:
		s += " — %s" % Phase.keys()[phase].to_lower()
	return s


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("current   %s" % describe_current())
	out.append("phase     %s" % Phase.keys()[phase].to_lower())

	if phase == Phase.SYNCING:
		var waiting := PackedStringArray()
		for session in server.sessions():
			if session.state == DotClientSession.State.DOWNLOADING:
				waiting.append("%s %d%%" % [
					session.display_name, int(session.content_progress * 100.0)
				])
		if not waiting.is_empty():
			out.append("waiting   %s" % ", ".join(Array(waiting)))

	out.append("")
	out.append("available games:")
	for descriptor in games:
		if descriptor == null:
			continue
		var marker := "*" if descriptor == _current else " "
		out.append("%s %-20s %s" % [
			marker,
			descriptor.game_id,
			descriptor.manifest_url if descriptor.manifest_url != "" else "(bundled)",
		])

	return out
