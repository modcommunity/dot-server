@tool
class_name DotConsole
extends Node

## The command and variable registry, and the thing that executes them.
##
## Modelled on the console every dedicated server has had for twenty years:
## registered [DotConVar]s and [DotConCommand]s, a
## command buffer that supports [code]wait[/code], aliases, config-file execution,
## and [code]+command[/code] arguments on the command line.
##
## [b]Every path into the server goes through here[/b] — the local terminal, RCON,
## chat triggers, config files, modules — and each arrives with a [DotCmdContext]
## saying who it is. That is what makes one permission check cover all of them
## instead of four checks that can disagree.
##
## Placed as a child of [DotServer], which registers it as
## [code]dot_console[/code] in [DotRegistry].

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


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


# --- Registration ----------------------------------------------------------

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


# --- Convenience accessors -------------------------------------------------

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


# --- Execution -------------------------------------------------------------

## Parses and runs a command line immediately.
##
## Semicolons separate commands, as they always have. Quotes group arguments containing
## spaces.
func execute(line: String, ctx_template: DotCmdContext = null) -> DotResult:
	var last := DotResult.success(null)

	for part in split_statements(line):
		last = _execute_one(part, ctx_template)

	return last


## Queues a command line to run from the buffer.
##
## Use when a command's effect must not happen inside another command's handler —
## `changelevel` from a vote callback, for instance, where tearing down the scene
## tree mid-signal would free the emitter.
func enqueue(line: String) -> void:
	for part in split_statements(line):
		_buffer.append(part)


func _execute_one(statement: String, ctx_template: DotCmdContext) -> DotResult:
	var trimmed := statement.strip_edges()
	if trimmed == "" or trimmed.begins_with("//") or trimmed.begins_with("#"):
		return DotResult.success(null)

	var tokens := tokenize(trimmed)
	if tokens.is_empty():
		return DotResult.success(null)

	var name := tokens[0].to_lower()
	var args := PackedStringArray(Array(tokens).slice(1))

	# Aliases expand before anything else, so an alias may name a cvar or wrap a
	# sequence of commands.
	if _aliases.has(name):
		var expansion := str(_aliases[name])
		if not args.is_empty():
			expansion += " " + " ".join(Array(args))
		return execute(expansion, ctx_template)

	var ctx := _build_context(name, args, ctx_template)

	var cmd := find_command(name)
	if cmd != null:
		return _run_command(cmd, ctx)

	var c := find_cvar(name)
	if c != null:
		return _run_cvar(c, ctx)

	ctx.reply("Unknown command '%s'." % tokens[0])

	# A close match is worth offering: most unknown-command reports are typos, and
	# an operator over RCON cannot press tab.
	var near := suggest(name, 3)
	if not near.is_empty():
		ctx.reply("Did you mean: %s" % ", ".join(Array(near)))

	command_refused.emit(ctx, "unknown command")
	return DotResult.fail(
		DotError.CODE_INVALID, "Unknown command '%s'." % tokens[0]
	)


func _build_context(
	name: String,
	args: PackedStringArray,
	template: DotCmdContext
) -> DotCmdContext:
	if template == null:
		return DotCmdContext.console(name, args)

	# Copy rather than mutate: the caller's template is reused across statements in
	# one line, and overwriting its args would make `a; b` run `b` twice with a's
	# arguments.
	var ctx := DotCmdContext.new()
	ctx.source = template.source
	ctx.command = name
	ctx.args = args
	ctx.identity = template.identity
	ctx.session = template.session
	ctx.permissions = template.permissions
	ctx.immunity = template.immunity
	ctx.reply_sink = template.reply_sink
	ctx.address = template.address
	return ctx


