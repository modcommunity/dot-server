@tool
class_name DotModule
extends Node

## Base class for a server plugin.
##
## A module is a [Node] with a lifecycle the host manages. Subclass it, override
## [method _module_load], register whatever you need, and the host guarantees
## [method _module_unload] runs before you are freed.
##
## [b]Why the registration helpers exist.[/b] A module that registers a console
## command and is then unloaded leaves a command whose handler points at a freed
## object — the console calls it and the server crashes. Every helper here records
## what it registered so [DotModuleHost] can undo it. Register through them, not
## directly, and unloading is safe by construction.
##
## [codeblock]
## extends DotModule
##
## func _module_name() -> String: return "welcome"
##
## func _module_load() -> DotResult:
##     add_command("welcome", _cmd_welcome, "Greet a player", DotAdminFlags.CHAT)
##     hook_post("client_spawn", _on_spawn)
##     return DotResult.success(null)
##
## func _on_spawn(e: DotEvent) -> void:
##     server.broadcast_message("Welcome, %s!" % e.get_string("name"))
## [/codeblock]

## The server this module is loaded into. Set by the host before [method _module_load].
var server: DotServer = null

var console: DotConsole = null
var events: DotEventBus = null

## Whether [method _module_load] succeeded.
var loaded: bool = false

var _registered_commands: PackedStringArray = PackedStringArray()
var _registered_cvars: PackedStringArray = PackedStringArray()
var _hooks: Array = []
var _query_providers: Array[Object] = []


# --- Subclass interface ----------------------------------------------------

## Identifier used by `module_load` / `module_unload`. Must be unique.
func _module_name() -> String:
	return name


func _module_version() -> String:
	return "1.0.0"


func _module_description() -> String:
	return ""


func _module_author() -> String:
	return ""


## Sets everything up. Return a failure to refuse to load.
##
## A module that cannot work — a missing dependency, a bad config — must fail here
## rather than load broken. The host reports it and unloads.
func _module_load() -> DotResult:
	return DotResult.success(null)


## Tears down anything the helpers below did not cover.
##
## Commands, cvars and hooks registered through the helpers are undone
## automatically. Override for anything else: timers, files, sockets.
func _module_unload() -> void:
	pass


## Called after the game changes, so a module can re-attach to a new scene.
func _module_game_changed(_content_key: String) -> void:
	pass


# --- Registration helpers -------------------------------------------------

## Registers a console command that is removed when this module unloads.
func add_command(
	command_name: String,
	handler: Callable,
	description: String = "",
	permission: String = ""
) -> DotConCommand:
	if console == null:
		push_error("DotModule.add_command() before the module was set up.")
		return null

	var cmd := console.command(command_name, handler, description, permission)
	_registered_commands.append(command_name)
	return cmd


## Registers a cvar that is removed when this module unloads.
func add_cvar(
	cvar_name: String,
	default_value: String,
	description: String = "",
	flags: int = 0
) -> DotConVar:
	if console == null:
		push_error("DotModule.add_cvar() before the module was set up.")
		return null

	var c := console.cvar(cvar_name, default_value, description, flags)
	_registered_cvars.append(cvar_name)
	return c


## Hooks an event, unhooked when this module unloads.
func hook_pre(event_name: String, callback: Callable) -> void:
	if events == null:
		push_error("DotModule.hook_pre() before the module was set up.")
		return
	events.hook_pre(event_name, callback)
	_hooks.append([event_name, callback])


func hook_post(event_name: String, callback: Callable) -> void:
	if events == null:
		push_error("DotModule.hook_post() before the module was set up.")
		return
	events.hook_post(event_name, callback)
	_hooks.append([event_name, callback])


## Registers a query provider, removed when this module unloads.
##
## The same reasoning as every other helper, and a sharper case for it: a provider
## left behind by an unloaded module is called on the next query, from a socket
## anyone can reach, with [code]self[/code] pointing at a freed object.
func add_query_provider(provider: Object) -> DotResult:
	if server == null or server.query_source == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"No query source: neither query protocol is enabled on this server."
		)

	var added := server.query_source.add_provider(provider)
	if added.ok:
		_query_providers.append(provider)
	return added


## Undoes every helper registration. Called by the host; not for subclasses.
func _cleanup_registrations() -> void:
	for command_name in _registered_commands:
		console.unregister_command(command_name)
	_registered_commands.clear()

	for cvar_name in _registered_cvars:
		console.unregister_cvar(cvar_name)
	_registered_cvars.clear()

	for entry in _hooks:
		events.unhook(str(entry[0]), entry[1])
	_hooks.clear()

	if server != null and server.query_source != null:
		for provider in _query_providers:
			server.query_source.remove_provider(provider)
	_query_providers.clear()


# --- Convenience ----------------------------------------------------------

func log_info(message: String, fields: Dictionary = {}) -> void:
	DotLog.info("mod." + _module_name(), message, fields)


func log_warn(message: String, fields: Dictionary = {}) -> void:
	DotLog.warn("mod." + _module_name(), message, fields)


func describe() -> Dictionary:
	return {
		"name": _module_name(),
		"version": _module_version(),
		"author": _module_author(),
		"description": _module_description(),
		"loaded": loaded,
		"commands": Array(_registered_commands),
		"cvars": Array(_registered_cvars),
		"hooks": _hooks.size(),
		"query_providers": _query_providers.size(),
	}
