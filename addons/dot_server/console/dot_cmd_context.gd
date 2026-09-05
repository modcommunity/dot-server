class_name DotCmdContext
extends RefCounted

## Who ran a command, with what arguments, and where output should go.
##
## The reason commands take a context object rather than an argument array: almost
## every interesting command needs to know the caller. [code]kick[/code] must
## refuse a target with higher immunity, [code]say[/code] must attribute the
## message, and any of them may be answering an RCON socket rather than the
## server's own stdout — so [method reply] has to route somewhere caller-specific.

## Where a command came from. Different origins get different trust.
enum Source {
	## The server's own terminal or startup config. Fully trusted.
	CONSOLE,
	## A `.cfg` file being executed.
	CONFIG,
	## An authenticated RCON session.
	RCON,
	## An in-game chat trigger (`!kick`). The least trusted path.
	CHAT,
	## A loaded module or another subsystem.
	INTERNAL,
	## A remote client's console command, if the server permits any.
	CLIENT,
}

var source: Source = Source.CONSOLE

## The command name as typed.
var command: String = ""

## Arguments after the command name.
var args: PackedStringArray = PackedStringArray()

## The identity of the caller, when there is one. Null for console and config.
##
## Typed loosely because dot-server does not depend on dot-auth — this holds a
## [code]DotAuthIdentity[/code] when dot-auth is installed.
var identity: Object = null

## The calling client's session, when a client ran this.
var session: DotClientSession = null

## Permission flags the caller holds. Checked by the console before dispatch.
var permissions: PackedStringArray = PackedStringArray()

## Immunity level of the caller. Compared against a target's before acting.
var immunity: int = 0

## Where replies go. Set by whoever built the context.
##
## An RCON session sets one that accumulates into its response packet; the local
## console sets one that prints. Commands never need to know which.
var reply_sink: Callable = Callable()

## Address the command came from, for logs.
var address: String = ""

## Lines this command produced, kept regardless of the sink.
##
## Lets a caller read the output of a command it dispatched programmatically
## without having to install a sink for it.
var output: PackedStringArray = PackedStringArray()


static func console(command_name: String, arguments: PackedStringArray) -> DotCmdContext:
	var ctx := DotCmdContext.new()
	ctx.source = Source.CONSOLE
	ctx.command = command_name
	ctx.args = arguments
	# The local console holds every permission: whoever has the terminal already
	# has the process, and pretending otherwise only makes the server harder to
	# administer without making it safer.
	ctx.permissions = PackedStringArray([DotAdminFlags.ROOT])
	ctx.immunity = DotAdminFlags.MAX_IMMUNITY
	return ctx


static func internal(command_name: String, arguments: PackedStringArray) -> DotCmdContext:
	var ctx := console(command_name, arguments)
	ctx.source = Source.INTERNAL
	return ctx


# --- Arguments -------------------------------------------------------------

func argc() -> int:
	return args.size()


func arg(index: int, default: String = "") -> String:
	if index < 0 or index >= args.size():
		return default
	return args[index]


func arg_int(index: int, default: int = 0) -> int:
	var s := arg(index)
	return s.to_int() if s.is_valid_int() else default


func arg_float(index: int, default: float = 0.0) -> float:
	var s := arg(index)
	return s.to_float() if s.is_valid_float() else default


func arg_bool(index: int, default: bool = false) -> bool:
	var s := arg(index).to_lower()
	if s == "":
		return default
	if s.is_valid_float():
		return s.to_float() != 0.0
	return ["true", "yes", "on", "enabled"].has(s)


## Every argument from [param from] onwards, joined with spaces.
##
## For commands whose last parameter is free text — a kick reason, a chat message —
## where quoting the whole thing is a burden nobody remembers.
func rest(from: int = 0) -> String:
	if from >= args.size():
		return ""
	return " ".join(Array(args).slice(from))


# --- Output ----------------------------------------------------------------

## Sends a line back to whoever ran the command.
func reply(text: String) -> void:
	output.append(text)
	if reply_sink.is_valid():
		reply_sink.call(text)


func reply_lines(lines: PackedStringArray) -> void:
	for line in lines:
		reply(line)


## Reports a failure to the caller and logs it.
func reply_error(res: DotResult) -> void:
	if res.ok:
		return
	reply("Error: %s" % res.error.message)
	if res.error.detail != "":
		reply("  %s" % res.error.detail)


# --- Permissions -----------------------------------------------------------

func has_permission(flag: String) -> bool:
	return DotAdminFlags.granted(permissions, flag)


## Whether this caller may act on a target with [param target_immunity].
##
## Equal immunity cannot act on equal, which is the rule every long-lived admin
## system converges on: two admins at the same level kicking each other in a loop
## has no correct resolution, so it is forbidden rather than raced.
func outranks(target_immunity: int) -> bool:
	if has_permission(DotAdminFlags.ROOT):
		return true
	return immunity > target_immunity


func is_trusted() -> bool:
	return source == Source.CONSOLE or source == Source.CONFIG


func source_name() -> String:
	return Source.keys()[source].to_lower()


## A label for logs and the audit trail.
func caller_label() -> String:
	if identity != null and identity.has_method("label"):
		return str(identity.call("label"))
	if session != null:
		return session.label()
	if address != "":
		return "%s@%s" % [source_name(), address]
	return source_name()


func _to_string() -> String:
	return "DotCmdContext(%s %s from %s)" % [
		command, " ".join(Array(args)), caller_label()
	]
