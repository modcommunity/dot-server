@tool
class_name DotAdminManager
extends Node

## Resolves a connected player to permission flags and an immunity level.
##
## Reads a JSON file of admins and groups, and consults any number of pluggable
## sources — dot-auth's [code]DotAuthAdminSource[/code] being the interesting one,
## which maps site groups to server flags so an operator does not maintain a list of
## user ids by hand.
##
## [b]Sources are duck-typed on purpose.[/b] dot-server does not depend on dot-auth,
## so a source is any object with:
##
## [codeblock]
## func lookup(identity: Object) -> DotResult   # -> {flags, immunity, source}
## func source_name() -> String
## [/codeblock]
##
## Results from every source are merged: a player in a file entry and a site group
## holds the union of both flags and the higher of the two immunity levels. Merging
## rather than first-match-wins is what lets a local file grant one extra flag to
## somebody who already has permissions from the site.

const CHANNEL := "admin"
const SERVICE := &"dot_admin_manager"

## Emitted when the admin file is loaded or reloaded.
signal admins_loaded(count: int)

## Emitted when a player's permissions are resolved, for audit logging.
signal permissions_resolved(session: DotClientSession, flags: PackedStringArray)

@export var config: DotServerConfig = null

## Additional permission sources, in consultation order.
var sources: Array = []

## uid -> {flags, immunity, groups, name}
var _admins: Dictionary = {}

## group name -> {flags, immunity}
var _groups: Dictionary = {}

var _file_modified_time: int = 0
var _reload_timer: Timer = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	DotRegistry.register(SERVICE, self)

	if config != null:
		load_admins()

		if config.admins_auto_reload:
			_reload_timer = Timer.new()
			_reload_timer.wait_time = 10.0
			_reload_timer.autostart = true
			_reload_timer.timeout.connect(_check_for_changes)
			add_child(_reload_timer)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


# --- Sources ---------------------------------------------------------------

## Adds a permission source.
##
## Validates the contract at registration so a mistyped source is a startup error
## rather than a silent absence of permissions later.
func add_source(source: Object) -> DotResult:
	if source == null:
		return DotResult.fail(DotError.CODE_INVALID, "Null source.")

	for method in ["lookup", "source_name"]:
		if not source.has_method(method):
			return DotResult.fail(
				DotError.CODE_INVALID,
				"An admin source must implement %s()." % method,
				source.get_class()
			)

	sources.append(source)

	DotLog.info(
		CHANNEL,
		"admin source added",
		{"source": str(source.call("source_name"))}
	)

	return DotResult.success(source)


func remove_source(source: Object) -> void:
	sources.erase(source)


# --- Resolution ------------------------------------------------------------

## Resolves and caches permissions onto a session.
##
## Called once per client at authentication. Cached on the session rather than
## resolved per command, because a lookup can hit a file or a remote source and
## doing that on every chat message would let a client make the server work by
## talking.
func resolve(session: DotClientSession) -> DotResult:
	session.permissions = PackedStringArray()
	session.immunity = DotAdminFlags.NO_IMMUNITY

	if not session.is_authenticated():
		# An unauthenticated or guest session gets nothing. A guest uid is a random
		# per-device string, so granting anything would grant it to anyone.
		return DotResult.success(session.permissions)

	var uid := session.uid()
	var reasons := PackedStringArray()

	if _admins.has(uid):
		var entry: Dictionary = _admins[uid]
		session.permissions = DotAdminFlags.merge(
			session.permissions, _flags_of(entry)
		)
		session.immunity = maxi(session.immunity, int(entry.get("immunity", 0)))
		reasons.append("file")

		for group in entry.get("groups", []):
			var group_name := str(group)
			if _groups.has(group_name):
				var g: Dictionary = _groups[group_name]
				session.permissions = DotAdminFlags.merge(
					session.permissions, _flags_of(g)
				)
				session.immunity = maxi(
					session.immunity, int(g.get("immunity", 0))
				)
				reasons.append("group:%s" % group_name)
			else:
				DotLog.warn(
					CHANNEL,
					"admin entry references an unknown group",
					{"uid": uid, "group": group_name}
				)

	for source in sources:
		var res: Variant = source.call("lookup", session.identity)

		if not (res is DotResult):
			DotLog.warn(
				CHANNEL,
				"admin source returned something other than a DotResult",
				{"source": str(source.call("source_name"))}
			)
			continue

		var result := res as DotResult
		if not result.ok:
			# Not an error: a source saying "nothing for this player" is the normal
			# case for most players and most sources.
			continue

		var payload: Variant = result.value
		if not (payload is Dictionary):
			continue

		var d := payload as Dictionary
		session.permissions = DotAdminFlags.merge(
			session.permissions, _as_flags(d.get("flags", []))
		)
		session.immunity = maxi(session.immunity, int(d.get("immunity", 0)))
		reasons.append(str(d.get("source", source.call("source_name"))))

	if not session.permissions.is_empty():
		DotLog.info(
			CHANNEL,
			"admin recognised",
			{
				"user": session.label(),
				"flags": DotAdminFlags.format(session.permissions),
				"immunity": session.immunity,
				"via": ", ".join(reasons),
			}
		)

	permissions_resolved.emit(session, session.permissions)
	return DotResult.success(session.permissions)