## Every command a caller arriving on [param source] could reach, as plain documents.
##
## Written for [code]DotChatRelay.commands_fn[/code]: a website composer offering a `/`
## menu has to be told what this server accepts, because the table depends on which game is
## loaded and which modules an operator installed, and a list held by the site goes stale
## the first time either changes.
##
## [b]The source gate here is the same one [method _run_command] applies[/b], and that
## matters more than it looks. A relay configured as RCON reaches everything RCON reaches;
## a relay configured as CHAT reaches what this server takes from chat, which with
## [member chat_commands_open] on is everything that has not called
## [method DotConCommand.no_chat] — so a menu built from a per-command flag alone would
## hide an operator's whole toolbox from a deployment that deliberately made them remote
## administrators, and, on a server that closed chat commands, offer a table where every
## entry is refused.
##
## [b]It answers no permission question.[/b] Whether a particular person may run a
## particular command is decided per line, later, by the admin manager — this is what is
## worth OFFERING. Hidden commands are left out, because hidden means "not in the list".
func command_document(
	source: DotCmdContext.Source = DotCmdContext.Source.CHAT
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for name in command_names():
		var cmd: DotConCommand = _commands.get(name)
		if cmd == null or cmd.hidden:
			continue
		if source == DotCmdContext.Source.RCON and not cmd.rcon_allowed:
			continue
		if source == DotCmdContext.Source.CHAT and not cmd.allows_chat(
			chat_commands_are_open()
		):
			continue

		out.append({
			"name": cmd.name,
			"usage": cmd.usage,
			"description": cmd.description,
			# What the READER is being told: "you can type this here". The relay's source
			# is what decided it a few lines above, so a deployment that made its site
			# admins remote administrators gets a menu that says so.
			"chat_allowed": true,
			"permission": cmd.permission,
		})

	return out


func _run_command(cmd: DotConCommand, ctx: DotCmdContext) -> DotResult:
	if ctx.source == DotCmdContext.Source.RCON and not cmd.rcon_allowed:
		ctx.reply("'%s' cannot be run remotely." % cmd.name)
		command_refused.emit(ctx, "not allowed over rcon")
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "Not allowed over RCON."
		)

	if ctx.source == DotCmdContext.Source.CHAT and not cmd.allows_chat(
		chat_commands_are_open()
	):
		# Two refusals, because they are two different conversations. One is "not this
		# command, ever"; the other is "not this server, by a setting" -- and an operator
		# who reads the second knows there is a cvar to look for, where the old single
		# message sent them looking for a `with_chat()` they could not add.
		var why := (
			"'%s' cannot be run from chat." % cmd.name
			if cmd.chat_policy == DotConCommand.ChatPolicy.REFUSED
			else "This server does not take commands from chat."
		)
		ctx.reply(why)
		command_refused.emit(ctx, "not allowed from chat")
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "Not allowed from chat."
		)

	if not ctx.has_permission(cmd.permission):
		ctx.reply("You do not have permission to use '%s'." % cmd.name)
		DotLog.warn(
			CHANNEL,
			"command refused",
			{
				"command": cmd.name,
				"by": ctx.caller_label(),
				"needed": cmd.permission,
			}
		)
		command_refused.emit(ctx, "missing permission " + cmd.permission)
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"Missing permission '%s'." % cmd.permission
		)

	var arg_check := cmd.check_args(ctx.argc())
	if not arg_check.ok:
		ctx.reply(arg_check.error.message)
		ctx.reply("Usage: %s" % cmd.usage_line())
		return arg_check

	if log_commands and ctx.source != DotCmdContext.Source.CONFIG:
		DotLog.info(
			CHANNEL,
			"command",
			{
				"cmd": cmd.name,
				"args": " ".join(Array(ctx.args)),
				"by": ctx.caller_label(),
				"via": ctx.source_name(),
			}
		)

	cmd.handler.call(ctx)
	command_executed.emit(ctx)

	return DotResult.success(null)


## Reads or writes a cvar typed bare at the console.
func _run_cvar(c: DotConVar, ctx: DotCmdContext) -> DotResult:
	if ctx.argc() == 0:
		ctx.reply_lines(c.describe_help())
		return DotResult.success(c.get_string())

	# Everything after the name, so `hostname My Cool Server` works without quotes.
	var value := ctx.rest(0)

	var res := c.set_value(value, _context_dict(c, ctx))

	if not res.ok:
		ctx.reply_error(res)
		command_refused.emit(ctx, res.error.message)
		return res

	if log_commands:
		DotLog.info(
			CHANNEL,
			"cvar set",
			{
				"cvar": c.name,
				"to": c.display_value(),
				"by": ctx.caller_label(),
			}
		)

	command_executed.emit(ctx)
	return res


func _on_cvar_changed(old_value: String, _new_value: String, c: DotConVar) -> void:
	cvar_changed.emit(c, old_value)


