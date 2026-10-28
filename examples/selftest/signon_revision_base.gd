extends Node

## The signon_revision suite's harness: counters, checks and helpers.

const StandIns := preload("signon_stand_ins.gd")
const Profile := preload("signon_profile.gd")
const PORT := 27717

## How many checks a clean run makes. A section that aborts part-way stops adding checks,
## and the section counter cannot see that when the abort comes after the section
## announced itself — so the total is asserted too.
const CHECKS := 149

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0
var _failures: Array[String] = []

var _server: DotServer = null
var _link: DotClientLink = null
var _client_side: Node = null

# Captured through an Array: a lambda captures locals by value, so a plain flag stays false.
var _spawned := [false]
var _refused := [""]

var _links: Dictionary = {}
var _outcomes: Dictionary = {}
var _playing_before_refusals: int = 0

## A client in a subtree of its own, with its own MultiplayerAPI: one socket per link, as
## one process per client would have. [param configure] edits its envelope before it
## connects -- that is how it stands in for an older or a newer build.
func _new_link(label: String, configure: Callable) -> DotClientLink:
	var root := Node.new()
	root.name = label
	add_child(root)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), root.get_path())

	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = label
	root.add_child(link)

	if configure.is_valid():
		configure.call(link)

	_links[label] = link
	_outcomes[label] = [false, ""]
	var outcome: Array = _outcomes[label]
	link.spawned.connect(func() -> void: outcome[0] = true)
	link.disconnected.connect(func(reason: String) -> void: outcome[1] = reason)
	return link

## Connects and waits for either end of the join. "" when it spawned; the reason when not.
func _join(link: DotClientLink) -> String:
	var outcome: Array = _outcomes[link.player_name]
	_playing_before_refusals = _server.sessions().size()
	var connecting: DotResult = await link.connect_to_server("127.0.0.1:%d" % PORT)
	if not connecting.ok:
		return "could not connect: %s" % str(connecting.error)
	var ended := await _until(func() -> bool: return outcome[0] or outcome[1] != "", 8.0)
	if not ended:
		return "timed out in %s" % DotClientLink.phase_name(link.phase)
	if outcome[0]:
		# The client's `spawned` is not the server's; wait for the server to agree.
		await _until(func() -> bool: return _server.playing_sessions().size() > _playing_before_refusals - 1, 3.0)
		return ""
	return str(outcome[1])

func _peer_of(label: String) -> int:
	for session in _server.sessions():
		if session.display_name == label:
			return session.peer_id
	return 0

func _first_peer() -> int:
	for session in _server.sessions():
		return session.peer_id
	return 0

func _drop_link(link: DotClientLink) -> void:
	if link == null:
		return
	link.disconnect_from_server()
	var root := link.get_parent()
	if root != null:
		root.queue_free()
	await get_tree().process_frame

func _missing_from(these: PackedStringArray, those: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for name in these:
		if not those.has(name):
			out.append(name)
	return out

## Stands in for the dot-cloud client's warm_content.
class FakeCloud extends Node:
	var hang := false

	func warm_content(_tree: SceneTree, _keys: PackedStringArray, _force: bool = false, on_progress: Callable = Callable()) -> RefCounted:
		if on_progress.is_valid():
			on_progress.call(1, 2)
			on_progress.call(2, 2)
		if hang:
			await get_tree().create_timer(3600.0).timeout
		return RefCounted.new()

func _section(title: String) -> void:
	_entered += 1
	print("")
	print(title)

func _done() -> void:
	_completed += 1

func _check(ok: bool, label: String, detail: String = "") -> bool:
	if ok:
		_passed += 1
		print("  ok    %s" % label)
	else:
		_failed += 1
		print("  FAIL  %s%s" % [label, "" if detail == "" else "  -- " + detail])
		_failures.append(label)
	return ok

func _until(predicate: Callable, seconds: float = 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	return false

## Lets [param seconds] pass with the network polled every frame — a wait for something to
## NOT happen, which `_until` cannot express.
func _settle(seconds: float) -> void:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

func _teardown() -> void:
	for label in _links:
		var l: Variant = _links[label]
		if is_instance_valid(l):
			(l as DotClientLink).disconnect_from_server()
	if _link != null:
		_link.disconnect_from_server()
	if _server != null:
		_server.shutdown("test over")