## Whether a player holds a flag, by uid, without a session.
##
## For deciding whether to hold a reserved slot for somebody who has not connected
## yet.
func uid_has_permission(uid: String, flag: String) -> bool:
	if not _admins.has(uid):
		return false

	var entry: Dictionary = _admins[uid]
	var flags := _flags_of(entry)

	for group in entry.get("groups", []):
		if _groups.has(str(group)):
			flags = DotAdminFlags.merge(
				flags, _flags_of(_groups[str(group)])
			)

	return DotAdminFlags.granted(flags, flag)


# --- Persistence -----------------------------------------------------------

## Loads the admin file. A missing file is not an error.
func load_admins() -> DotResult:
	_admins.clear()
	_groups.clear()

	var path := config.admins_path

	if not FileAccess.file_exists(path):
		DotLog.info(
			CHANNEL,
			"no admin file; nobody has permissions yet",
			{"path": path}
		)
		# Written so an operator has something to edit rather than having to
		# discover the format.
		_write_template(path)
		return DotResult.success(0)

	var read := DotPaths.read_json(path)
	if not read.ok:
		# A malformed admin file must not silently mean "no admins" — that turns a
		# typo into an unmoderated server. Report loudly and keep whatever was
		# loaded before.
		DotLog.error(
			CHANNEL,
			"the admin file is malformed; permissions were NOT loaded",
			{"path": path, "detail": read.error.detail}
		)
		return read

	var data: Variant = read.value
	if not (data is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE, "The admin file must be a JSON object."
		)

	var d := data as Dictionary

	if d.get("groups") is Dictionary:
		for name in (d["groups"] as Dictionary):
			var g: Variant = (d["groups"] as Dictionary)[name]
			if g is Dictionary:
				_groups[str(name)] = g

	if d.get("admins") is Dictionary:
		for uid in (d["admins"] as Dictionary):
			var a: Variant = (d["admins"] as Dictionary)[uid]
			if a is Dictionary:
				_admins[str(uid)] = a

	_file_modified_time = FileAccess.get_modified_time(path)

	_warn_about_unknown_flags()

	DotLog.info(
		CHANNEL,
		"admins loaded",
		{"admins": _admins.size(), "groups": _groups.size()}
	)

	admins_loaded.emit(_admins.size())
	return DotResult.success(_admins.size())


func save_admins() -> DotResult:
	var payload := {"groups": _groups, "admins": _admins}
	var written := DotPaths.write_json(config.admins_path, payload)

	if written.ok:
		_file_modified_time = FileAccess.get_modified_time(config.admins_path)
		DotLog.info(CHANNEL, "admins saved", {"count": _admins.size()})

	return written


func _check_for_changes() -> void:
	var path := config.admins_path
	if not FileAccess.file_exists(path):
		return

	var modified := FileAccess.get_modified_time(path)
	if modified == _file_modified_time:
		return

	DotLog.info(CHANNEL, "admin file changed; reloading")
	load_admins()


