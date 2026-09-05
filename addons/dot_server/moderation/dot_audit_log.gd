@tool
class_name DotAuditLog
extends Node

## An append-only record of every administrative action.
##
## [b]Separate from the general server log on purpose.[/b] The general log rotates,
## is full of routine noise, and gets truncated when a disk fills. This is the record
## a moderation dispute is resolved from — "who banned this player, when, and why" —
## and it needs to survive all of that.
##
## One JSON object per line (JSONL), so it can be tailed, grepped, and fed to
## anything that reads a stream of events without needing a parser for a bespoke
## format. Appended and flushed immediately: an action that happened but was not
## recorded because the process crashed is exactly the case an audit log exists for.

const CHANNEL := "audit"
const SERVICE := &"dot_audit_log"

## Emitted for every recorded action, so a module can forward it elsewhere.
signal action_recorded(entry: Dictionary)

@export var config: DotServerConfig = null

## Path override. Falls back to [member DotServerConfig.audit_log_path].
@export var path_override: String = ""

## Also log every action to [DotLog] at INFO.
@export var mirror_to_log: bool = true

## Entries kept in memory for the `audit` console command.
##
## The file is the record; this is a convenience so an admin can see recent actions
## without shelling into the box.
@export_range(0, 10000, 10) var recent_limit: int = 200

var _recent: Array[Dictionary] = []
var _file: FileAccess = null
var _path: String = ""
var _write_failed: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	DotRegistry.register(SERVICE, self)
	open_log()


## Resolves the path and opens the file. Safe to call again once [member config] is set.
##
## [b]Called twice, and the second time is the one that works.[/b] Every subsystem on
## [DotServer] is a [DotNodeRef] defaulting to `of_created(...)`, and a created node has
## already run [method Node._ready] by the time [DotServer] assigns its [member config] —
## which is why `admins.load_admins()` is triggered explicitly rather than left to `_ready`
## ordering. This was the one that was missed: `_ready` found no config, took the
## "no audit log path" branch and returned, and nothing ever opened the file afterwards.
##
## So in the default configuration — every server that does not place its own audit node —
## no administrative action was ever recorded. The warning said so on every boot and reads
## like a setting nobody had filled in.
##
## Idempotent: a log already open is left alone, so calling this from both places cannot
## reopen the file or truncate it.
func open_log() -> DotResult:
	if _file != null:
		return DotResult.success(_path)

	_path = path_override

	if _path == "" and config != null:
		_path = config.audit_log_path

	if _path == "":
		# Not warned here. `_ready` legitimately runs before a config is assigned, and a
		# warning on every boot that is then resolved a millisecond later is a warning
		# people learn to ignore. [DotServer] reports it once, after it has set the config.
		return DotResult.fail(DotError.CODE_STATE, "No audit log path.")

	var opened := _open()

	if not opened.ok:
		DotLog.error(
			CHANNEL,
			"could not open the audit log — administrative actions will NOT be recorded",
			{"path": _path, "detail": opened.error.detail}
		)

	return opened


## Whether anything is actually being recorded to disk.
func is_recording() -> bool:
	return _file != null and not _write_failed


func _exit_tree() -> void:
	if _file != null:
		_file.flush()
		_file.close()
		_file = null
	DotRegistry.unregister_instance(SERVICE, self)


func _open() -> DotResult:
	var parent := DotPaths.ensure_parent_dir(_path)
	if not parent.ok:
		return parent

	# READ_WRITE preserves history; WRITE would truncate it, which for an audit log
	# is the one unacceptable failure mode.
	_file = FileAccess.open(_path, FileAccess.READ_WRITE)
	if _file == null:
		_file = FileAccess.open(_path, FileAccess.WRITE)

	if _file == null:
		return DotResult.failure(
			DotError.from_engine(
				FileAccess.get_open_error(), "opening '%s'" % _path
			)
		)

	_file.seek_end()
	return DotResult.success(_path)


# --- Recording -------------------------------------------------------------

