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
##
## [code]res://[/code] first so a game can ship defaults, then [code]user://[/code]
## so an operator's edits win — which is the order that makes shipping a default
## [code]server.cfg[/code] useful rather than obstructive.
@export var config_search_paths: PackedStringArray = PackedStringArray([
	"user://cfg", "res://cfg", "res://addons/dot_server/cfg",
])

## Commands executed per frame from the buffer. 0 means all of them.
##
## Nonzero bounds the damage of a config file that loops: `alias` plus `exec` can
## express one, and a server that hangs at boot with no output is much harder to
## diagnose than one that logs a slow buffer.
@export_range(0, 1000, 1) var commands_per_frame: int = 64

## Maximum depth of nested `exec` calls.
##
## The direct guard against a config that execs itself.
@export_range(1, 32, 1) var max_exec_depth: int = 8

## Whether a chat line that opens with a command prefix reaches commands that have
## said nothing either way.
##
## [b]On, and that is a deliberate reversal.[/b] Commands used to opt in one at a time
## and everything else answered "cannot be run from chat" -- to an operator holding the
## flag for it as readily as to a stranger, because the check ran before the permission
## check and did not look at who was asking. The gate that decides what a person may do is
## [member DotConCommand.permission], and it runs on the same line for chat, RCON, the
## terminal and a config file alike. This one decides something narrower: whether typing is
## a way in at all.
##
## Off restores the old behaviour exactly -- only [code]with_chat()[/code] commands are
## reachable by typing -- for a deployment that wants its console reached by console.
## Either way [method DotConCommand.no_chat] still wins for a command whose answer is about
## the operation rather than about who is asking.
##
## [DotServer] binds [member chat_commands_cvar] over this, so an operator can flip it at
## runtime and a server.cfg can set it at boot.
@export var chat_commands_open: bool = true

## Log every executed command at INFO.
##
## On for a dedicated server: the command log is how an operator reconstructs what
## an admin did, and it is the backing evidence for a moderation decision.
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


## Registers everything a duck-typed command source claims, as ordinary commands.
##
## [b]The point is that this is not a second dispatch path.[/b] An addon that ships a
## command object -- dot-log's [code]log[/code], and anything else with the same shape --
## has a whole console's worth of machinery it would otherwise have to do without on a
## dedicated server: permissions, the RCON gate, the chat gate, the audit line, `cmdlist`,
## `help`, aliases and completion. Wrapping each claimed name in a real [DotConCommand]
## means every one of those keeps working and there is exactly one place a command is run.
##
## [b]Duck-typed, and the source's class is named nowhere.[/b] Same reasoning as
## [method DotServer.attach_query_host]: a script mentioning a [code]class_name[/code] the
## project does not have fails to parse and takes every script referencing it down with it,
## so an optional addon may not be named by a mandatory one. The shape is the one
## dot-console's [code]DotConsoleBridge[/code] already duck-types, which is why an addon
## implements it once and reaches a client console and a server console both.
##
## [codeblock]
## # in the host, with dot-log installed:
## server.console.add_source(DotLogCommands.new(router), DotAdminFlags.GENERIC)
## [/codeblock]
##
## [param source] must have [code]names()[/code] and [code]execute(line)[/code].
## [code]help_for(name)[/code] and [code]complete(partial, limit)[/code] are used when
## present and skipped when not.
##
## Returns the names actually registered, which is not always every name claimed: one that
## collides with an existing command or cvar is refused by [method register_command] and
## left to whoever had it. Read the returned array rather than assuming.
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
##
## [b]The whole line, command word included.[/b] Every source of this shape parses its own
## first word -- dot-log's refuses a line that does not begin with `log` -- so handing it
## only the arguments would make every one of them answer "not a log command".
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
##
## A source is entitled to answer with a string, a string with newlines in it, or an array
## of lines, and a console that only understood one of the three would make two thirds of
## them look like a command that ran and said nothing.
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
##
## The source is handed the whole line it would be asked to execute and answers with whole
## lines, which is the convention everywhere in this family -- dot-console's panel replaces
## the input box with the candidate it picked. [method complete] puts the line back
## together from the pieces the completer contract hands over.
func _source_completer(source: Object, name: String) -> Callable:
	return func(partial: String, index: int) -> PackedStringArray:
		if not is_instance_valid(source):
			return PackedStringArray()

		var line := name

		for _i in range(index):
			# The arguments already typed are not passed to a completer -- only the one
			# being completed and its position -- so they are stood in for. Every source
			# of this shape completes on the POSITION and the prefix, which is what makes
			# that lossless here; one that parsed the earlier arguments would need the
			# whole line and would be asking for a different contract.
			line += " ?"

		line += " " + partial

		var out: Variant = source.call("complete", line, 24)

		if out is PackedStringArray:
			return out

		if out is Array:
			return PackedStringArray(out)

		return PackedStringArray()


## Unregisters everything a source claims. For a module that shipped one and is unloading.
##
## Every name it still claims, not every name it was given: a source whose claim list has
## grown since is one whose extra commands would otherwise be left pointing at it after it
## is gone.
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


## Whether a prefixed chat line reaches a command that has said nothing either way.
##
## The cvar wins when there is one, so `sv_chat_commands 0` takes effect on the next line
## typed rather than at the next restart.
func chat_commands_are_open() -> bool:
	if chat_commands_cvar != null:
		return chat_commands_cvar.get_bool()
	return chat_commands_open


func set_server_running(running: bool) -> void:
	_server_running = running


func _on_cvar_changed(old_value: String, _new_value: String, c: DotConVar) -> void:
	cvar_changed.emit(c, old_value)


## Names close to [param name], for "did you mean".
##
## Substring match plus a cheap edit-distance-1 check. Not a full Levenshtein: the
## overwhelming majority of console typos are one transposition or one missing
## character, and this catches those without scanning 400 names quadratically.
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
