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

## What this command says about being typed in chat (`!kick`, `/map`).
##
## [b]Three states, and the middle one is the default.[/b] [code]ALLOWED[/code] and
## [code]REFUSED[/code] are the command's own decision and no server setting overrules
## either; [code]DEFAULT[/code] defers to [member DotConsole.chat_commands_open], which
## ships on.
##
## It was a plain bool defaulting to false, and every command opted in. That read as a
## security boundary and was not one: the thing that decides whether a person may kick
## somebody is [member permission], checked on the same line for every source. What the
## old default actually did was make a prefix a player had already typed correctly answer
## "'map' cannot be run from chat" to an operator holding the flag for it -- a refusal
## with no attacker on the other end of it.
enum ChatPolicy {
	## Follow the server: [member DotConsole.chat_commands_open].
	DEFAULT,
	## Always reachable from chat, whatever the server's default is.
	ALLOWED,
	## Never reachable from chat, whatever the server's default is.
	REFUSED,
}

var chat_policy: ChatPolicy = ChatPolicy.DEFAULT

## Whether this command has not refused chat outright.
##
## [b]Not the whole answer[/b] -- a [code]DEFAULT[/code] command on a server with
## [member DotConsole.chat_commands_open] off is reachable by nobody, and this still reads
## true. Kept because it is what a suite asks and what the relay's published table carries;
## the executable answer is [method allows_chat], which is what the console calls.
##
## Assigning is still the old opt-in: true marks [code]ALLOWED[/code], false
## [code]REFUSED[/code]. Both are explicit, which is what an assignment meant.
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


## Marks this reachable from chat whatever the server's default is.
##
## Still worth writing on a command a game means to be typed -- `!rtv`, `!top` -- because
## it survives an operator turning the server-wide default off, which is the deployment
## that setting exists for.
func with_chat(allowed: bool = true) -> DotConCommand:
	chat_policy = ChatPolicy.ALLOWED if allowed else ChatPolicy.REFUSED
	return self


## Marks this unreachable from chat whatever the server's default is.
##
## For the handful where the answer is about the operation rather than about who is
## asking: `quit` on a listen server, a map change on a records server mid-run. Everything
## else should carry a [member permission] and let the flag decide.
func no_chat() -> DotConCommand:
	chat_policy = ChatPolicy.REFUSED
	return self


## Whether a CHAT-sourced line may reach this, given the server's default.
##
## The console asks this and nothing else. Says nothing about permission, which is checked
## straight after for every source alike.
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
