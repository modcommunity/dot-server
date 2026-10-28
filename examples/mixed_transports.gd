extends "res://examples/selftest/selftest_harness.gd"

## A browser player and a desktop player in one match, which is what `transport_mode: dual`
## is for and what nothing else asserts end to end.
##
## dot-core's `dual_transport_selftest` proves the peer: two engine peers behind one
## [DotDualPeer], packets routed to the right one. `signon_revision` proves a native client
## joins over ENet. Neither has a WebSocket player and an ENet player [b]in the same game[/b],
## and that is the claim the platform makes: a browser tab (TCP, it has no UDP) and the
## desktop app (UDP) play together, and a desktop player who cannot or will not use UDP
## falls back to, or chooses, the WebSocket and still plays with both.
##
## What is driven, over real loopback sockets:
##
##   1. A dual server boots and loads a game whose one rule is "the server relays what a
##      player says to everybody else" (fixtures/mixed_world).
##   2. A browser-style player joins over WebSocket (`transport_preference = "ws"`, which is
##      also what `--transport ws` makes the shell do: the opt-out).
##   3. A desktop player joins with the default `auto` and lands on ENet.
##   4. The server sees one match: both sessions playing, and each client's scoreboard lists both.
##   5. Reliable game RPCs cross both ways, WebSocket to ENet and ENet to WebSocket.
##   6. An unreliable stream crosses both ways, nearly whole on loopback.
##   6b. Which addresses a native WebSocket join tries over TLS first.
##   7. A desktop player whose UDP gets no answer falls back to WebSocket in about
##      `udp_connect_timeout_sec`, and plays with the other two.
##   8. The ENet player leaving disturbs nobody else.
##
## Run:
## [codeblock]
## godot --headless --path . res://examples/mixed_transports.tscn
## [/codeblock]

const PORT := 27731
## Nothing listens here, so a UDP connect to it is never answered: a firewall that drops UDP.
const DEAD_UDP_PORT := 27739

const WORLD := preload("res://examples/fixtures/mixed_world.gd")

## How many checks a clean run makes; asserted, so a section that aborts part-way shows.
const CHECKS := 26


var _outcomes: Dictionary = {}
## Where the server's world sits relative to its MultiplayerAPI root. A built-in game has no
## client scene the server may name (a client loads only from the content mount), so its
## client half is placed by the host, and an RPC routes only if it is at the same path.
var _world_path: NodePath = NodePath()


func _ready() -> void:
	DotLog.set_level(
		DotLog.Level.DEBUG if "--verbose" in OS.get_cmdline_user_args()
		else DotLog.Level.ERROR
	)
	_run.call_deferred()


func _run() -> void:
	print("dot-server: a WebSocket player and an ENet player in one match")

	if not ClassDB.class_exists("ENetMultiplayerPeer"):
		print("ERROR: this build has no ENet; the suite needs it.")
		get_tree().quit(1)
		return

	if await _boot():
		var browser := await _test_browser_joins_over_websocket()
		var desktop := await _test_desktop_joins_over_enet()
		if browser != null and desktop != null:
			await _test_one_match(browser, desktop)
			await _test_reliable_crosses(browser, desktop)
			await _test_unreliable_crosses(browser, desktop)
			_test_which_addresses_try_tls_first(desktop)
			var fallback := await _test_blocked_udp_falls_back(browser, desktop)
			if fallback != null:
				await _test_a_leaver_disturbs_nobody(browser, desktop, fallback)

	_teardown()

	print("")
	_check(
		_completed == _entered,
		"every section ran to its last line (%d of %d)" % [_completed, _entered],
		"a section that aborted stops adding checks and the total cannot show it"
	)
	_check(
		_passed + _failed + 1 == CHECKS,
		"and made every check it has (%d of %d)" % [_passed + _failed + 1, CHECKS],
		"a check that never ran is not a check that passed"
	)

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)

	get_tree().quit(1 if _failed > 0 else 0)


# --- 1. The server -----------------------------------------------------------

