@tool
class_name DotModuleHost
extends Node

## Loads, unloads and reloads [DotModule]s at runtime.
##
## Server plugins, in the usual sense: a community operator drops a script in a
## directory and gets new commands without rebuilding the game. Modules load from
## [code]res://[/code] or [code]user://[/code], and unloading undoes their console
## registrations and event hooks.
##
## [b]On reloading.[/b] `module_reload` frees and re-instantiates, which works
## because the helpers on [DotModule] track everything a module registered. What it
## cannot do is reclaim a mounted resource pack or undo changes a module made to the
## world — reload is for iterating on a plugin's own logic, not a general undo.

const CHANNEL := "modules"
const SERVICE := &"dot_module_host"

signal module_loaded(module: DotModule)
signal module_unloaded(module_name: String)

## Directories scanned by [method load_all], in order.
@export var search_dirs: PackedStringArray = PackedStringArray([
	"user://modules", "res://modules",
])

## Load everything in [member search_dirs] on setup.
@export var auto_load: bool = true

## Modules that must not be loaded, by name.
##
## Lets an operator keep a broken module on disk while disabling it, which is what
## you want at 3am — the alternative is deleting the file and losing its config.
@export var blocklist: PackedStringArray = PackedStringArray()

var server: DotServer = null

## name -> DotModule
var _modules: Dictionary = {}

## name -> script path, so reload can find the source again.
var _paths: Dictionary = {}


## Wires the host to its server. Called by [DotServer].
func setup(p_server: DotServer) -> void:
	server = p_server
	DotRegistry.register(SERVICE, self)

	if server.games != null:
		server.games.game_loaded.connect(_on_game_changed)

	if auto_load:
		# Not awaited, and it cannot be: `setup` is called from [DotServer]'s boot, which
		# is itself a coroutine, and making this one would mean every caller of `setup`
		# had to be. A module that suspends during a scan-load finishes on a later frame;
		# what matters is that `load_module` itself awaits the module, which is what was
		# missing and what produced "Trying to call an async function without 'await'".
		load_all()


func _exit_tree() -> void:
	unload_all()
	DotRegistry.unregister_instance(SERVICE, self)


# --- Loading ---------------------------------------------------------------

## Loads every [code].gd[/code] in the search directories.
func load_all() -> int:
	var loaded_count := 0

	for dir in search_dirs:
		if not DirAccess.dir_exists_absolute(dir):
			continue

		for rel in DotPaths.list_files_recursive(dir):
			if not rel.ends_with(".gd"):
				continue

			var res: DotResult = await load_module(dir.path_join(rel))
			if res.ok:
				loaded_count += 1

	if loaded_count > 0:
		DotLog.info(CHANNEL, "modules loaded", {"count": loaded_count})

	return loaded_count


## Loads one module from a script path.
func load_module(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		return DotResult.fail(
			DotError.CODE_IO, "Module script not found.", path
		)

	var script := load(path)
	if not (script is GDScript):
		return DotResult.fail(
			DotError.CODE_INVALID, "Not a GDScript file.", path
		)

	var instance: Variant = (script as GDScript).new()

	if not (instance is DotModule):
		# Freed explicitly: a RefCounted would go on its own, but a Node that is
		# never added to the tree leaks until the process ends.
		if instance is Node:
			(instance as Node).queue_free()
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A module script must extend DotModule.",
			path
		)

	var module := instance as DotModule
	var module_name := module._module_name()

	if blocklist.has(module_name):
		module.queue_free()
		DotLog.info(CHANNEL, "module blocked", {"module": module_name})
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "Module is blocklisted.", module_name
		)

	if _modules.has(module_name):
		module.queue_free()
		return DotResult.fail(
			DotError.CODE_STATE,
			"A module named '%s' is already loaded." % module_name
		)

	module.name = "Module_" + module_name
	module.server = server
	module.console = server.console
	module.events = server.events

	add_child(module)

	# [b]Awaited, and it was not.[/b] `_module_load` is allowed to be a coroutine and
	# every non-trivial one is -- an identity layer reaches a content host, a profile
	# store, an avatar store, and an un-awaited GDScript coroutine returns at its first
	# suspension. Godot 4.7 reports that as **"Trying to call an async function without
	# 'await'"**, `result` is then null, and the next line reads `.ok` off it: the module
	# fails to load with a message about async functions, on a server whose only crime is
	# that something it talks to was slow.
	#
	# It hid because it only fires when a load ACTUALLY suspends. Every module in the
	# tree awaited things that happened to finish inside one call -- a cloud client with
	# nothing to fetch, a backbone that is not configured -- so the coroutine ran to
	# completion and returned its value like an ordinary function. The first module whose
	# setup really waited was a test fixture written to wait on purpose.
	#
	# `await` on a value that is not a coroutine passes it straight through, so this is
	# correct for a synchronous module too. Typed explicitly rather than inferred,
	# because `await` yields a Variant and `:=` would quietly widen `result`.
	var result: DotResult = await module._module_load()

	if not result.ok:
		# A module that refused to load must not stay half-attached: its partial
		# registrations would fire into an object that believes it is not running.
		DotLog.error(
			CHANNEL,
			"module refused to load",
			{"module": module_name, "why": result.error.message}
		)
		module._cleanup_registrations()
		module.queue_free()
		return result

	module.loaded = true
	_modules[module_name] = module
	_paths[module_name] = path

	DotLog.info(
		CHANNEL,
		"module loaded",
		{
			"module": module_name,
			"version": module._module_version(),
			# [b]`get`, not `[]`.[/b] `describe()` is a method a module is expected to
			# override -- it is the family's "dump your runtime state" convention -- and
			# indexing an override that did not happen to keep this key throws, inside
			# the logging call, AFTER the module has been registered. What that produced
			# was a load that reported "Invalid access to property or key 'commands'",
			# returned null to its caller, and left the module in `_modules` anyway, so
			# the next attempt said it was already loaded. A log line must not be able to
			# fail the operation it is describing.
			"commands": module.describe().get("commands", 0),
		}
	)

	module_loaded.emit(module)
	return DotResult.success(module)


