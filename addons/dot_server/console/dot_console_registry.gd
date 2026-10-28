@tool
extends Node

## Registry half of [DotConsole]: cvars, commands, sources, typed accessors, the suggestion helper.

const CHANNEL := "console"

## Registry name.
const SERVICE := &"dot_console"

## Emitted for every command executed, after permission checks pass.
signal command_executed(ctx: DotCmdContext)

## Emitted when a command is refused. For audit logging and abuse detection.
signal command_refused(ctx: DotCmdContext, reason: String)

## Emitted whenever any cvar changes, so replication and notification can hook in
## without connecting to each cvar.
signal cvar_changed(cvar: DotConVar, old_value: String)

## Emitted when a cvar is registered, so a replicated one a module adds while players are
## already in reaches them without waiting for its first change.
signal cvar_registered(cvar: DotConVar)

@export_group("Behaviour")

## Config files are searched here, in order.
## [code]res://[/code] first so a game can ship defaults, then [code]user://[/code] so an operator's edits win.
@export var config_search_paths: PackedStringArray = PackedStringArray([
	"user://cfg", "res://cfg", "res://addons/dot_server/cfg",
])

## Commands executed per frame from the buffer. 0 means all of them.
## Nonzero bounds a looping config (`alias` plus `exec`); a boot that hangs silently is harder to diagnose than a slow buffer.
@export_range(0, 1000, 1) var commands_per_frame: int = 64

## Maximum depth of nested `exec` calls.
##
## The direct guard against a config that execs itself.
@export_range(1, 32, 1) var max_exec_depth: int = 8

## Whether a chat line that opens with a command prefix reaches commands that said nothing either way.
## On: [member DotConCommand.permission] decides who may do what on every source; this decides only whether typing is a way in. Off: only [code]with_chat()[/code] commands.
## [method DotConCommand.no_chat] always wins. [DotServer] binds [member chat_commands_cvar] over this.
@export var chat_commands_open: bool = true

## Log every executed command at INFO.
## On for a dedicated server: it is how an operator reconstructs what an admin did, and the evidence for moderation.
@export var log_commands: bool = true

## name -> DotConVar
var _cvars: Dictionary = {}

## name -> DotConCommand
var _commands: Dictionary = {}

## alias -> command string
var _aliases: Dictionary = {}

## Pending command strings.
var _buffer: Array[String] = []

## Frames remaining on a `wait`.
var _wait_frames: int = 0

var _exec_depth: int = 0
var _server_running: bool = false

## Set by [DotServer] so cheat gating can be evaluated without a hard dependency.
var cheats_cvar: DotConVar = null

## `sv_chat_commands`, bound by [DotServer]. Null on a console with no server, which is
## when [member chat_commands_open] answers instead.
var chat_commands_cvar: DotConVar = null




## Registers a cvar. Returns it so definitions can be kept inline.
func register_cvar(cvar: DotConVar) -> DotConVar:
	var key := cvar.name.to_lower()

	if _cvars.has(key):
		DotLog.warn(
			CHANNEL, "cvar registered twice", {"cvar": cvar.name}
		)
		return _cvars[key]

	if _commands.has(key):
		# Those consoles allow a cvar and a command to share a name and resolve it
		# inconsistently. Refusing is better than a console where `exec` sometimes
		# means a variable.
		DotLog.error(
			CHANNEL,
			"a command already uses this name; cvar not registered",
			{"name": cvar.name}
		)
		return cvar

	_cvars[key] = cvar
	cvar.changed.connect(_on_cvar_changed.bind(cvar))
	cvar_registered.emit(cvar)
	return cvar


## Convenience: builds and registers a cvar in one call.
func cvar(
	name: String,
	default_value: String,
	description: String = "",
	flags: int = 0
) -> DotConVar:
	return register_cvar(DotConVar.new(name, default_value, description, flags))


func register_command(command: DotConCommand) -> DotConCommand:
	var key := command.name.to_lower()

	if _commands.has(key):
		DotLog.warn(
			CHANNEL, "command registered twice", {"command": command.name}
		)
		return _commands[key]

	if _cvars.has(key):
		DotLog.error(
			CHANNEL,
			"a cvar already uses this name; command not registered",
			{"name": command.name}
		)
		return command

	_commands[key] = command
	return command


## Convenience: builds and registers a command in one call.
func command(
	name: String,
	handler: Callable,
	description: String = "",
	permission: String = ""
) -> DotConCommand:
	return register_command(
		DotConCommand.new(name, handler, description, permission)
	)


