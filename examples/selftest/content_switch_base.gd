extends Node

## State, harness and the publish and boot steps of content_switch.gd.

const DATA := "user://dot_server_content_switch"
const DIST := DATA + "/dist"
const SOURCE := DATA + "/src"
const CACHE_SERVER := DATA + "/cache_server"
const CACHE_CLIENT := DATA + "/cache_client"

## The delivered game's identity. Version is in the mount path, by dot-cloud's rule.
const PACK_ID := "delivered_arena"
const PACK_VERSION := "1.0.0"
const PACK_SCENE := "world.tscn"
# A dependency is always an owner/name pack, the shape the site publishes.
const DEP_ID := "test/shared-assets"
const DEP_VERSION := "1.0.0"
const DEP_SOURCE := DATA + "/dep_src"

# A pack only the server mounts, and a map the game offers but does not load up front.
const SRV_ID := "test/server-only"
const SRV_VERSION := "1.0.0"
const SRV_SOURCE := DATA + "/srv_src"
const MAP_KEY := "test/map_a@1.0.0"

## A fixed port, because [DotServer] does not report the one an ephemeral bind chose
## and the client half of this test has to be told where to connect.
const PORT := 27515

## The address the server hands out. Deliberately one nothing dials: this pack is
## served from a local search directory, so the check is that the address REACHES the
## client's content layer, not that anything downloads from it.
const CONTENT_BASE := "https://content.invalid/content"

## Every check this suite runs, including the one that compares against it. The section
## counter cannot see a section that aborted after announcing itself — its remaining checks
## simply never run — and a total can. See docs/testing.md.
const CHECKS := 71

## The name a game's RPC node is given on both ends, for the retirement checks.
const GAME_NODE := &"GameLink"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()
var _entered := 0
var _completed := 0

var _server: DotServer = null
var _server_cloud: Node = null
var _client_side: Node = null
var _client_cloud: Node = null
var _link: DotClientLink = null

# Arrays, because a lambda captures locals by value: a flag set in a handler stays false outside.
var _spawned := [false]
var _refused := [""]
var _games_seen: Array[String] = []
var _progress_calls := [0]

var _manifest_url := ""

## The stand-in game nodes added under the server and the client link while arena runs.
var _game_nodes: Array = []



func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)


func _done() -> void:
	_completed += 1


