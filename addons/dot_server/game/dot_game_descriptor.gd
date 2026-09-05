@tool
class_name DotGameDescriptor
extends Resource

## One game (or map, or mode) the server can run.
##
## A [Resource] so an operator configures it in the inspector or a
## [code].tres[/code] file, and so a module can build one at runtime. Deliberately
## thin: it names content and a scene, and everything about *fetching* that content
## is dot-cloud's business.

## Stable identifier, used by `changelevel` and in config filenames.
##
## Slug-safe, because it becomes a path component of the per-game config file.
@export var game_id: String = ""

## Name shown to players.
@export var display_name: String = ""

## Content version, matching the manifest's. Part of the content key.
@export var version: String = ""

@export_group("Content")

## dot-cloud manifest URL. Empty means the game ships inside the build.
##
## When set, joining and switching clients are sent to fetch it before the scene
## loads.
@export var manifest_url: String = ""

## Content id from the manifest, if it differs from [member game_id].
##
## They are usually the same. This exists for the case where one content set backs
## several game modes.
@export var content_id: String = ""

## Optional content groups to fetch. Empty fetches only required content.
@export var content_groups: PackedStringArray = PackedStringArray()

@export_group("Scenes")

## Scene the server instantiates.
##
## May be a [code]res://[/code] path in the build, or a path inside downloaded
## content — in which case it resolves under the mount prefix.
@export var scene: String = ""

## Scene the client instantiates, when it differs.
##
## A dedicated server usually loads a headless authoritative scene while clients
## load one with rendering and UI. Empty means clients use [member scene].
@export var client_scene: String = ""

@export_group("Rules")

## Cvars applied when this game loads, as [code]name -> value[/code].
##
## Convenient for per-game rules without a config file. The per-game
## [code].cfg[/code] still runs afterwards, so an operator can override these.
@export var cvars: Dictionary = {}

## Player slots for this game. 0 uses the server's.
@export var max_players: int = 0

## Minimum players before the game starts. Advisory; the game decides.
@export var min_players: int = 0

@export_group("Metadata")

## Free-form data for game code and server listings.
@export var metadata: Dictionary = {}


## Checks the descriptor is usable before a change is attempted.
##
## Called by [DotGameManager] on every change, so a mistake surfaces as a refused
## command rather than a half-completed switch.
func validate() -> DotResult:
	if game_id.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "A game descriptor needs a game_id."
		)

	var slug := DotPaths.slugify(game_id)
	if slug != game_id:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"game_id must be lowercase alphanumeric with - or _.",
			"got '%s', try '%s'" % [game_id, slug]
		)

	if scene.strip_edges() == "" and client_scene.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' names no scene." % game_id
		)

	# A relative scene path is resolved against downloaded content, so a game with
	# no manifest and a relative path can never resolve.
	if scene != "" and not scene.contains("://") and manifest_url == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' has a relative scene path but no manifest_url." % game_id,
			"either use a res:// path, or set manifest_url so the content is fetched"
		)

	if scene != "" and not scene.contains("://"):
		var safe := DotPaths.safe_relative(scene)
		if not safe.ok:
			return safe.wrap("'%s' has an unsafe scene path." % game_id)

	return DotResult.success(true)


## The content id the manifest uses.
func effective_content_id() -> String:
	return content_id if content_id != "" else game_id


## Key identifying this exact content, matching dot-cloud's.
##
## [code]id@version[/code], so two versions of one game are distinct — which is what
## lets a client's reported content be checked against the server's.
func content_key() -> String:
	if manifest_url == "":
		return ""
	return "%s@%s" % [
		effective_content_id(),
		version if version != "" else "0.0.0",
	]


## Absolute path of the scene the server loads.
##
## An absolute path is used as-is; a relative one resolves under dot-cloud's mount
## prefix, which is [code]res://dot_cloud/<content_id>/<version>/[/code].
func resolve_scene_path() -> String:
	return _resolve(scene)


func resolve_client_scene_path() -> String:
	var path := client_scene if client_scene != "" else scene
	return _resolve(path)


func _resolve(path: String) -> String:
	if path == "":
		return ""
	if path.contains("://"):
		return path
	return "res://dot_cloud/%s/%s/%s" % [
		effective_content_id(),
		version if version != "" else "0.0.0",
		path,
	]


## The client scene path as sent to clients.
##
## Relative when the content is downloaded, so a client resolves it against its own
## mount prefix rather than trusting a server-supplied absolute path — which would
## let a server name [code]res://addons/…[/code] and have the client load it.
##
## [b]Empty for a game that ships inside the build.[/b] With no
## [member manifest_url] there is no mount for a path to be inside, and
## [method DotClientLink._resolve_scene] refuses every absolute path that is not —
## so falling back to the server's own [member scene] could produce nothing but a
## refusal, and a game shipped with its client could not be joined at all. The empty
## string is the documented "you already have it" path: the client reports ready,
## enters play, and loads whatever scene its own build says is the client.
##
## A game delivered through dot-cloud sets [member client_scene] to a relative path
## and gets the mounted one instead.
func client_scene_or_scene() -> String:
	if client_scene != "":
		return client_scene

	return scene if manifest_url != "" else ""


func display_name_or_id() -> String:
	return display_name if display_name != "" else game_id


func describe() -> Dictionary:
	return {
		"game_id": game_id,
		"display_name": display_name_or_id(),
		"version": version,
		"content_key": content_key(),
		"bundled": manifest_url == "",
		"scene": resolve_scene_path(),
		"client_scene": client_scene_or_scene(),
	}


func _to_string() -> String:
	return "DotGameDescriptor(%s)" % game_id
