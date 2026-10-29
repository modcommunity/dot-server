class_name DotConCommand
extends RefCounted

## A console command carrying its own permission and argument bounds, so the console refuses
## before invoking. Commands are reachable from the terminal, RCON, chat and `.cfg` files at
## very different trust; a handler checking for itself would sometimes forget.

## The invocation context: who is asking and where to reply (so `kick` can respect immunity
## and output reaches the RCON session that asked). A [DotCmdContext], not a bare array.

## Callable signature: [code]func(ctx: DotCmdContext) -> void[/code].
var handler: Callable

var name: String
var description: String

## Permission flag required to run this; empty means anybody (`status`, `help`). Anything
## that changes state should have one. See [DotAdminFlags].
var permission: String = ""

## Usage line shown by `help`, e.g. [code]"<player> [reason][/code]".
var usage: String = ""

## Minimum and maximum argument counts. -1 for no maximum.
var min_args: int = 0
var max_args: int = -1

## Whether a client may run this over RCON at all. Separate from [member permission]: some
## commands only make sense locally (`quit` on a listen server closes the host's game).
var rcon_allowed: bool = true

## What this command says about chat (`!kick`, `/map`): [code]ALLOWED[/code] and
## [code]REFUSED[/code] are its own decision; [code]DEFAULT[/code] (the default) defers to
## [member DotConsole.chat_commands_open]. Not a security boundary; [member permission] is.
enum ChatPolicy {
	## Follow the server: [member DotConsole.chat_commands_open].
	DEFAULT,
	## Always reachable from chat, whatever the server's default is.
	ALLOWED,
	## Never reachable from chat, whatever the server's default is.
	REFUSED,
}

var chat_policy: ChatPolicy = ChatPolicy.DEFAULT

## Whether this command has not refused chat outright. Not the whole answer: a DEFAULT command
## with [member DotConsole.chat_commands_open] off reads true yet is unreachable; the console
## calls [method allows_chat]. Assigning true marks ALLOWED, false REFUSED.
var chat_allowed: bool:
	get:
		return chat_policy != ChatPolicy.REFUSED
	set(value):
		chat_policy = ChatPolicy.ALLOWED if value else ChatPolicy.REFUSED

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


## Marks this reachable from chat whatever the server default is, so it survives an operator
## turning the default off (`!rtv`, `!top`).
func with_chat(allowed: bool = true) -> DotConCommand:
	chat_policy = ChatPolicy.ALLOWED if allowed else ChatPolicy.REFUSED
	return self


## Marks this unreachable from chat whatever the server default is, for operations rather
## than callers (`quit` on a listen server). Everything else relies on [member permission].
func no_chat() -> DotConCommand:
	chat_policy = ChatPolicy.REFUSED
	return self


## Whether a CHAT-sourced line may reach this, given the server's default. Permission is
## checked afterwards for every source alike.
func allows_chat(open_by_default: bool) -> bool:
	match chat_policy:
		ChatPolicy.ALLOWED:
			return true
		ChatPolicy.REFUSED:
			return false
		_:
			return open_by_default


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
	match chat_policy:
		ChatPolicy.ALLOWED:
			out.append("  can be run from chat")
		ChatPolicy.REFUSED:
			out.append("  cannot be run from chat")

	return out


func _to_string() -> String:
	return "DotConCommand(%s)" % name
