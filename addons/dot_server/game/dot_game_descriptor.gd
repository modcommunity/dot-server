@tool
class_name DotGameDescriptor
extends Resource

## One game (or map, or mode) the server can run. A [Resource] so an operator can
## configure it in the inspector and a module can build one; it only names content and a
## scene, since fetching content is dot-cloud's business.

## Stable identifier, used by `changelevel` and in config filenames.
##
## Slug-safe, because it becomes a path component of the per-game config file.
@export var game_id: String = ""

## Name shown to players.
@export var display_name: String = ""

## Content version, matching the manifest's. Part of the content key.
@export var version: String = ""

@export_group("Content")

## dot-cloud manifest URL: an override, not the switch. Delivery is decided by
## [method needs_delivered_content] (a relative scene path); set this only when the content
## lives somewhere a client's bases do not reach.
@export var manifest_url: String = ""

## Content id from the manifest, if it differs from [member game_id] (one content set
## backing several modes).
@export var content_id: String = ""

## Optional content groups to fetch. Empty fetches only required content.
@export var content_groups: PackedStringArray = PackedStringArray()

## Other packs mounted beside this game's own, as `<owner>/<name>@<version>`, fetched by the
## server before a change and by every client in the same sync. A concrete version always:
## `@latest` is resolved by the installer, so all players mount the same bytes.
@export var dependencies: PackedStringArray = PackedStringArray()

## Packs only the SERVER needs (bot navigation, a ruleset, a replay recording): mounted with
## the game's own, never sent to a client, which [member dependencies] would force to
## download them. Same key rule: `<owner>/<name>@<version>`, a concrete version.
@export var server_dependencies: PackedStringArray = PackedStringArray()

## The maps this game offers, as delivered packs `<owner>/<map id>@<version>`. Not mounted at
## load: a map is fetched when the server changes to it. The game turns these into
## [code]DotMapDef[/code]s; the installer checks each pack, so a typo fails at startup.
@export var maps: PackedStringArray = PackedStringArray()

@export_group("Scenes")

## Scene the server instantiates: a [code]res://[/code] path in the build, or a path inside
## downloaded content (resolved under the mount prefix).
@export var scene: String = ""

## Scene the client instantiates, when it differs (a dedicated server loads a headless one).
## Empty means clients use [member scene].
@export var client_scene: String = ""

@export_group("Rules")

## Cvars applied when this game loads, as [code]name -> value[/code]. The per-game
## [code].cfg[/code] runs afterwards, so an operator can override these.
@export var cvars: Dictionary = {}

## Player slots for this game. 0 uses the server's.
@export var max_players: int = 0

## Minimum players before the game starts. Advisory; the game decides.
@export var min_players: int = 0

@export_group("Metadata")

## Free-form data for game code and server listings.
@export var metadata: Dictionary = {}


## Checks the descriptor is usable before a change is attempted, so a mistake is a refused
## command rather than a half-completed switch. Called by [DotGameManager] on every change.
func validate() -> DotResult:
	if game_id.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID, "A game descriptor needs a game_id."
		)

	# A game built into a server is one name (`lobby`); a published one is its
	# publisher's and is `<owner>/<name>` (`gamemann/game-arena`), so forks and
	# same-named games from two people are two ids. Each half is a slug.
	var halves := game_id.split("/")
	if halves.size() > 2:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"game_id is a name or <owner>/<name>, with one slash at most.",
			"got '%s'" % game_id
		)
	for half in halves:
		var slug := DotPaths.slugify(half)
		if half == "" or slug != half:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"game_id must be lowercase alphanumeric with - or _, as a name or <owner>/<name>.",
				"got '%s', try '%s'" % [game_id, "/".join(Array(halves).map(func(h): return DotPaths.slugify(h)))]
			)

	if scene.strip_edges() == "" and client_scene.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"'%s' names no scene." % game_id
		)

	if scene != "" and not scene.contains("://"):
		var safe := DotPaths.safe_relative(scene)
		if not safe.ok:
			return safe.wrap("'%s' has an unsafe scene path." % game_id)

	for list: Array in [
		[dependencies, "dependency"],
		[server_dependencies, "server dependency"],
		[maps, "map"],
	]:
		for key in (list[0] as PackedStringArray):
			var parts := split_key(key)
			if parts[0] == "" or parts[1] == "" or not parts[0].contains("/"):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"'%s' has a %s that is not <owner>/<name>@<version>." % [game_id, list[1]],
					"got '%s'; @latest is resolved when the game is installed, not here" % key
				)

	return DotResult.success(true)


## `<id>@<version>` taken apart from the right, as `[id, version]`. The same split the
## client does on a content key: an id never ends in `@`, a version never holds one.
static func split_key(key: String) -> PackedStringArray:
	var at := key.strip_edges().rfind("@")
	if at <= 0:
		return PackedStringArray([key.strip_edges(), ""])
	return PackedStringArray([key.substr(0, at).strip_edges(), key.substr(at + 1).strip_edges()])


## Whether this game's files must be fetched and mounted before it can load. A relative scene
## path IS the statement; [member manifest_url] is only an override for content whose client
## has no base for it.
func needs_delivered_content() -> bool:
	if manifest_url != "":
		return true
	if scene != "" and not scene.contains("://"):
		return true
	return client_scene != "" and not client_scene.contains("://")


## The content id the manifest uses.
func effective_content_id() -> String:
	return content_id if content_id != "" else game_id


## Key identifying this exact content, matching dot-cloud's: [code]id@version[/code], so a
## client's reported content can be checked against the server's.
func content_key() -> String:
	# Never empty for a delivered game: the key is what a client reports back and what
	# `DotClientLink._resolve_scene` splits to build the mount path, so an empty one would
	# tell the client to download something with no name.
	if not needs_delivered_content():
		return ""
	return "%s@%s" % [
		effective_content_id(),
		version if version != "" else "0.0.0",
	]


## Absolute path of the scene the server loads. A relative path resolves under dot-cloud's
## mount prefix, [code]res://dot_cloud/<content_id>/<version>/[/code].
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


## The client scene path as sent to clients: relative when downloaded, so a client resolves it
## under its own mount, never a server-named [code]res://addons/…[/code]. Empty for a game
## shipped in the build: the client reports ready and loads its own scene.
func client_scene_or_scene() -> String:
	if client_scene != "":
		return client_scene

	return scene if needs_delivered_content() else ""


func display_name_or_id() -> String:
	return display_name if display_name != "" else game_id


func describe() -> Dictionary:
	return {
		"game_id": game_id,
		"display_name": display_name_or_id(),
		"version": version,
		"content_key": content_key(),
		"bundled": not needs_delivered_content(),
		"dependencies": Array(dependencies),
		"server_dependencies": Array(server_dependencies),
		"maps": Array(maps),
		"scene": resolve_scene_path(),
		"client_scene": client_scene_or_scene(),
	}


func _to_string() -> String:
	return "DotGameDescriptor(%s)" % game_id