# --- Unloading -------------------------------------------------------------

func unload_module(module_name: String) -> DotResult:
	if not _modules.has(module_name):
		return DotResult.fail(
			DotError.CODE_INVALID, "No module named '%s'." % module_name
		)

	var module: DotModule = _modules[module_name]

	# The module's own teardown runs first, while its registrations still exist —
	# a module that wants to announce its departure needs its command to work.
	# [b]`_module_unload` must be SYNCHRONOUS, and this is where that is enforced.[/b]
	# Unlike `_module_load`, this one cannot be awaited: `unload_all` runs from
	# `_exit_tree`, where the node is already leaving and there is no frame left to
	# resume a coroutine in -- so awaiting here would make shutdown depend on a
	# suspension that can no longer complete. A module with something to flush on the
	# way out has to have flushed it by the time it returns.
	#
	# Detected rather than assumed: a GDScript coroutine that suspends returns a
	# [Signal] instead of its value, so a module that ignored this is visible right
	# here, by name, instead of leaving half a teardown behind and no message at all.
	# Through `call`, because GDScript refuses to take the return value of a function
	# declared `-> void` -- which is exactly what a module's teardown is declared as, and
	# is also what makes the suspension invisible without this.
	var teardown: Variant = module.call("_module_unload")

	if teardown is Signal:
		push_error(
			"%s._module_unload() suspended. Module teardown must be synchronous: "
			% module_name
			+ "unloading runs during shutdown, where there is no frame to resume in."
		)
	module._cleanup_registrations()

	# Belt and braces: a module that hooked directly rather than through the
	# helpers would otherwise leave hooks pointing at a freed object.
	if server.events != null:
		server.events.unhook_all(module)

	_modules.erase(module_name)
	_paths.erase(module_name)

	module.queue_free()

	DotLog.info(CHANNEL, "module unloaded", {"module": module_name})
	module_unloaded.emit(module_name)

	return DotResult.success(module_name)


func unload_all() -> int:
	var names := loaded_names()
	for module_name in names:
		unload_module(module_name)
	return names.size()


## Unloads and loads a module again from the same path.
func reload_module(module_name: String) -> DotResult:
	if not _paths.has(module_name):
		return DotResult.fail(
			DotError.CODE_INVALID, "No module named '%s'." % module_name
		)

	var path := str(_paths[module_name])

	var unloaded := unload_module(module_name)  # synchronous; see unload_module
	if not unloaded.ok:
		return unloaded

	# The engine caches scripts by path, so a file edited on disk would reload as
	# the old version without this.
	var cached := ResourceLoader.exists(path)
	if cached:
		var script := load(path)
		if script is GDScript:
			(script as GDScript).reload()

	return await load_module(path)


# --- Queries ---------------------------------------------------------------

func get_module(module_name: String) -> DotModule:
	return _modules.get(module_name)


func has_module(module_name: String) -> bool:
	return _modules.has(module_name)


func loaded_names() -> PackedStringArray:
	var out := PackedStringArray(_modules.keys())
	out.sort()
	return out


func count() -> int:
	return _modules.size()


func _on_game_changed(content_key: String) -> void:
	for module_name in _modules:
		(_modules[module_name] as DotModule)._module_game_changed(content_key)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if _modules.is_empty():
		out.append("no modules loaded")
		return out

	for module_name in loaded_names():
		var module: DotModule = _modules[module_name]
		out.append("%-20s %-10s %s" % [
			module_name,
			module._module_version(),
			module._module_description(),
		])

	return out
