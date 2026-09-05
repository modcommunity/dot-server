extends Node

## Changing to a game whose content is DELIVERED, with a real client attached.
##
## [codeblock]
## godot --headless --path . res://examples/content_switch.tscn
## [/codeblock]
##
## Exits non-zero on any failure.
##
## [b]Why this exists when the family already switches games under a live client.[/b]
## Every game in every suite in this family ships inside its build. `manifest_url` is
## empty for all of them, and [method DotGameManager.change_game] skips the whole of
## [method DotGameManager._sync_clients] when it is — so the announce, the download, the
## per-client readiness wait, the timeout and the re-load were the four hundred lines
## that nothing had ever executed. Everything below the first section is a code path
## that this file is the first thing to reach, which is this family's own recurring
## lesson: [i]a code path only one deployment shape reaches is a code path nothing has
## run.[/i]
##
## It found four, all parse-clean and none of which produced an error where it was
## written:
##
## - [b]The server never fetched its own content.[/b] `change_game` announced the pack,
##   waited for every client to download it, and then loaded
##   [code]res://dot_cloud/<id>/<version>/<scene>[/code] — a path that exists only
##   because something mounted the pack, and nothing on the server ever did. A
##   delivered game could not be loaded at all; it failed with "the game scene is
##   missing" and restored the previous game, which reads as a bad scene name.
## - [b]Every client was kicked the moment it did the right thing.[/b]
##   `report_content_ready` compared the key a client reported against
##   [method DotGameManager.current_content_key] — and for the whole of a sync that is
##   deliberately the OLD game, because the point of the sync is that clients get the
##   new content before the server swaps. The correct answer looked wrong and the
##   client was dropped with "Your game content does not match the server's."
## - [b]A stale content key made a client look ready before it had been told.[/b]
##   `content_key` was never cleared when a sync began, so on the second change TO a
##   game a client had already played, the wait loop matched on the first pass and the
##   swap went out to clients still downloading.
## - [b]The download progress subscription was made again on every change.[/b] A fresh
##   lambda is a fresh [Callable], so the `is_connected` guard never matched its own
##   handler.
##
## Two [MultiplayerAPI] instances in one process, scoped with
## [method SceneTree.set_multiplayer], because there is one [member SceneTree.multiplayer]
## and both halves want it. Both link nodes are named [code]Server[/code] — RPCs are
## routed by node path relative to each API root, so the name is the routing.

const DATA := "user://dot_server_content_switch"
const DIST := DATA + "/dist"
const SOURCE := DATA + "/src"
const CACHE_SERVER := DATA + "/cache_server"
const CACHE_CLIENT := DATA + "/cache_client"

## The delivered game's identity. Version is in the mount path, by dot-cloud's rule.
const PACK_ID := "delivered_arena"
const PACK_VERSION := "1.0.0"
const PACK_SCENE := "world.tscn"

## A fixed port, because [DotServer] does not report the one an ephemeral bind chose
## and the client half of this test has to be told where to connect.
const PORT := 27515

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

	_teardown()
	DotPaths.remove_tree(DATA)

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- Harness ---------------------------------------------------------------

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


# --- Content ---------------------------------------------------------------

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
	# it is why the games in dot-server-setup-test are builtin.
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
		"%s/%s/%s" % [DIST, PACK_ID, PACK_VERSION]
	])
	cloud.service_scope = scope
	return cloud


# --- Boot ------------------------------------------------------------------

func _boot() -> bool:
	_section("booting a server with one builtin game and one delivered one")

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
	config.admins_path = DATA.path_join("admins.json")
	config.bans_path = DATA.path_join("bans.json")
	config.audit_log_path = DATA.path_join("audit.jsonl")
	# The addon ships a server.cfg the search path would find, which is correct
	# layering and would make this assert against whatever it contains.
	config.startup_config = ""
	config.autoexec_config = ""

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

	_check(delivered.validate().ok, "the delivered descriptor validates")
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

	var initial := await _server.games.change_game("lobby", "boot")
	if not _check(initial.ok, "the lobby loads", str(initial.error)):
		_done()
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


# --- Sections --------------------------------------------------------------

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

	# The client half: it really downloaded, verified and mounted the pack, and the
	# scene it is showing came out of it rather than out of its own build.
	_check(
		bool(_client_cloud.call("is_mounted", PACK_ID, PACK_VERSION)),
		"the client mounted the pack it was sent to fetch"
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
	_done()


func _test_switch_back() -> void:
	_section("and back to the builtin game")

	var result := _server.console.execute("changelevel lobby")
	_check(result.ok, "the command is accepted", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("lobby"), 30.0)
	_check(arrived, "the lobby comes back")
	_check(_refused[0] == "", "the client is still connected")

	var told := await _until(_told_lobby_again)
	_check(told, "and was told (%s)" % [_games_seen])
	_done()


## The change that a stale content key made look instant.
##
## Going back to a game the client has already played is the case where
## `session.content_key` still holds exactly the string the wait loop compares
## against. Without clearing it the client counted as ready on the first pass — before
## the RPC telling it to download had been processed at all — and the swap went out to
## a client that had not been asked for anything.
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

	var result := _server.console.execute("changelevel arena")
	_check(result.ok, "the command is accepted", str(result.error))

	var arrived := await _until(func() -> bool: return _at_game("arena"), 30.0)
	_check(arrived, "the server reaches it again")

	await _until(_client_playing)

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