func _boot() -> bool:
	_section("a dual-stack server boots")

	var config := DotServerConfig.new()
	config.hostname = "Mixed Transports"
	config.port = PORT
	config.max_players = 8
	# The default, written out because it is the point of the suite.
	config.transport_mode = "dual"
	config.a2s_enabled = false
	config.query_enabled = false
	config.hibernate_when_empty = false
	config.startup_config = ""
	config.autoexec_config = ""

	# Its own MultiplayerAPI root, like every host: see docs/transports.md.
	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), server_side.get_path())

	_server = DotServer.new()
	_server.name = "Server"
	_server.config = config
	_server.config_file = ""
	_server.auto_boot = false
	server_side.add_child(_server)

	var booted := await _server.boot()
	if not _check(booted.ok, "it boots", str(booted.error)):
		_done()
		return false

	var game := DotGameDescriptor.new()
	game.game_id = "mixed"
	game.display_name = "Mixed"
	game.version = "1.0.0"
	game.scene = "res://examples/fixtures/mixed_world.tscn"
	_server.games.add_game(game)

	var loaded: DotResult = await _server.games.change_game("mixed")
	_check(loaded.ok and WORLD.instances.has(1), "and loads the relay world", str(loaded.error))
	if WORLD.instances.has(1):
		_world_path = server_side.get_path_to(WORLD.instances[1] as Node)

	_done()
	return true


# --- 2, 3. One of each -------------------------------------------------------

func _test_browser_joins_over_websocket() -> DotClientLink:
	_section("a browser-style player joins over WebSocket")

	# A browser build never tries UDP (DotPlatform.is_web()); on a native build "ws" is the
	# same path, and it is the opt-out a desktop player gets with `--transport ws`.
	var link := _new_link("Browser", func(l: DotClientLink) -> void: l.transport_preference = "ws")
	var refused := await _join(link)
	if not _check(refused == "", "it joins", refused):
		_done()
		return null

	var peer := _peer_of("Browser")
	_check(
		link.transport_used == "websocket" and _server.peer_transport(peer) == "websocket",
		"over WebSocket, on both ends (client %s, server %s)" % [link.transport_used, _server.peer_transport(peer)]
	)
	_done()
	return link


func _test_desktop_joins_over_enet() -> DotClientLink:
	_section("a desktop player joins over ENet, to the same server")

	var link := _new_link("Desktop", Callable())
	var refused := await _join(link)
	if not _check(refused == "", "it joins", refused):
		_done()
		return null

	var peer := _peer_of("Desktop")
	_check(
		link.transport_used == "enet" and _server.peer_transport(peer) == "enet",
		"over ENet, on both ends (client %s, server %s)" % [link.transport_used, _server.peer_transport(peer)]
	)
	_done()
	return link


# --- 4. One match ------------------------------------------------------------

func _test_one_match(browser: DotClientLink, desktop: DotClientLink) -> void:
	_section("the server holds one match with both of them in it")

	_check(_server.playing_sessions().size() == 2, "two playing sessions (%d)" % _server.playing_sessions().size())
	_check(
		_world_of(browser) != null and _world_of(desktop) != null,
		"each client loaded the game's world"
	)

	var boards := {"Browser": {}, "Desktop": {}}
	for link: DotClientLink in [browser, desktop]:
		var label := link.player_name
		link.scoreboard_received.connect(func(snap: Dictionary) -> void: boards[label] = snap)
		var _asked := link.request_scoreboard()

	var both := await _until(func() -> bool:
		return _names_on(boards["Browser"]) == ["Browser", "Desktop"] \
			and _names_on(boards["Desktop"]) == ["Browser", "Desktop"], 5.0)
	_check(both, "and each one's scoreboard lists both players (%s / %s)" % [
		_names_on(boards["Browser"]), _names_on(boards["Desktop"])])
	_done()


# --- 5. Reliable -------------------------------------------------------------

func _test_reliable_crosses(browser: DotClientLink, desktop: DotClientLink) -> void:
	_section("a reliable game RPC crosses from one transport to the other")

	var b := _world_of(browser)
	var d := _world_of(desktop)
	b.say.rpc_id(1, "hello from the browser")
	d.say.rpc_id(1, "hello from the desktop")

	var b_peer := _peer_of("Browser")
	var d_peer := _peer_of("Desktop")
	_check(
		await _until(func() -> bool: return d.heard.has([b_peer, "hello from the browser"]), 3.0),
		"WebSocket to ENet", str(d.heard)
	)
	_check(
		await _until(func() -> bool: return b.heard.has([d_peer, "hello from the desktop"]), 3.0),
		"ENet to WebSocket", str(b.heard)
	)

	# Order matters for reliable traffic: a burst arrives as it was sent, across the seam.
	for i in 50:
		d.say.rpc_id(1, "line %d" % i)
	var arrived := await _until(func() -> bool: return _lines_from(b, d_peer).size() >= 51, 3.0)
	var lines := _lines_from(b, d_peer)
	var in_order := lines.size() >= 51
	for i in 50:
		if not in_order:
			break
		in_order = lines[i + 1] == "line %d" % i
	_check(arrived and in_order, "fifty reliable lines arrive whole and in order (%d)" % lines.size())
	_done()


