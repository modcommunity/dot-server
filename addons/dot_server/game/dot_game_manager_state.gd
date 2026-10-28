@tool
extends Node

## State, signals and descriptor lookup of [DotGameManager].

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

## Where the game's scene is added; a child of this node by default.
##
## Point it at the host's own container when the scene must sit somewhere specific.
@export var game_root_ref: DotNodeRef = null

## Seconds to wait for every client to have the new content.
##
## Covers a full download; clients still syncing at expiry follow [member kick_on_content_timeout].
@export_range(10.0, 7200.0, 10.0) var sync_timeout_sec: float = 900.0

## Drop clients that lack the content when the timeout expires.
##
## Off keeps them in [constant DotClientSession.State.DOWNLOADING]; only sensible while debugging.
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
var _current_map: String = ""

## How long a game's retired nodes outlive it: requests a client sent before LOAD_GAME reached
## it arrive within a round trip, and this is many of them. See [method _free_game_children].
const RETIRED_SECONDS := 10.0

## The server's children before the running game's scene went in. Anything else under the
## server arrived while that game ran, and goes with it. See [method _free_game_children].
var _server_children_before_game: Array[Node] = []


## The game an id names: exactly, or by its NAME half when that is unambiguous.
## A published id is `<owner>/<name>`, so `changelevel arena` works while one installed game is
## called `arena`; [method resolve_game] says which two there are once a second owner arrives.
func find_game(game_id: String) -> DotGameDescriptor:
	for descriptor in games:
		if descriptor != null and descriptor.game_id == game_id:
			return descriptor

	var matches := _by_short_name(game_id)
	return matches[0] if matches.size() == 1 else null


## [method find_game], with the reason when it finds nothing.
func resolve_game(game_id: String) -> DotResult:
	var found := find_game(game_id)
	if found != null:
		return DotResult.success(found)

	var matches := _by_short_name(game_id)
	if matches.size() > 1:
		var ids := PackedStringArray()
		for d in matches:
			ids.append(d.game_id)
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' is more than one game here; say whose." % game_id,
			"one of: %s" % ", ".join(ids)
		)

	return DotResult.fail(
		DotError.CODE_INVALID,
		"No game with id '%s'." % game_id,
		"known: %s" % ", ".join(Array(game_ids()))
	)


func _by_short_name(name: String) -> Array[DotGameDescriptor]:
	var out: Array[DotGameDescriptor] = []
	if name == "" or name.contains("/"):
		return out
	for descriptor in games:
		if descriptor != null and descriptor.game_id.ends_with("/" + name):
			out.append(descriptor)
	return out


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

	# Exact, not find_game: a built-in `arena` beside a published `alice/arena` is two
	# games, and the short-name alias must not make one look like a duplicate.
	if game_ids().has(descriptor.game_id):
		return DotResult.fail(
			DotError.CODE_STATE,
			"A game with id '%s' is already registered." % descriptor.game_id
		)

	games.append(descriptor)
	return DotResult.success(descriptor)


func current() -> DotGameDescriptor:
	return _current


func current_content_key() -> String:
	return _current.content_key() if _current != null else ""


## The content key of the game being changed to, while a change is in progress.
## A client reports the new content before the swap, so admission compares against this key too;
## without it every client was dropped on every content-bearing change.
func pending_content_key() -> String:
	return _pending.content_key() if _pending != null else ""


## The game being changed to, or null when no change is in progress.
func pending() -> DotGameDescriptor:
	return _pending


func current_content_id() -> String:
	return _current.game_id if _current != null else ""


## The map the running game says it is on, or "" when it has said nothing.
##
## Set by the game, because only the game knows what it calls a map; the query prints it.
func current_map() -> String:
	return _current_map


## Called by the running game whenever its map changes. "" clears it.
##
## Drops the query cache too (duck-typed, the query source is dot-server-query's).
func set_current_map(map_id: String) -> void:
	if map_id == _current_map:
		return

	_current_map = map_id
	DotLog.debug(CHANNEL, "map reported", {"map": map_id, "game": current_content_id()})

	if server != null and is_instance_valid(server.query_source) \
		and server.query_source.has_method("invalidate"):
		server.query_source.call("invalidate")


## What a listing should print as the map: the game's own map, else the game's display name.
##
## A game with no maps reads as a server "on" that game, and a display name beats a content id.
func reported_map() -> String:
	if _current_map != "":
		return _current_map
	return _current.display_name_or_id() if _current != null else ""


func current_manifest_url() -> String:
	return _current.manifest_url if _current != null else ""


## Whether the running game is delivered, and so whether a joining client must sync.
##
## Not "has a manifest_url"; see [method DotGameDescriptor.needs_delivered_content].
func current_needs_content() -> bool:
	return _current != null and _current.needs_delivered_content()


## The optional content groups the running game asks clients to fetch.
func current_content_groups() -> Array:
	return Array(_current.content_groups) if _current != null else []


## The packs the running game needs beside its own, as `<id>@<version>` keys.
func current_dependencies() -> PackedStringArray:
	return _current.dependencies if _current != null else PackedStringArray()


## The packs only the server mounts for the running game. Never sent to a client.
func current_server_dependencies() -> PackedStringArray:
	return _current.server_dependencies if _current != null else PackedStringArray()


## The running game's delivered maps, as `<owner>/<map id>@<version>` keys, for the game
## to turn into map definitions (dot-map's DotMapCatalogue.add_delivered). Empty for a
## game whose descriptor names none.
func current_maps() -> PackedStringArray:
	return _current.maps if _current != null else PackedStringArray()


## What a joining client is told to load.
func load_info() -> Dictionary:
	if _current == null:
		return {"game_id": "", "content_id": "", "scene": "", "content_key": ""}

	return {
		"game_id": _current.game_id,
		# The client keys its built-in games on `content_id`, not the operator's `game_id`
		# (a directory name they chose); it defaults to `game_id` and names one content set
		# that several game modes share.
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
	out.append("map       %s" % (_current_map if _current_map != "" else "(none reported)"))
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
			(
				descriptor.manifest_url if descriptor.manifest_url != ""
				else ("delivered: %s" % descriptor.content_key()
					if descriptor.needs_delivered_content() else "(bundled)")
			),
		])

	return out