# --- Buffer ----------------------------------------------------------------

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if _wait_frames > 0:
		_wait_frames -= 1
		return

	if _buffer.is_empty():
		return

	var budget := commands_per_frame if commands_per_frame > 0 else _buffer.size()
	var ran := 0

	while not _buffer.is_empty() and ran < budget:
		var statement: String = _buffer.pop_front()
		ran += 1

		# `wait` stops this frame's drain and resumes on a later one. Handled here
		# rather than as a command because only the buffer can suspend itself.
		var tokens := tokenize(statement)
		if not tokens.is_empty() and tokens[0].to_lower() == "wait":
			_wait_frames = maxi(1, tokens[1].to_int() if tokens.size() > 1 else 1)
			return

		_execute_one(statement, null)


func pending_commands() -> int:
	return _buffer.size()


func clear_buffer() -> void:
	_buffer.clear()
	_wait_frames = 0


# --- Config files ----------------------------------------------------------

## Executes a config file.
##
## Searched through [member config_search_paths] unless the name is already a
## path. Missing files are not an error when [param required] is false: a server
## that refuses to boot without an optional [code]autoexec.cfg[/code] is a server
## that is annoying to install.
func exec_config(
	name: String,
	ctx: DotCmdContext = null,
	required: bool = false
) -> DotResult:
	if _exec_depth >= max_exec_depth:
		return DotResult.fail(
			DotError.CODE_STATE,
			"Config files are nested too deeply.",
			"depth limit %d — a config probably execs itself" % max_exec_depth
		)

	var path := resolve_config_path(name)

	if path == "":
		if required:
			return DotResult.fail(
				DotError.CODE_IO,
				"Config file '%s' not found." % name,
				"searched: %s" % ", ".join(Array(config_search_paths))
			)
		DotLog.debug(CHANNEL, "no config file", {"name": name})
		return DotResult.success(0)

	var read := DotPaths.read_text(path)
	if not read.ok:
		return read.wrap("Could not read '%s'." % path)

	_exec_depth += 1

	var config_ctx := DotCmdContext.new()
	config_ctx.source = DotCmdContext.Source.CONFIG
	# A config file on disk is as trusted as the terminal — whoever wrote it
	# already had filesystem access to the server.
	config_ctx.permissions = PackedStringArray([DotAdminFlags.ROOT])
	config_ctx.immunity = DotAdminFlags.MAX_IMMUNITY
	config_ctx.address = path
	if ctx != null:
		config_ctx.reply_sink = ctx.reply_sink

	var lines := str(read.value).split("\n")
	var executed := 0

	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed == "" or trimmed.begins_with("//") or trimmed.begins_with("#"):
			continue
		execute(trimmed, config_ctx)
		executed += 1

	_exec_depth -= 1

	DotLog.info(
		CHANNEL, "executed config", {"file": path, "lines": executed}
	)

	return DotResult.success(executed)


## Finds a config file, adding [code].cfg[/code] if it has no extension.
func resolve_config_path(name: String) -> String:
	var filename := name
	if not filename.contains("."):
		filename += ".cfg"

	if filename.contains("://") or filename.begins_with("/"):
		return filename if FileAccess.file_exists(filename) else ""

	var safe := DotPaths.safe_relative(filename)
	if not safe.ok:
		# `exec` is reachable over RCON, so its argument is attacker-controlled on
		# a server whose password has leaked. A traversal here would read
		# arbitrary files and echo them as command errors.
		DotLog.warn(
			CHANNEL, "refused an unsafe config path", {"name": name}
		)
		return ""

	for dir in config_search_paths:
		var candidate := dir.path_join(str(safe.value))
		if FileAccess.file_exists(candidate):
			return candidate

	return ""


## Writes every [constant DotConVar.FLAG_ARCHIVE] cvar to a config file.
func write_config(name: String = "server_saved") -> DotResult:
	var lines := PackedStringArray()
	lines.append("// Written by dot-server. Edits are preserved until the next writeconfig.")
	lines.append("")

	for cvar_name in cvar_names():
		var c: DotConVar = _cvars[cvar_name]
		if not c.has_flag(DotConVar.FLAG_ARCHIVE):
			continue
		# A protected value must not be written into a file that gets copied
		# around, pasted into issues and committed by accident.
		if c.has_flag(DotConVar.FLAG_PROTECTED):
			lines.append("// %s omitted (protected)" % c.name)
			continue
		lines.append("%s \"%s\"" % [c.name, c.get_string()])

	for alias in _aliases:
		lines.append("alias %s \"%s\"" % [alias, _aliases[alias]])

	var filename := name
	if not filename.contains("."):
		filename += ".cfg"

	var target := config_search_paths[0].path_join(filename)
	var written := DotPaths.write_text(target, "\n".join(lines) + "\n")

	if written.ok:
		DotLog.info(CHANNEL, "config written", {"file": target})
		return DotResult.success(target)

	return written


