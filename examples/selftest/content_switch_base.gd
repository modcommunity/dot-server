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

# Captured through Arrays: GDScript lambdas capture locals by value, so a flag set
# inside a signal handler stays false outside it and the test reports a failure for a
# signal that fired perfectly.
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


## A named method rather than a lambda: a GDScript lambda's body ends at the newline,
## so a two-line condition inside a call is a parse error — and a parse error makes the
## scene fail to load and the process HANG rather than fail, which is the family's
## documented process hazard reached from a third direction.
func _client_playing() -> bool:
	return _server.sessions().size() > 0 \
		and _server.sessions()[0].state == DotClientSession.State.SPAWNED


func _told_lobby_again() -> bool:
	return _games_seen.size() >= 3 and _games_seen[_games_seen.size() - 1] == "lobby"


func _at_game(game_id: String) -> bool:
	var current := _server.games.current()
	return current != null and current.game_id == game_id \
		and _server.games.phase == DotGameManager.Phase.IDLE



## Publishes a real signed pack containing a real scene.
##
## Signed, not unsigned-with-the-check-off: a client that mounts content runs whatever
## scripts are in it, and the refusal is the control. A test that turns it off is
## testing a configuration nobody should ship.
func _publish_content() -> bool:
	_section("publishing a delivered game")

	# A minimal scene with no script. A scene inside a pack may not use a
	# `class_name` — a mounted pack's globals are NOT registered in the host, so
	# every cross-file type reference in it fails to compile. That is measured, and
	# it is why the games in dot-server-deploy are builtin.
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

	# Where the publisher writes is where the manifest is fetched from, and the two
	# have to agree with DotCloudClient.manifest_url_template for `ensure` to find it
	# by id and version. dot-server names a URL outright, so only this test's own
	# layout depends on it — but keeping them the same is what makes the id-and-
	# version form and the URL form address one file.
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

	# The manifest is a `user://` path, and until DotCloudClient learned to read one
	# it went through HTTPRequest, which cannot fetch `user://` or `res://` at all. So
	# a deployment serving content off the disk — which is what local_search_dirs is —
	# could reach every object in a pack and not the one document naming them.
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


## A cloud client fed from the published directory on disk.
##
## [param scope] keeps the two apart in [DotRegistry]: both halves run in this one
## process and the second would otherwise displace the first, which is exactly the
## case `service_scope` exists for. The server's is the scoped one, because everything
## that resolves the service by its plain name is client-side.
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
		# The dependency is found BY ID, through `{base}/{id}/{version}/manifest.json`,
		# so its base is the root the packs are published under, not a pack's folder.
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
	# What the server will tell clients about where its content lives. Not a real
	# host: the point of the check below is that the address REACHES the client's
	# content layer, and this pack is served out of a local search directory, so a
	# base that nothing dials proves the delivery without depending on a network.
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
	# Relative, so it resolves under the mount prefix on the server AND under the
	# client's own mount prefix. An absolute path here is refused by
	# DotClientLink._resolve_scene, correctly — a server that could name one could
	# ask a client to load any scene in its build.
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

	# [b]Each half gets its own MultiplayerAPI, scoped to its own subtree.[/b] Godot
	# addresses an RPC by the receiver's node path relative to its API root, which
	# defaults to `/root` — so a DotServer at `/root/ContentSwitch/Server` sends calls
	# addressed to "ContentSwitch/Server" and a DotClientLink at
	# `/root/ContentSwitch/ClientSide/Server` answers every one with `Node not found`,
	# the handshake included, whose only symptom is a timeout. Scoped, both ends send
	# and expect "Server" and neither has to know the other's scene.
	#
	# Scoped before boot(), because boot() is what assigns the peer.
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

	# Added under the server's half of the tree so the scoped registration happens
	# before anything asks for it. `_ready` is where DotCloudClient registers, for the
	# reason its own class doc gives: `start()` awaits and a consumer resolving the
	# service in between would get null from a client that was about to work.
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