## Registers everything a duck-typed command source claims, as ordinary commands. Not a second dispatch path:
## wrapping each name in a [DotConCommand] keeps permissions, the RCON and chat gates, audit, `cmdlist`, `help`, aliases and completion. Duck-typed because a mandatory addon may not name an optional addon's class (it would fail to parse).
## [param source] needs [code]names()[/code] and [code]execute(line)[/code]; [code]help_for(name)[/code] and [code]complete(partial, limit)[/code] are optional. Returns the names actually registered (collisions are refused), so read it.
func add_source(
	source: Object,
	permission: String = "",
	chat: bool = false
) -> DotResult:
	if source == null or not is_instance_valid(source):
		return DotResult.fail(
			DotError.CODE_INVALID, "A console source cannot be null."
		)

	for required in ["names", "execute"]:
		if not source.has_method(required):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A console source needs a %s() method." % required,
				"got a %s" % source.get_class()
			)

	var claimed: Variant = source.call("names")

	if not (claimed is PackedStringArray or claimed is Array):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A console source's names() must return an array of names."
		)

	var wanted := PackedStringArray(claimed)

	if wanted.is_empty():
		# Not an error. A source that claims nothing is a source whose feature is off,
		# and refusing here would make an optional subsystem fatal to the boot.
		DotLog.debug(
			CHANNEL, "a console source claimed no commands",
			{"source": source.get_class()}
		)
		return DotResult.success(PackedStringArray())

	var has_help: bool = source.has_method("help_for")
	var has_complete: bool = source.has_method("complete")
	var registered := PackedStringArray()

	for raw in wanted:
		var name := String(raw).strip_edges().to_lower()

		if name == "":
			continue

		if has_name(name):
			DotLog.warn(
				CHANNEL,
				"a console source claimed a name that is already taken",
				{"name": name, "source": source.get_class()}
			)
			continue

		var description := ""

		if has_help:
			description = String(source.call("help_for", name))

		if description == "":
			description = "Provided by %s." % source.get_class()

		var cmd := DotConCommand.new(
			name,
			_source_handler(source, name),
			description,
			permission
		)

		if chat:
			cmd.with_chat()

		if has_complete:
			cmd.with_completer(_source_completer(source, name))

		# `!=` rather than `.ok`: register_command returns whatever already held the
		# name on a collision, and has_name() above cannot see a name a source claimed
		# twice in one list.
		if register_command(cmd) == cmd:
			registered.append(name)

	DotLog.debug(
		CHANNEL,
		"console source registered",
		{"source": source.get_class(), "commands": " ".join(Array(registered))}
	)

	return DotResult.success(registered)


## One command's forwarder. Bound per name so the source sees the line it expects.
## The whole line, command word included: every source parses its own first word, so handing only the arguments makes it answer "not a log command".
func _source_handler(source: Object, name: String) -> Callable:
	return func(ctx: DotCmdContext) -> void:
		if not is_instance_valid(source):
			# A source outlives nothing here by design, but a module that shipped one
			# and then unloaded without removing it is a crash otherwise, on the first
			# command after a game change.
			ctx.reply("'%s' is no longer available." % name)
			return

		var line := name

		if ctx.argc() > 0:
			line += " " + ctx.rest()

		var out: Variant = source.call("execute", line)

		if out is DotResult:
			var res := out as DotResult
			if not res.ok:
				ctx.reply_error(res)
				return
			_reply_value(ctx, res.value)
			return

		_reply_value(ctx, out)


## Puts whatever a source returned on the caller's console.
## A source may answer a string, a multi-line string or an array of lines; handling only one makes the rest look like a command that ran silently.
func _reply_value(ctx: DotCmdContext, value: Variant) -> void:
	if value == null:
		return

	if value is PackedStringArray:
		ctx.reply_lines(value)
		return

	if value is Array:
		ctx.reply_lines(PackedStringArray(value))
		return

	var text := str(value)

	if text == "":
		return

	ctx.reply_lines(text.split("\n"))


## A source's own completion, in the shape [member DotConCommand.completer] is called in.
## The source gets the whole line and answers whole lines (dot-console's panel replaces the input box);
## [method complete] reassembles the line from the pieces the completer contract hands over.
func _source_completer(source: Object, name: String) -> Callable:
	return func(partial: String, index: int) -> PackedStringArray:
		if not is_instance_valid(source):
			return PackedStringArray()

		var line := name

		for _i in range(index):
			# The completer is not given the arguments already typed, only the one being completed and its position, so they are
			# stood in for. Sources complete on position and prefix, so this is lossless; one that parsed earlier arguments
			# would need a different contract.
			line += " ?"

		line += " " + partial

		var out: Variant = source.call("complete", line, 24)

		if out is PackedStringArray:
			return out

		if out is Array:
			return PackedStringArray(out)

		return PackedStringArray()


## Unregisters everything a source claims, for a module that is unloading.
## Every name it still claims, not every name it was given, or commands added since would be left pointing at a gone source.
func remove_source(source: Object) -> void:
	if source == null or not is_instance_valid(source):
		return

	if not source.has_method("names"):
		return

	var claimed: Variant = source.call("names")

	if not (claimed is PackedStringArray or claimed is Array):
		return

	for raw in PackedStringArray(claimed):
		unregister_command(String(raw))