func _check(condition: bool, what: String, detail: String = "") -> bool:
	if condition:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what if detail == "" else "%s — %s" % [what, detail])
		print("  FAIL  %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
	return condition


func _until(condition: Callable, seconds: float = 20.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)

	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame

	return bool(condition.call())


## A named method, not a lambda: a two-line lambda condition is a parse error, and a parse
## error makes the scene hang rather than fail.
func _client_playing() -> bool:
	return _server.sessions().size() > 0 \
		and _server.sessions()[0].state == DotClientSession.State.SPAWNED


func _told_lobby_again() -> bool:
	return _games_seen.size() >= 3 and _games_seen[_games_seen.size() - 1] == "lobby"


func _at_game(game_id: String) -> bool:
	var current := _server.games.current()
	return current != null and current.game_id == game_id \
		and _server.games.phase == DotGameManager.Phase.IDLE



## Publishes a real signed pack containing a real scene, signed because the refusal of
## unsigned content is the control.
func _publish_content() -> bool:
	_section("publishing a delivered game")

	# No script: a mounted pack's `class_name` globals are not registered in the host, so
	# cross-file type references in a pack scene fail to compile.
	var scene := (
		"[gd_scene format=3]\n\n"
		+ "[node name=\"DeliveredWorld\" type=\"Node\"]\n"
	)

	var written := DotPaths.write_text(SOURCE.path_join(PACK_SCENE), scene)
	if not _check(written.ok, "the source scene is written", str(written.error)):
		_done()
		return false

	var keys := DotCloudSignature.generate_keypair()
	if not _check(keys.ok, "a signing key pair is generated", str(keys.error)):
		_done()
		return false

	var pair: Dictionary = keys.value

	var publisher := DotCloudPublisher.new()
	publisher.content_id = PACK_ID
	publisher.version = PACK_VERSION
	publisher.display_name = "Delivered Arena"
	publisher.entry_scene = PACK_SCENE
	publisher.signing_key_pem = str(pair["private"])
	publisher.signing_key_id = "test"

	# Must agree with DotCloudClient.manifest_url_template so `ensure` finds the pack by id
	# and version as well as by URL.
	var out := "%s/%s/%s" % [DIST, PACK_ID, PACK_VERSION]

	var published := publisher.publish(SOURCE, out)
	if not _check(published.ok, "the pack publishes", str(published.error)):
		_done()
		return false

	_manifest_url = out.path_join("manifest.json")

	_publish_side_packs(pair)

	_check(
		FileAccess.file_exists(_manifest_url),
		"a signed manifest is on disk",
		_manifest_url
	)
	_check(
		DirAccess.dir_exists_absolute(out.path_join("objects")),
		"with its objects beside it"
	)

	# HTTPRequest cannot fetch `user://`, so a disk-served manifest needs the client to read
	# local paths itself.
	_check(
		DotCloudClient.is_local_manifest_url(_manifest_url),
		"and the client recognises it as a local path rather than a URL"
	)

	_client_cloud = _make_cloud(CACHE_CLIENT, str(pair["public"]), &"")
	_server_cloud = _make_cloud(CACHE_SERVER, str(pair["public"]), &"server")

	_done()
	return true

func _publish_side_packs(pair: Dictionary) -> void:
	# A second pack the game names as a DEPENDENCY: a map or asset pack that has to be
	# mounted beside the game's own, on the server and on every client, before anyone
	# is told the change is ready.
	DotPaths.write_text(DEP_SOURCE.path_join("shared.txt"), "shared assets\n")
	var dep := DotCloudPublisher.new()
	dep.content_id = DEP_ID
	dep.version = DEP_VERSION
	dep.display_name = "Shared Assets"
	dep.signing_key_pem = str(pair["private"])
	dep.signing_key_id = "test"
	var dep_published := dep.publish(DEP_SOURCE, "%s/%s/%s" % [DIST, DEP_ID, DEP_VERSION])
	_check(dep_published.ok, "a dependency pack publishes beside it", str(dep_published.error))

	# And one the game needs on the SERVER only: never in a client's content.sync.
	DotPaths.write_text(SRV_SOURCE.path_join("server.txt"), "server only\n")
	var srv := DotCloudPublisher.new()
	srv.content_id = SRV_ID
	srv.version = SRV_VERSION
	srv.display_name = "Server Only"
	srv.signing_key_pem = str(pair["private"])
	srv.signing_key_id = "test"
	var srv_published := srv.publish(SRV_SOURCE, "%s/%s/%s" % [DIST, SRV_ID, SRV_VERSION])
	_check(srv_published.ok, "a server-only pack publishes beside them", str(srv_published.error))


## A cloud client fed from the published directory. [param scope] keeps the two halves apart
## in [DotRegistry]; the server's is the scoped one.
func _make_cloud(cache: String, public_key: String, scope: StringName) -> Node:
	var config := DotCloudConfig.new()
	config.cache_dir = cache
	config.require_signed_manifests = true
	config.trusted_keys = {"test": public_key}

	var cloud := DotCloudClient.new()
	cloud.name = "Cloud" + (String(scope) if scope != &"" else "Client")
	cloud.config = config
	# Empty so a file left by another run cannot change what this test asserts.
	cloud.config_file = ""
	cloud.local_search_dirs = PackedStringArray([
		"%s/%s/%s" % [DIST, PACK_ID, PACK_VERSION],
		# A dependency is resolved by id under `{base}/{id}/{version}`, so its base is the root.
		DIST,
	])
	cloud.service_scope = scope
	return cloud



func _boot_config() -> DotServerConfig:
	var config := DotServerConfig.new()
	config.hostname = "content-switch"
	config.server_id = "content-switch-1"
	config.port = PORT
	config.max_players = 8
	config.tickrate = 30
	config.rcon_password = "content-switch-rcon-password"
	config.a2s_enabled = false
	config.query_enabled = false
	config.hibernate_when_empty = false
	# Not a real host: the pack is served from a local directory, and the check is only that
	# the address reaches the client's content layer.
	config.content_base_urls = PackedStringArray([CONTENT_BASE])
	config.admins_path = DATA.path_join("admins.json")
	config.bans_path = DATA.path_join("bans.json")
	config.audit_log_path = DATA.path_join("audit.jsonl")
	# The addon ships a server.cfg the search path would find, which is correct
	# layering and would make this assert against whatever it contains.
	config.startup_config = ""
	config.autoexec_config = ""
	return config


func _add_boot_games() -> void:
	var builtin := DotGameDescriptor.new()
	builtin.game_id = "lobby"
	builtin.display_name = "Lobby"
	builtin.version = "1.0.0"
	builtin.scene = "res://examples/fixtures/lobby_world.tscn"

	var delivered := DotGameDescriptor.new()
	delivered.game_id = "arena"
	delivered.display_name = "Delivered Arena"
	delivered.content_id = PACK_ID
	delivered.version = PACK_VERSION
	delivered.manifest_url = _manifest_url
	# Relative, so it resolves under each side's mount prefix; DotClientLink refuses an
	# absolute path.
	delivered.scene = PACK_SCENE
	delivered.client_scene = PACK_SCENE
	delivered.dependencies = PackedStringArray(["%s@%s" % [DEP_ID, DEP_VERSION]])
	delivered.server_dependencies = PackedStringArray(["%s@%s" % [SRV_ID, SRV_VERSION]])
	# Never published: a map is fetched when the server changes to it, so naming one the
	# origin does not have must not stop the GAME from loading.
	delivered.maps = PackedStringArray([MAP_KEY])

	_check(delivered.validate().ok, "the delivered descriptor validates")

	var unpinned := DotGameDescriptor.new()
	unpinned.game_id = "unpinned"
	unpinned.scene = "res://examples/fixtures/lobby_world.tscn"
	unpinned.maps = PackedStringArray(["test/map_b"])
	_check(
		not unpinned.validate().ok,
		"a map with no pinned version is refused, as a dependency is"
	)
	_check(
		delivered.content_key() == "%s@%s" % [PACK_ID, PACK_VERSION],
		"and names its content key (%s)" % delivered.content_key()
	)
	_check(
		delivered.client_scene_or_scene() == PACK_SCENE,
		"and hands the client a relative scene path (%s)"
			% delivered.client_scene_or_scene()
	)

	_server.games.add_game(builtin)
	_server.games.add_game(delivered)

	# Short, because nothing here is downloading over a network and a real timeout
	# would make a regression take fifteen minutes to report.
	_server.games.sync_timeout_sec = 30.0


func _load_lobby_awake() -> bool:
	# A game loads AWAKE: an empty server hibernates (at boot, now), and a game reads its tick
	# rate from the engine as it starts, so a load at the hibernate rate started the delivered
	# playground's netcode at 5 Hz and it refused. Hibernated first, then the load watched.
	_server.config.hibernate_when_empty = true
	_server._maybe_hibernate()
	var asleep_before := _server.is_hibernating()
	var at_load := [-1, false]
	var watch := func(_key: String) -> void:
		at_load[0] = Engine.physics_ticks_per_second
		at_load[1] = _server.is_hibernating()
	_server.games.game_loaded.connect(watch)

	var initial := await _server.games.change_game("lobby", "boot")
	if not _check(initial.ok, "the lobby loads", str(initial.error)):
		_done()
		return false
	_server.games.game_loaded.disconnect(watch)
	await get_tree().process_frame
	_check(asleep_before and int(at_load[0]) == 30 and not bool(at_load[1]),
		"an empty, hibernating server is awake at its own tick rate while a game loads",
		"before %s, at load %d Hz, hibernating %s" % [asleep_before, int(at_load[0]), at_load[1]])
	_check(_server.is_hibernating(), "and goes back to sleep after it, still empty")
	# The rest of this suite is about switching, not sleeping.
	_server._apply_hibernate_setting(false)
	return true


func _boot() -> bool:
	_section("booting a server with one builtin game and one delivered one")

	var config := _boot_config()

	# Each half gets its own MultiplayerAPI, because an RPC is addressed by node path from the
	# API root and the two Server nodes sit at different paths (`Node not found`, then a
	# timeout). Scoped before boot(), which assigns the peer.
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	_client_side = Node.new()
	_client_side.name = "ClientSide"
	add_child(_client_side)

	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), server_side.get_path()
	)
	get_tree().set_multiplayer(
		MultiplayerAPI.create_default_interface(), _client_side.get_path()
	)

	_check(
		get_tree().get_multiplayer(server_side.get_path())
			!= get_tree().get_multiplayer(_client_side.get_path()),
		"the two halves have separate MultiplayerAPI instances"
	)

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)

	# Added under the server's half so the scoped registration (in `_ready`) happens before
	# anything looks the service up.
	_server.add_child(_server_cloud)

	var booted := await _server.boot()
	if not _check(booted.ok, "the server boots", str(booted.error)):
		_done()
		return false

	_add_boot_games()

	if not await _load_lobby_awake():
		return false

	_client_side.add_child(_client_cloud)
	_done()
	return true


func _teardown() -> void:
	if _link != null and is_instance_valid(_link):
		_link.disconnect_from_server("test over")

	if _server != null and is_instance_valid(_server):
		_server.shutdown("test over")
		var side := _server.get_parent()
		side.remove_child(_server)
		_server.free()
