@tool
extends "res://addons/dot_server/console/dot_console_registry.gd"

## Execution half of [DotConsole]: statements, the command buffer, aliases, tokenizing.


## Parses and runs a command line immediately.
## Semicolons separate commands; quotes group arguments containing spaces.
func execute(line: String, ctx_template: DotCmdContext = null) -> DotResult:
	var last := DotResult.success(null)

	for part in split_statements(line):
		last = _execute_one(part, ctx_template)

	return last


## Queues a command line to run from the buffer.
## For effects that must not happen inside another command's handler: `changelevel` from a vote callback would free the emitter mid-signal.
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


## Every command a caller arriving on [param source] could reach, as plain documents, for [code]DotChatRelay.commands_fn[/code].
## The source gate is the one [method _run_command] applies (RCON reaches all, CHAT what chat takes, per [member chat_commands_open] and [method DotConCommand.no_chat]),
## so a menu built from a flag alone would hide or wrongly offer commands. It answers no permission question: the admin manager decides per line. Hidden commands are left out.
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
		# Two refusals, because they are two conversations: "not this command, ever" and "not this server, by a setting";
		# the second tells the operator there is a cvar to look for.
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


func set_alias(name: String, expansion: String) -> void:
	_aliases[name.to_lower()] = expansion


func remove_alias(name: String) -> void:
	_aliases.erase(name.to_lower())


func aliases() -> Dictionary:
	return _aliases


## The command name at the start of a statement, without its arguments.
static func _first_token(statement: String) -> String:
	var trimmed := statement.strip_edges()
	var space := trimmed.find(" ")

	return trimmed if space < 0 else trimmed.substr(0, space)


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
