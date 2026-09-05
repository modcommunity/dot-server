class_name DotEvent
extends RefCounted

## One fired event, carrying its data and whether a hook cancelled it.
##
## Passed by reference to every hook, so a pre-hook can both inspect and modify it:
## a chat filter rewrites [code]text[/code], a rate limiter cancels outright. That
## mutability is the point — a hook that could only observe would need a separate
## mechanism to act.

var name: String

## Event payload. Hooks may modify values in place.
var data: Dictionary

## Set by [method cancel]. The firing code must check it.
var cancelled: bool = false

## Why it was cancelled, for logs and for telling a player.
var cancel_reason: String = ""

## Which hook cancelled it, for diagnosing a rule nobody expected.
var cancelled_by: String = ""

var fired_at_ms: int


func _init(p_name: String, p_data: Dictionary = {}) -> void:
	name = p_name
	data = p_data
	fired_at_ms = Time.get_ticks_msec()


## Stops the event. Remaining pre-hooks are skipped and post-hooks do not run.
func cancel(reason: String = "", by: String = "") -> void:
	cancelled = true
	cancel_reason = reason
	cancelled_by = by


# --- Typed accessors -------------------------------------------------------
#
# Event data arrives from RPCs and config files, so a field's type is not
# guaranteed. These coerce rather than crash, because a hook that fails on an
# unexpected type takes the event — and often the frame — with it.

func get_string(key: String, default: String = "") -> String:
	var v: Variant = data.get(key)
	return str(v) if v != null else default


func get_int(key: String, default: int = 0) -> int:
	var v: Variant = data.get(key)
	if v is int:
		return v
	if v is float:
		return int(v)
	if v is String and (v as String).is_valid_int():
		return (v as String).to_int()
	return default


func get_float(key: String, default: float = 0.0) -> float:
	var v: Variant = data.get(key)
	if v is float:
		return v
	if v is int:
		return float(v)
	if v is String and (v as String).is_valid_float():
		return (v as String).to_float()
	return default


func get_bool(key: String, default: bool = false) -> bool:
	var v: Variant = data.get(key)
	if v is bool:
		return v
	if v is int or v is float:
		return float(v) != 0.0
	if v is String:
		return ["1", "true", "yes", "on"].has((v as String).to_lower())
	return default


func get_object(key: String) -> Object:
	var v: Variant = data.get(key)
	return v as Object if v is Object else null


## The session this event is about, when it carries one.
func get_session() -> DotClientSession:
	var v: Variant = data.get("session")
	return v as DotClientSession if v is DotClientSession else null


func set_value(key: String, value: Variant) -> void:
	data[key] = value


func has(key: String) -> bool:
	return data.has(key)


func _to_string() -> String:
	var s := "DotEvent(%s" % name
	if cancelled:
		s += ", cancelled: %s" % cancel_reason
	return s + ")"
