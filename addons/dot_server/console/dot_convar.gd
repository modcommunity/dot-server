class_name DotConVar
extends RefCounted

## A console variable, modelled on the console variables of every dedicated server.
##
## [b]Why values are stored as strings.[/b] Every path a cvar value arrives
## through is textual — a [code].cfg[/code] file, an RCON packet, a chat command,
## a command-line argument — and every path it leaves through is textual too.
## Storing the string and converting on read means one representation, one place
## where parsing can fail, and no class of bug where [code]sv_gravity 800[/code]
## and [code]sv_gravity 800.0[/code] behave differently.
##
## Flags are the interesting part. They are what makes a console safe to expose:
## [constant FLAG_CHEAT] variables refuse to change unless [code]sv_cheats[/code]
## is on, [constant FLAG_PROTECTED] values never appear in output, and
## [constant FLAG_ARCHIVE] decides what [code]writeconfig[/code] persists.

## Persisted by `writeconfig`. For operator settings, not runtime state.
const FLAG_ARCHIVE := 1 << 0

## Refuses to change unless `sv_cheats` is on.
##
## The whole reason a cheat flag exists: a server can ship a console that
## exposes gameplay-affecting variables without those variables being reachable
## on a live competitive server.
const FLAG_CHEAT := 1 << 1

## Value is sent to clients and kept in sync.
##
## For rules a client needs to predict correctly — gravity, movement speed. A
## client that disagrees mispredicts, and the mismatch looks like lag.
const FLAG_REPLICATED := 1 << 2

## Announces changes in chat.
const FLAG_NOTIFY := 1 << 3

## Value is never shown: redacted in `cvarlist`, `status` and every log line.
##
## For `rcon_password` and `sv_password`. A console that prints these is one
## pasted screenshot away from a compromised server.
const FLAG_PROTECTED := 1 << 4

## Meaningful only on the server. Client-side use is refused.
const FLAG_SERVER_ONLY := 1 << 5

## Meaningful only on a client.
const FLAG_CLIENT_ONLY := 1 << 6

## Hidden from `cvarlist` and completion, but still settable if you know the name.
##
## For internals and deprecated aliases — clutter reduction, not access control.
const FLAG_HIDDEN := 1 << 7

## Cannot be changed after the server has started.
##
## For things a live server cannot re-negotiate: the listen port, the tickrate,
## the transport. Changing them at runtime would half-apply.
const FLAG_STARTUP_ONLY := 1 << 8

## May be changed by clients over RCON only with the `cvar` permission.
const FLAG_NEEDS_PERMISSION := 1 << 9

const FLAG_NAMES := {
	FLAG_ARCHIVE: "archive",
	FLAG_CHEAT: "cheat",
	FLAG_REPLICATED: "replicated",
	FLAG_NOTIFY: "notify",
	FLAG_PROTECTED: "protected",
	FLAG_SERVER_ONLY: "sv_only",
	FLAG_CLIENT_ONLY: "cl_only",
	FLAG_HIDDEN: "hidden",
	FLAG_STARTUP_ONLY: "startup",
	FLAG_NEEDS_PERMISSION: "needs_perm",
}

## Emitted after a successful change. [param old] and [param new] are strings.
signal changed(old_value: String, new_value: String)

var name: String
var description: String
var flags: int

var default_value: String
var _value: String

## Numeric bounds. Applied only when set — see [member has_min] / [member has_max].
var min_value: float = 0.0
var max_value: float = 0.0
var has_min: bool = false
var has_max: bool = false

## Optional validator. Returns a [DotResult]; a failure refuses the change.
##
## For constraints reflection cannot express: a port already in use, a map that
## does not exist, a tickrate the physics step cannot divide.
var validator: Callable = Callable()


func _init(
	p_name: String,
	p_default: String,
	p_description: String = "",
	p_flags: int = 0
) -> void:
	name = p_name
	default_value = p_default
	_value = p_default
	description = p_description
	flags = p_flags


## Sets numeric bounds. Returns self so construction can chain.
func with_range(p_min: float, p_max: float) -> DotConVar:
	min_value = p_min
	max_value = p_max
	has_min = true
	has_max = true
	return self


func with_min(p_min: float) -> DotConVar:
	min_value = p_min
	has_min = true
	return self


func with_max(p_max: float) -> DotConVar:
	max_value = p_max
	has_max = true
	return self


func with_validator(p_validator: Callable) -> DotConVar:
	validator = p_validator
	return self


# --- Reading ---------------------------------------------------------------

func get_string() -> String:
	return _value


func get_int() -> int:
	return _value.to_int() if _value.is_valid_int() else int(get_float())


func get_float() -> float:
	return _value.to_float() if _value.is_valid_float() else 0.0


## Truthiness, accepting everything an operator might reasonably type.
##
## Those consoles treat any nonzero number as true and nothing else; accepting
## [code]true[/code] / [code]on[/code] / [code]yes[/code] as well costs nothing
## and stops [code]sv_cheats true[/code] from silently meaning false.
func get_bool() -> bool:
	var s := _value.strip_edges().to_lower()
	if s.is_valid_float():
		return s.to_float() != 0.0
	return ["true", "yes", "on", "enabled"].has(s)