# --- Aliases ---------------------------------------------------------------

func set_alias(name: String, expansion: String) -> void:
	_aliases[name.to_lower()] = expansion


func remove_alias(name: String) -> void:
	_aliases.erase(name.to_lower())


func aliases() -> Dictionary:
	return _aliases


# --- Command line ---------------------------------------------------------

## Runs [code]+command args[/code] arguments, the way a dedicated server does.
##
## [code]godot --headless -- +sv_maxplayers 24 +map dm_arena[/code] — a plus
## introduces a command and everything up to the next plus is its arguments. This
## is what makes a server scriptable from a systemd unit without a config file.
func execute_command_line(only_cvars: bool = false) -> int:
	var statements := command_line_statements()
	var ran := 0

	for statement in statements:
		# Split into two passes, and the reason is `FLAG_STARTUP_ONLY`.
		#
		# A cvar the server cannot re-negotiate once it is up — the tickrate, the
		# port, the transport — is refused after [method set_server_running]. The
		# command line is the most "startup" input there is, so refusing
		# `+sv_tickrate 128` there made the flag mean "settable nowhere but
		# server.cfg", and an operator with the muscle memory of any other server
		# ignored them and said so only in a log line.
		#
		# So the boot runs this twice: once before the listener with `only_cvars`,
		# which lets those through, and once after for everything else — because a
		# `+map` or a `+say` genuinely does need the server to be up first.
		if only_cvars and find_cvar(_first_token(statement)) == null:
			continue

		DotLog.info(CHANNEL, "command line", {"cmd": statement})
		execute(statement)
		ran += 1

	return ran


## The `+command arg` statements on the command line, in order.
##
## Separated from running them so the boot can look at the list twice without
## re-parsing argv, and so a test can assert on what was found.
func command_line_statements() -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())

	var statements := PackedStringArray()
	var current := ""

	for arg in args:
		if arg.begins_with("+"):
			if current != "":
				statements.append(current)
			current = arg.substr(1)
		elif current != "":
			# Re-quote anything containing spaces so tokenize() puts it back
			# together as one argument.
			current += " " + ("\"%s\"" % arg if arg.contains(" ") else arg)

	if current != "":
		statements.append(current)

	return statements


## The command name at the start of a statement, without its arguments.
static func _first_token(statement: String) -> String:
	var trimmed := statement.strip_edges()
	var space := trimmed.find(" ")

	return trimmed if space < 0 else trimmed.substr(0, space)


# --- Parsing --------------------------------------------------------------

## Splits on semicolons, respecting quotes.
##
## [code]say "hello; goodbye"[/code] is one command, not two.
static func split_statements(line: String) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	var in_quotes := false

	for i in range(line.length()):
		var ch := line[i]

		if ch == "\"":
			in_quotes = not in_quotes
			current += ch
		elif ch == ";" and not in_quotes:
			out.append(current)
			current = ""
		else:
			current += ch

	if current.strip_edges() != "":
		out.append(current)

	return out


## Splits a statement into tokens, honouring double quotes.
static func tokenize(statement: String) -> PackedStringArray:
	var out := PackedStringArray()
	var current := ""
	var in_quotes := false
	var has_token := false

	for i in range(statement.length()):
		var ch := statement[i]

		if ch == "\"":
			in_quotes = not in_quotes
			# An empty quoted string is a real argument — `say ""` — so opening a
			# quote marks a token as present even before any characters arrive.
			has_token = true
		elif (ch == " " or ch == "\t") and not in_quotes:
			if has_token:
				out.append(current)
				current = ""
				has_token = false
		else:
			current += ch
			has_token = true

	if has_token:
		out.append(current)

	return out


# --- Completion ------------------------------------------------------------