# --- 6. Unreliable -----------------------------------------------------------

func _test_unreliable_crosses(browser: DotClientLink, desktop: DotClientLink) -> void:
	_section("an unreliable stream crosses both ways")

	var b := _world_of(browser)
	var d := _world_of(desktop)
	var b_peer := _peer_of("Browser")
	var d_peer := _peer_of("Desktop")

	# One a frame, as a game sends its inputs, rather than a burst a socket would coalesce.
	for i in 60:
		b.move.rpc_id(1, i)
		d.move.rpc_id(1, i)
		await get_tree().process_frame
	await _settle(0.5)

	var at_desktop: Array = d.moves.get(b_peer, [])
	var at_browser: Array = b.moves.get(d_peer, [])
	# Loopback loses nothing in practice; the margin is for a loaded CI box, not the network.
	_check(at_desktop.size() >= 54, "WebSocket to ENet: %d of 60" % at_desktop.size())
	_check(at_browser.size() >= 54, "ENet to WebSocket: %d of 60" % at_browser.size())
	_done()


# --- 6b. Which WebSocket joins try TLS first ------------------------------------

## A listed server's game port is a TLS port (browsers reach it from an HTTPS page), so a
## native WebSocket join to a public bare host:port tries wss:// first; anything local, and
## anything that names its scheme, does not. Real TLS is proven by hand against nginx (see
## docs/transports.md); this pins the rule that picks it.
func _test_which_addresses_try_tls_first(link: DotClientLink) -> void:
	_section("a native WebSocket join tries TLS first only at a public bare host:port")

	var tls := ["play.example.com:6064", "fcdn.example.com:443", "203.0.113.9:6000"]
	var plain := ["127.0.0.1:6064", "localhost:6064", "10.0.0.5:6064", "192.168.1.20:6064",
		"172.20.0.2:6064", "[::1]:6064", "box.local:6064", "ws://play.example.com:6064",
		"wss://play.example.com:6064", "play.example.com"]
	var wrong: Array[String] = []
	for a: String in tls:
		if not link._tls_first(a):
			wrong.append(a)
	_check(wrong.is_empty(), "public hosts and addresses try wss:// first", str(wrong))
	wrong.clear()
	for a: String in plain:
		if link._tls_first(a):
			wrong.append(a)
	_check(wrong.is_empty(), "local, private, named-scheme and portless ones do not", str(wrong))
	_done()


# --- 7. A desktop player whose UDP is blocked --------------------------------

func _test_blocked_udp_falls_back(browser: DotClientLink, desktop: DotClientLink) -> DotClientLink:
	_section("a desktop player whose UDP gets no answer falls back to WebSocket and plays")

	# `udp_address` is what the shell's `--udp` sets from the server's advertised enet_port;
	# pointing it at a port nobody answers on is a firewall that drops UDP.
	var link := _new_link("Firewalled", func(l: DotClientLink) -> void:
		l.udp_address = "127.0.0.1:%d" % DEAD_UDP_PORT)
	var started := Time.get_ticks_msec()
	var refused := await _join(link)
	var took := (Time.get_ticks_msec() - started) / 1000.0
	if not _check(refused == "", "it joins", refused):
		_done()
		return null

	_check(
		link.transport_used == "websocket" and _server.peer_transport(_peer_of("Firewalled")) == "websocket",
		"over WebSocket (%s)" % link.transport_used
	)
	# The UDP attempt is capped by udp_connect_timeout_sec; the rest of the join is fast.
	_check(
		took < link.udp_connect_timeout_sec + 4.0,
		"after waiting about udp_connect_timeout_sec for UDP, no longer (%.1f s)" % took
	)

	var f := _world_of(link)
	var f_peer := _peer_of("Firewalled")
	_world_of(desktop).say.rpc_id(1, "can you hear me")
	f.say.rpc_id(1, "loud and clear")
	_check(
		await _until(func() -> bool: return f.heard.has([_peer_of("Desktop"), "can you hear me"]), 3.0),
		"it hears the ENet player"
	)
	_check(
		await _until(func() -> bool:
			return _world_of(desktop).heard.has([f_peer, "loud and clear"]) \
				and _world_of(browser).heard.has([f_peer, "loud and clear"]), 3.0),
		"and both others hear it"
	)
	_done()
	return link