## Records an action.
##
## [param action] is a short verb: [code]ban[/code], [code]kick[/code],
## [code]cvar[/code], [code]changelevel[/code]. [param actor] is who did it, as a
## label including their account id where there is one. [param target] is who or
## what it was done to.
func record(
	action: String,
	actor: String,
	target: String = "",
	details: Dictionary = {}
) -> void:
	var entry := {
		# Wall clock, not ticks: this outlives the process.
		"at": int(Time.get_unix_time_from_system()),
		"iso": Time.get_datetime_string_from_system(true, true),
		"action": action,
		"actor": actor,
		"target": target,
	}

	if not details.is_empty():
		entry["details"] = details

	_recent.append(entry)
	if recent_limit > 0 and _recent.size() > recent_limit:
		_recent = _recent.slice(_recent.size() - recent_limit)

	if mirror_to_log:
		var fields := {"actor": actor}
		if target != "":
			fields["target"] = target
		for k in details:
			fields[str(k)] = details[k]
		DotLog.info(CHANNEL, action, fields)

	_append(entry)
	action_recorded.emit(entry)


## Records a command a caller ran. Wired to [signal DotConsole.command_executed].
##
## Not every command is interesting — `status` and `help` change nothing and would
## bury the record. Only commands that carry a permission are recorded, which is a
## reasonable proxy for "changes something".
func record_command(ctx: DotCmdContext, permission: String) -> void:
	if permission == "":
		return

	record(
		"command",
		ctx.caller_label(),
		ctx.command,
		{
			"args": " ".join(Array(ctx.args)),
			"via": ctx.source_name(),
			"address": ctx.address,
		}
	)


func _append(entry: Dictionary) -> void:
	if _file == null:
		return

	_file.store_line(JSON.stringify(entry))

	# Flushed per entry. An audit log that loses the last few actions to a crash is
	# missing exactly the actions somebody is asking about.
	_file.flush()
	DotWeb.sync_filesystem()

	if _file.get_error() != OK and not _write_failed:
		# Reported once rather than per line, so a full disk does not produce a log
		# flood on top of the failure.
		_write_failed = true
		DotLog.error(
			CHANNEL,
			"the audit log write failed — actions are no longer being recorded",
			{"path": _path, "error": error_string(_file.get_error())}
		)


# --- Reading ---------------------------------------------------------------

## Recent entries, newest last.
func recent(limit: int = 50) -> Array[Dictionary]:
	if limit <= 0 or limit >= _recent.size():
		return _recent
	return _recent.slice(_recent.size() - limit)


## Recent entries matching a substring of actor, target or action.
func search(query: String, limit: int = 50) -> Array[Dictionary]:
	var needle := query.to_lower()
	var out: Array[Dictionary] = []

	for i in range(_recent.size() - 1, -1, -1):
		var entry := _recent[i]
		var haystack := "%s %s %s %s" % [
			str(entry.get("action", "")),
			str(entry.get("actor", "")),
			str(entry.get("target", "")),
			JSON.stringify(entry.get("details", {})),
		]

		if haystack.to_lower().contains(needle):
			out.append(entry)
			if out.size() >= limit:
				break

	out.reverse()
	return out


func describe_lines(limit: int = 25) -> PackedStringArray:
	var out := PackedStringArray()

	for entry in recent(limit):
		var line := "%s  %-12s %-28s %s" % [
			str(entry.get("iso", "")),
			str(entry.get("action", "")),
			str(entry.get("actor", "")).substr(0, 28),
			str(entry.get("target", "")),
		]

		var details: Variant = entry.get("details")
		if details is Dictionary and not (details as Dictionary).is_empty():
			line += "  " + DotLog.format_fields(details as Dictionary)

		out.append(line)

	if out.is_empty():
		out.append("no recorded actions")

	return out


func describe() -> Dictionary:
	return {
		"path": _path,
		"open": _file != null,
		"write_failed": _write_failed,
		"recent": _recent.size(),
	}