func is_default() -> bool:
	return _value == default_value


# --- Writing ---------------------------------------------------------------

## Changes the value, enforcing flags and bounds.
##
## [param context] describes who is setting it and gates the flag checks. Keys:
## [code]cheats_enabled[/code], [code]server_running[/code],
## [code]has_permission[/code], [code]source[/code].
##
## A cvar set from a config file at boot legitimately bypasses checks that a cvar
## set by a client over RCON must not, which is why this takes a context rather
## than reading global state.
func set_value(new_value: String, context: Dictionary = {}) -> DotResult:
	var trimmed := new_value.strip_edges()

	if (flags & FLAG_CHEAT) and not bool(context.get("cheats_enabled", false)):
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"%s is a cheat variable and sv_cheats is off." % name
		)

	if (flags & FLAG_STARTUP_ONLY) and bool(context.get("server_running", false)):
		return DotResult.fail(
			DotError.CODE_STATE,
			"%s can only be changed before the server starts." % name,
			"restart with the new value"
		)

	if (flags & FLAG_NEEDS_PERMISSION) and not bool(
		context.get("has_permission", true)
	):
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"You do not have permission to change %s." % name
		)

	var coerced := _coerce(trimmed)
	if not coerced.ok:
		return coerced

	var final: String = coerced.value

	if validator.is_valid():
		var checked: Variant = validator.call(final)
		if checked is DotResult and not (checked as DotResult).ok:
			return checked

	if final == _value:
		return DotResult.success(final)

	var old := _value
	_value = final

	changed.emit(old, final)

	DotLog.debug(
		"convar",
		"changed",
		{
			"cvar": name,
			# A protected value must not reach the log either. This is the same
			# reasoning as redacting it from `cvarlist`, and the log is the more
			# commonly shared artefact of the two.
			"from": "***" if (flags & FLAG_PROTECTED) else old,
			"to": "***" if (flags & FLAG_PROTECTED) else final,
			"by": str(context.get("source", "console")),
		}
	)

	return DotResult.success(final)


## Sets the value ignoring every flag check. For internal use at boot only.
func force_set(new_value: String) -> void:
	var old := _value
	_value = new_value.strip_edges()
	if old != _value:
		changed.emit(old, _value)


func reset() -> void:
	force_set(default_value)


## Applies bounds, clamping rather than refusing.
##
## Clamping is what an operator typing at a console expects, and is the right
## behaviour for one at a
## console: [code]sv_maxplayers 9999[/code] should give them the maximum with a
## note, not an error they have to look up the limit to fix.
func _coerce(value: String) -> DotResult:
	if not (has_min or has_max):
		return DotResult.success(value)

	if not value.is_valid_float():
		return DotResult.fail(
			DotError.CODE_INVALID,
			"%s expects a number, got '%s'." % [name, value]
		)

	var f := value.to_float()
	var clamped := f

	if has_min:
		clamped = maxf(clamped, min_value)
	if has_max:
		clamped = minf(clamped, max_value)

	if not is_equal_approx(clamped, f):
		DotLog.info(
			"convar",
			"value clamped to the allowed range",
			{"cvar": name, "asked": f, "used": clamped}
		)

	# Preserve integer formatting so `sv_maxplayers` reads 32 rather than 32.0 in
	# cvarlist and writeconfig output.
	if is_equal_approx(clamped, roundf(clamped)) and not value.contains("."):
		return DotResult.success(str(int(clamped)))

	return DotResult.success(str(clamped))


# --- Reporting -------------------------------------------------------------

func has_flag(flag: int) -> bool:
	return (flags & flag) != 0


func flag_names() -> PackedStringArray:
	var out := PackedStringArray()
	for flag in FLAG_NAMES:
		if flags & int(flag):
			out.append(str(FLAG_NAMES[flag]))
	return out


## The value as it may be shown. Protected cvars report [code]***[/code].
func display_value() -> String:
	if flags & FLAG_PROTECTED:
		return "***" if _value != "" else "(unset)"
	return _value


## One line for `cvarlist`.
func describe_line() -> String:
	var s := "%-28s %-14s" % [name, display_value()]

	var tags := flag_names()
	if not tags.is_empty():
		s += " [%s]" % ", ".join(tags)

	if has_min or has_max:
		s += " (%s..%s)" % [
			str(min_value) if has_min else "-",
			str(max_value) if has_max else "-",
		]

	if description != "":
		s += " - " + description

	return s


## Multi-line detail for `help <cvar>`.
func describe_help() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("%s = %s (default: %s)" % [
		name,
		display_value(),
		"***" if (flags & FLAG_PROTECTED) else default_value,
	])

	if description != "":
		out.append("  " + description)

	var tags := flag_names()
	if not tags.is_empty():
		out.append("  flags: %s" % ", ".join(tags))

	if has_min or has_max:
		out.append("  range: %s to %s" % [
			str(min_value) if has_min else "unbounded",
			str(max_value) if has_max else "unbounded",
		])

	if flags & FLAG_CHEAT:
		out.append("  requires sv_cheats 1")
	if flags & FLAG_STARTUP_ONLY:
		out.append("  cannot be changed while the server is running")

	return out


func _to_string() -> String:
	return "DotConVar(%s = %s)" % [name, display_value()]