## Removes a command. For modules unloading cleanly.
func unregister_command(name: String) -> void:
	_commands.erase(name.to_lower())


func unregister_cvar(name: String) -> void:
	var key := name.to_lower()
	if _cvars.has(key):
		var c: DotConVar = _cvars[key]
		if c.changed.is_connected(_on_cvar_changed):
			c.changed.disconnect(_on_cvar_changed)
		_cvars.erase(key)


## Every [constant DotConVar.FLAG_REPLICATED] cvar's value, by its registered name: what a
## client is told so it predicts under the server's rules. A protected cvar is never in it,
## replicated or not: a value a client is sent is a value every player can read.
func replicated_values() -> Dictionary:
	var out := {}
	for key in _cvars:
		var c: DotConVar = _cvars[key]
		if is_replicated(c):
			out[c.name] = c.get_string()
	return out


## Whether [param c] is one [method replicated_values] would send.
static func is_replicated(c: DotConVar) -> bool:
	return c != null and c.has_flag(DotConVar.FLAG_REPLICATED) and not c.has_flag(DotConVar.FLAG_PROTECTED)


func find_cvar(name: String) -> DotConVar:
	return _cvars.get(name.to_lower())


func find_command(name: String) -> DotConCommand:
	return _commands.get(name.to_lower())


func has_name(name: String) -> bool:
	var key := name.to_lower()
	return _cvars.has(key) or _commands.has(key) or _aliases.has(key)


func cvar_names() -> PackedStringArray:
	var out := PackedStringArray(_cvars.keys())
	out.sort()
	return out


func command_names() -> PackedStringArray:
	var out := PackedStringArray(_commands.keys())
	out.sort()
	return out


## A cvar's value, or [param default] when it is not registered.
##
## Lets a subsystem read a cvar it does not own without null-checking each time.
func get_string(name: String, default: String = "") -> String:
	var c := find_cvar(name)
	return c.get_string() if c != null else default


func get_int(name: String, default: int = 0) -> int:
	var c := find_cvar(name)
	return c.get_int() if c != null else default


func get_float(name: String, default: float = 0.0) -> float:
	var c := find_cvar(name)
	return c.get_float() if c != null else default


func get_bool(name: String, default: bool = false) -> bool:
	var c := find_cvar(name)
	return c.get_bool() if c != null else default


## Sets a cvar with full flag enforcement.
func set_cvar(
	name: String,
	value: String,
	ctx: DotCmdContext = null
) -> DotResult:
	var c := find_cvar(name)
	if c == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown variable '%s'." % name
		)

	return c.set_value(value, _context_dict(c, ctx))


## Builds the context dictionary [method DotConVar.set_value] expects.
func _context_dict(c: DotConVar, ctx: DotCmdContext) -> Dictionary:
	var cheats := cheats_cvar.get_bool() if cheats_cvar != null else false

	# The local console and config files may set cheat cvars regardless of
	# sv_cheats: that is how sv_cheats itself gets turned on, and whoever has the
	# terminal already has the process.
	if ctx != null and ctx.is_trusted():
		cheats = true

	var has_perm := true
	if ctx != null:
		var needed := DotAdminFlags.CHEATS if c.has_flag(DotConVar.FLAG_CHEAT) else DotAdminFlags.CVAR
		has_perm = ctx.has_permission(needed)

	return {
		"cheats_enabled": cheats,
		"server_running": _server_running,
		"has_permission": has_perm,
		"source": ctx.caller_label() if ctx != null else "console",
	}


## Whether a prefixed chat line reaches a command that said nothing either way.
## The cvar wins when present, so `sv_chat_commands 0` takes effect on the next line rather than at restart.
func chat_commands_are_open() -> bool:
	if chat_commands_cvar != null:
		return chat_commands_cvar.get_bool()
	return chat_commands_open


func set_server_running(running: bool) -> void:
	_server_running = running


func _on_cvar_changed(old_value: String, _new_value: String, c: DotConVar) -> void:
	cvar_changed.emit(c, old_value)


## Names close to [param name], for "did you mean".
## Substring match plus an edit-distance-1 check, not full Levenshtein: most typos are one transposition or missing character,
## and this avoids scanning 400 names quadratically.
func suggest(name: String, limit: int = 3) -> PackedStringArray:
	var out := PackedStringArray()
	var target := name.to_lower()

	for candidate in command_names() + cvar_names():
		if candidate.contains(target) or target.contains(candidate):
			out.append(candidate)
		elif _near(target, candidate):
			out.append(candidate)

		if out.size() >= limit:
			break

	return out


## Whether two strings differ by roughly one character.
static func _near(a: String, b: String) -> bool:
	if absi(a.length() - b.length()) > 1:
		return false

	var differences := 0
	var shorter := mini(a.length(), b.length())

	for i in range(shorter):
		if a[i] != b[i]:
			differences += 1
			if differences > 1:
				return false

	return true