# --- 8. Leaving ---------------------------------------------------------------

func _test_a_leaver_disturbs_nobody(browser: DotClientLink, desktop: DotClientLink, fallback: DotClientLink) -> void:
	_section("the ENet player leaving disturbs nobody else")

	var d_peer := _peer_of("Desktop")
	await _drop_link(desktop)
	_check(
		await _until(func() -> bool: return _peer_of("Desktop") == 0, 5.0),
		"the server sees it leave (peer %d)" % d_peer
	)
	_check(
		_server.playing_sessions().size() == 2 and browser.is_connected_to_server() and fallback.is_connected_to_server(),
		"and the other two are still playing (%d)" % _server.playing_sessions().size()
	)

	var b := _world_of(browser)
	_world_of(fallback).say.rpc_id(1, "still here")
	_check(
		await _until(func() -> bool: return b.heard.has([_peer_of("Firewalled"), "still here"]), 3.0),
		"and still hear each other"
	)
	_done()


# --- Helpers -------------------------------------------------------------------

func _new_link(label: String, configure: Callable) -> DotClientLink:
	var root := Node.new()
	root.name = label
	add_child(root)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), root.get_path())

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = label
	root.add_child(link)
	# On spawn, not game_changed: the link retires what the last game left under it during
	# the swap, and a world placed before that would be retired with it.
	link.spawned.connect(func() -> void: _place_world(root))
	if configure.is_valid():
		configure.call(link)

	_links[label] = link
	# Through an Array: a lambda captures locals by value (docs/gdscript-hazards.md).
	_outcomes[label] = [false, ""]
	var outcome: Array = _outcomes[label]
	link.spawned.connect(func() -> void: outcome[0] = true)
	link.disconnected.connect(func(reason: String) -> void: outcome[1] = reason)
	return link


## "" when the link spawned and the server agrees; the reason when not.
func _join(link: DotClientLink) -> String:
	var outcome: Array = _outcomes[link.player_name]
	var connecting: DotResult = await link.connect_to_server("127.0.0.1:%d" % PORT)
	if not connecting.ok:
		return "could not connect: %s" % str(connecting.error)
	if not await _until(func() -> bool: return outcome[0] or outcome[1] != "", 10.0):
		return "timed out in %s" % DotClientLink.phase_name(link.phase)
	if outcome[1] != "":
		return str(outcome[1])
	var label := link.player_name
	if not await _until(func() -> bool: return _playing(label) and _world_of(link) != null, 3.0):
		return "the client spawned but the server or the world never agreed"
	return ""


## What a host does for a built-in game: put the client half where the server's is.
func _place_world(root: Node) -> void:
	if _world_path.is_empty() or root.has_node(_world_path):
		return
	var parent := root
	for i in _world_path.get_name_count() - 1:
		var step := _world_path.get_name(i)
		if not parent.has_node(NodePath(step)):
			var made := Node.new()
			made.name = step
			parent.add_child(made)
		parent = parent.get_node(NodePath(step))
	var world: Node = (load("res://examples/fixtures/mixed_world.tscn") as PackedScene).instantiate()
	world.name = _world_path.get_name(_world_path.get_name_count() - 1)
	parent.add_child(world)


func _playing(label: String) -> bool:
	for session in _server.playing_sessions():
		if session.display_name == label:
			return true
	return false


func _peer_of(label: String) -> int:
	for session in _server.sessions():
		if session.display_name == label:
			return session.peer_id
	return 0


## The relay world this link's client loaded, found by the unique id of its MultiplayerAPI.
func _world_of(link: DotClientLink) -> Node:
	if not is_instance_valid(link) or not link.is_inside_tree():
		return null
	return WORLD.instances.get(link.multiplayer.get_unique_id())


func _lines_from(world: Node, peer: int) -> Array:
	var out := []
	for entry: Array in world.heard:
		if int(entry[0]) == peer:
			out.append(entry[1])
	return out


func _names_on(snap: Dictionary) -> Array:
	var names := []
	for row: Dictionary in snap.get("players", []):
		names.append(str(row.get("name", "")))
	names.sort()
	return names


func _drop_link(link: DotClientLink) -> void:
	link.disconnect_from_server()
	var root := link.get_parent()
	if root != null:
		root.queue_free()
	await get_tree().process_frame


func _teardown() -> void:
	for label in _links:
		var l: Variant = _links[label]
		if is_instance_valid(l):
			(l as DotClientLink).disconnect_from_server()
	if _server != null:
		_server.shutdown("test over")