func _write_template(path: String) -> void:
	var template := {
		"groups": {
			"moderator": {
				"flags": ["generic", "kick", "mute", "chat"],
				"immunity": 20,
			},
			"admin": {
				"flags": [
					"generic", "kick", "ban", "unban", "mute",
					"changemap", "cvar", "chat", "vote",
				],
				"immunity": 60,
			},
			"owner": {"flags": ["root"], "immunity": 100},
		},
		"admins": {
			"_example": {
				"name": "Replace this key with a real uid, e.g. backbone:clx8f2k0",
				"groups": ["admin"],
				"flags": [],
				"immunity": 0,
			},
		},
	}

	var written := DotPaths.write_json(path, template)
	if written.ok:
		DotLog.info(CHANNEL, "wrote an admin file template", {"path": path})


## Reports flags that are not standard, without refusing them.
##
## A game defines its own flags, so unknown is legal. But it is also what a typo
## looks like, and an admin whose [code]"kcik"[/code] silently does nothing is a
## support ticket.
func _warn_about_unknown_flags() -> void:
	var seen := {}

	for uid in _admins:
		for flag in DotAdminFlags.unknown(_flags_of(_admins[uid])):
			seen[flag] = true

	for name in _groups:
		for flag in DotAdminFlags.unknown(_flags_of(_groups[name])):
			seen[flag] = true

	if not seen.is_empty():
		DotLog.info(
			CHANNEL,
			"admin file uses non-standard flags (fine if your game defines them)",
			{"flags": seen.keys()}
		)


# --- Editing ---------------------------------------------------------------

## Adds or updates an admin entry and saves.
func set_admin(
	uid: String,
	flags: PackedStringArray,
	immunity: int,
	groups: PackedStringArray = PackedStringArray(),
	name: String = ""
) -> DotResult:
	if uid.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "No uid given.")

	_admins[uid] = {
		"name": name,
		"flags": Array(flags),
		"immunity": clampi(immunity, 0, DotAdminFlags.MAX_IMMUNITY),
		"groups": Array(groups),
	}

	DotLog.info(
		CHANNEL,
		"admin entry set",
		{"uid": uid, "flags": DotAdminFlags.format(flags)}
	)

	return save_admins()


func remove_admin(uid: String) -> DotResult:
	if not _admins.erase(uid):
		return DotResult.fail(
			DotError.CODE_INVALID, "No admin entry for '%s'." % uid
		)

	DotLog.info(CHANNEL, "admin entry removed", {"uid": uid})
	return save_admins()


func set_group(
	name: String,
	flags: PackedStringArray,
	immunity: int
) -> DotResult:
	_groups[name] = {
		"flags": Array(flags),
		"immunity": clampi(immunity, 0, DotAdminFlags.MAX_IMMUNITY),
	}
	return save_admins()


# --- Queries ---------------------------------------------------------------

func admin_count() -> int:
	return _admins.size()


func group_names() -> PackedStringArray:
	var out := PackedStringArray(_groups.keys())
	out.sort()
	return out


func admin_uids() -> PackedStringArray:
	var out := PackedStringArray(_admins.keys())
	out.sort()
	return out


func _flags_of(entry: Dictionary) -> PackedStringArray:
	return _as_flags(entry.get("flags", []))


func _as_flags(value: Variant) -> PackedStringArray:
	if value is PackedStringArray:
		return value
	if value is Array:
		var out := PackedStringArray()
		for v in (value as Array):
			out.append(str(v).to_lower())
		return out
	if value is String:
		return DotAdminFlags.parse(value as String)
	return PackedStringArray()


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	out.append("groups:")
	for name in group_names():
		var g: Dictionary = _groups[name]
		out.append("  %-16s immunity %-4d %s" % [
			name,
			int(g.get("immunity", 0)),
			DotAdminFlags.format(_flags_of(g)),
		])

	out.append("admins: %d" % _admins.size())
	for uid in admin_uids():
		var a: Dictionary = _admins[uid]
		out.append("  %-32s %s" % [
			uid,
			", ".join(Array(a.get("groups", []))) if not (a.get("groups", []) as Array).is_empty()
				else DotAdminFlags.format(_flags_of(a)),
		])

	out.append("sources:")
	for source in sources:
		out.append("  %s" % str(source.call("source_name")))

	return out
