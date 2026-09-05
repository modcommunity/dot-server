class_name DotConCommand
extends RefCounted

## A console command.
##
## Carries its own permission requirement and argument bounds, so the console can
## refuse a command before invoking it. That matters because commands are reachable
## from four places with very different trust — the local terminal, an RCON
## session, a chat trigger, and a [code].cfg[/code] file — and a handler that has
## to check "am I allowed to run" itself is a handler that will sometimes forget.

## The invocation context, so a handler knows who is asking and where to reply.
##
## Passed as a [DotCmdContext] rather than a bare argument array precisely so that
## [code]kick[/code] can refuse to kick someone with higher immunity, and so
## output reaches the RCON session that asked rather than the server's stdout.

## Callable signature: [code]func(ctx: DotCmdContext) -> void[/code].
var handler: Callable

var name: String
var description: String

## Permission flag required to run this. Empty means anybody may.
##
## See [DotAdminFlags]. A command with no flag is genuinely public — `status`,
## `help` — and everything that changes state should have one.
var permission: String = ""

## Usage line shown by `help`, e.g. [code]"<player> [reason][/code]".
var usage: String = ""

## Minimum and maximum argument counts. -1 for no maximum.
var min_args: int = 0
var max_args: int = -1

## Whether a client may run this over RCON at all.
##
## Some commands only make sense locally — `quit` on a listen server would close
## the host's game. Separate from [member permission] because the answer is not
## about who is asking.
var rcon_allowed: bool = true

## Whether this may be triggered from in-game chat (`!kick`, `/map`).
##
## Off by default. Chat is the least authenticated path into the console and the
## easiest to spoof in a log, so commands opt in.
var chat_allowed: bool = false

## Hidden from `help` and completion.
var hidden: bool = false

## Completion provider: [code]func(partial: String, arg_index: int) -> PackedStringArray[/code].
##
## What makes `kick <tab>` list connected players instead of nothing.
var completer: Callable = Callable()


func _init(
	p_name: String,
	p_handler: Callable,
	p_description: String = "",
	p_permission: String = ""
) -> void:
	name = p_name
	handler = p_handler
	description = p_description
	permission = p_permission


func with_usage(p_usage: String) -> DotConCommand:
	usage = p_usage
	return self


func with_args(p_min: int, p_max: int = -1) -> DotConCommand:
	min_args = p_min
	max_args = p_max
	return self


func with_chat(allowed: bool = true) -> DotConCommand:
	chat_allowed = allowed
	return self


func with_rcon(allowed: bool) -> DotConCommand:
	rcon_allowed = allowed
	return self


func with_completer(p_completer: Callable) -> DotConCommand:
	completer = p_completer
	return self


func as_hidden() -> DotConCommand:
	hidden = true
	return self


## Checks argument counts. Called by the console before the handler runs.
func check_args(argc: int) -> DotResult:
	if argc < min_args:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Not enough arguments.",
			usage_line()
		)

	if max_args >= 0 and argc > max_args:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Too many arguments.",
			usage_line()
		)

	return DotResult.success(true)


func usage_line() -> String:
	if usage == "":
		return name
	return "%s %s" % [name, usage]


func describe_line() -> String:
	var s := "%-24s" % name
	if permission != "":
		s += " [%s]" % permission
	if description != "":
		s += " - " + description
	return s


func describe_help() -> PackedStringArray:
	var out := PackedStringArray()
	out.append(usage_line())

	if description != "":
		out.append("  " + description)

	if permission != "":
		out.append("  requires permission: %s" % permission)
	if not rcon_allowed:
		out.append("  cannot be run over RCON")
	if chat_allowed:
		out.append("  can be run from chat")

	return out


func _to_string() -> String:
	return "DotConCommand(%s)" % name
