@tool
class_name DotEventBus
extends Node

## Named game events with pre-hooks that can veto and post-hooks that observe.
## Pre-hooks can cancel, which a Godot signal cannot: a module can block a chat message or a kick
## without the firing code knowing it exists. Example: docs/design-notes.md.

const CHANNEL := "events"
const SERVICE := &"dot_event_bus"

## Emitted after every event, cancelled or not, for logging and relays.
signal event_fired(event: DotEvent)

## Log every fired event at TRACE. Very noisy; for debugging a hook order problem.
@export var trace_events: bool = false

## Events fired per frame before a warning: an event loop would otherwise take the server down unnamed.
@export_range(16, 100000, 16) var max_events_per_frame: int = 4096

## name -> Array[Callable]
var _pre_hooks: Dictionary = {}
var _post_hooks: Dictionary = {}

## Declared event names, for `event_list`.
var _declared: Dictionary = {}

var _fired_this_frame: int = 0
var _warned_about_flood: bool = false
var _total_fired: int = 0


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	DotRegistry.register(SERVICE, self)
	_declare_builtin()


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


func _process(_delta: float) -> void:
	_fired_this_frame = 0


## Events dot-server itself fires. Declared so `event_list` documents them.
func _declare_builtin() -> void:
	declare("server_start", "The server finished booting.")
	declare("server_shutdown", "The server is shutting down.")
	declare("client_connect", "A client's transport connected.")
	declare("client_disconnect", "A client left.")
	declare("client_spawn", "A client finished joining and is in the game.")
	declare("client_kicked", "A client was kicked.")
	declare("player_chat", "A chat message. Cancellable.")
	declare("player_command", "A chat command was recognised. Cancellable.")
	declare("game_changing", "The game is about to change. Cancellable.")
	declare("game_changed", "The game finished loading.")
	declare("vote_started", "A vote began.")
	declare("vote_ended", "A vote finished.")
	declare("admin_action", "An administrative action was taken.")


## Records that an event exists, with a description.
## Optional ([method fire] works for undeclared names), but a declared event shows up in `event_list`.
func declare(name: String, description: String = "") -> void:
	_declared[name] = description


func declared_events() -> PackedStringArray:
	var out := PackedStringArray(_declared.keys())
	out.sort()
	return out



## Adds a hook that runs before the event and may cancel it.
## Hooks run in registration order; a cancel stops the remaining pre-hooks.
func hook_pre(name: String, callback: Callable) -> void:
	if not _pre_hooks.has(name):
		_pre_hooks[name] = []
	(_pre_hooks[name] as Array).append(callback)


## Adds a hook that runs after the event, and cannot cancel it.
##
## For reacting: logging, updating a scoreboard, reporting to the backbone.
func hook_post(name: String, callback: Callable) -> void:
	if not _post_hooks.has(name):
		_post_hooks[name] = []
	(_post_hooks[name] as Array).append(callback)


func unhook(name: String, callback: Callable) -> void:
	if _pre_hooks.has(name):
		(_pre_hooks[name] as Array).erase(callback)
	if _post_hooks.has(name):
		(_post_hooks[name] as Array).erase(callback)


## Removes every hook whose callable is bound to [param owner], so an unloaded module's hooks cannot fire into freed objects.
func unhook_all(owner: Object) -> int:
	var removed := 0

	for table in [_pre_hooks, _post_hooks]:
		for name in table:
			var hooks: Array = table[name]
			for i in range(hooks.size() - 1, -1, -1):
				var hook: Callable = hooks[i]
				if hook.get_object() == owner:
					hooks.remove_at(i)
					removed += 1

	if removed > 0:
		DotLog.debug(
			CHANNEL, "hooks removed", {"count": removed, "owner": owner.get_class()}
		)

	return removed


func hook_count(name: String) -> int:
	var pre: Array = _pre_hooks.get(name, [])
	var post: Array = _post_hooks.get(name, [])
	return pre.size() + post.size()



## Fires an event and returns it, so the caller can check [member DotEvent.cancelled].
##
## Pre-hooks run first and may cancel; post-hooks run only if it was not cancelled.
func fire(name: String, data: Dictionary = {}) -> DotEvent:
	var event := DotEvent.new(name, data)

	_fired_this_frame += 1
	_total_fired += 1

	if _fired_this_frame > max_events_per_frame:
		if not _warned_about_flood:
			_warned_about_flood = true
			DotLog.error(
				CHANNEL,
				"event flood — a hook is probably firing the event it handles",
				{"event": name, "this_frame": _fired_this_frame}
			)
		return event

	if trace_events:
		DotLog.trace(CHANNEL, "fire", {"event": name})

	for hook in (_pre_hooks.get(name, []) as Array):
		if not (hook as Callable).is_valid():
			continue

		(hook as Callable).call(event)

		if event.cancelled:
			DotLog.debug(
				CHANNEL,
				"event cancelled",
				{"event": name, "reason": event.cancel_reason}
			)
			event_fired.emit(event)
			return event

	for hook in (_post_hooks.get(name, []) as Array):
		if (hook as Callable).is_valid():
			(hook as Callable).call(event)

	event_fired.emit(event)
	return event


## Fires an event whose result nobody checks; a cancellable event fired with this is a bug.
func notify(name: String, data: Dictionary = {}) -> void:
	fire(name, data)


func total_fired() -> int:
	return _total_fired


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	for name in declared_events():
		var count := hook_count(name)
		out.append("%-20s %-3s %s" % [
			name,
			str(count) if count > 0 else "-",
			str(_declared[name]),
		])

	# Undeclared events with hooks are worth showing: usually a game's own events,
	# occasionally a typo in a hook name that will never fire.
	for name in _pre_hooks.keys() + _post_hooks.keys():
		if not _declared.has(name):
			out.append("%-20s %-3d (not declared)" % [name, hook_count(name)])

	return out