## Completions for what is in the input box, as whole command lines.
##
## [b]Whole lines, not tokens, and that is the contract the callers already have.[/b]
## dot-console's panel replaces the input box with the candidate it picked, so a candidate
## that was only the argument would delete the command word with it. For a one-word partial
## a name IS the whole line, which is why this reads as a name list until an argument is
## being completed.
##
## [b]Once there is a space, the command's own completer answers.[/b] It used to be that
## nothing did: [member DotConCommand.completer] was set by seven builtins -- `kick`,
## `ban`, `mute`, `gag`, `unban`, and both game commands -- read only by
## [method complete_argument], and [method complete_argument] had no callers anywhere in
## this family. Every one of those completers was correct, reachable and never once run,
## which is why tab on `kick ` offered nothing on a server that knew exactly who was
## connected. The name list still comes back for a bare word, so nothing that completed
## before completes differently.
func complete(partial: String, limit: int = 24) -> PackedStringArray:
	# Leading whitespace is never meaningful and a trailing space always is, so only the
	# left is stripped. `strip_edges()` here would turn "kick " -- completing the first
	# argument -- into "kick", which completes the command that is already typed.
	var line := partial.lstrip(" \t")

	if line.contains(" "):
		return _complete_arguments(line, limit)

	var prefix := line.to_lower()
	var out := PackedStringArray()

	for name in command_names():
		var cmd: DotConCommand = _commands[name]
		if cmd.hidden:
			continue
		if name.begins_with(prefix):
			out.append(name)

	for name in cvar_names():
		var c: DotConVar = _cvars[name]
		if c.has_flag(DotConVar.FLAG_HIDDEN):
			continue
		if name.begins_with(prefix):
			out.append(name)

	for alias in _aliases:
		if str(alias).begins_with(prefix):
			out.append(str(alias))

	out.sort()
	if out.size() > limit:
		out = out.slice(0, limit)

	return out


## Argument completions for a partial line, put back together as whole lines.
##
## The trailing space matters and is the whole of the parsing here: `kick ` is completing
## argument 0 with an empty prefix, and `kick Bo` is completing argument 0 with the prefix
## `Bo`. Getting that backwards offers the second player's name while the first is being
## typed, which reads as the completer being broken rather than off by one.
func _complete_arguments(partial: String, limit: int) -> PackedStringArray:
	var tokens := tokenize(partial)

	if tokens.is_empty():
		return PackedStringArray()

	var name := tokens[0].to_lower()
	var cmd := find_command(name)

	if cmd == null:
		var expanded: Variant = _aliases.get(name)
		if expanded != null:
			# An alias completes as whatever it expands to. Without this, completion is
			# the one place an alias is not the command it stands for.
			var alias_tokens := tokenize(str(expanded))
			if not alias_tokens.is_empty():
				cmd = find_command(alias_tokens[0].to_lower())

	if cmd == null or not cmd.completer.is_valid():
		return PackedStringArray()

	var completing_new := partial.ends_with(" ") or partial.ends_with("\t")
	var index := tokens.size() - 1 if completing_new else tokens.size() - 2
	var prefix := "" if completing_new else tokens[tokens.size() - 1]

	if index < 0:
		return PackedStringArray()

	var raw: Variant = cmd.completer.call(prefix, index)
	var candidates := PackedStringArray()

	if raw is PackedStringArray:
		candidates = raw
	elif raw is Array:
		for item in (raw as Array):
			candidates.append(str(item))
	else:
		return PackedStringArray()

	# The arguments already settled, so a candidate can be put back as a whole line. The
	# same slice either way: `index` is the position being completed, so everything before
	# it is settled whether or not the prefix is an empty token.
	var head := " ".join(Array(tokens.slice(0, index + 1)))
	var out := PackedStringArray()

	for candidate in candidates:
		var text := str(candidate)

		if text == "":
			continue

		# A source that already answered with a whole line -- dot-log's does -- is left
		# alone. Prefixing it again would offer `log log tail`.
		out.append(text if text.to_lower().begins_with(name + " ") else head + " " + text)

		if out.size() >= limit:
			break

	return out


## Completions for one argument, as bare tokens, via the command's own completer.
##
## [method complete] is what a console calls; this is the piece under it, kept public
## because a game with its own input box may want the tokens rather than the lines.
func complete_argument(
	command_name: String,
	partial: String,
	arg_index: int
) -> PackedStringArray:
	var cmd := find_command(command_name)
	if cmd == null or not cmd.completer.is_valid():
		return PackedStringArray()

	var result: Variant = cmd.completer.call(partial, arg_index)
	if result is PackedStringArray:
		return result
	if result is Array:
		var out := PackedStringArray()
		for item in (result as Array):
			out.append(str(item))
		return out

	return PackedStringArray()


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


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"cvars": _cvars.size(),
		"commands": _commands.size(),
		"aliases": _aliases.size(),
		"buffered": _buffer.size(),
	}
