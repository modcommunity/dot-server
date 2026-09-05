@tool
class_name DotBanStore
extends Resource

## Where bans are kept. Subclass to put them somewhere other than a file.
##
## [b]The case this exists for.[/b] A community running eight servers wants one ban
## list. With file storage each server has its own, a player banned on one walks into
## the next, and admins maintain eight copies by hand. A shared store — a database, an
## HTTP service, the backbone — makes a ban mean the same thing everywhere, and it is
## the single most requested thing from anyone running more than one server.
##
## [b]Load is allowed to be slow; the checks are not.[/b] [DotBanManager] keeps the
## loaded set in memory and answers every connection from it, so a store that talks to
## a database is queried at startup and on writes, never on the join path. A store that
## needs to poll for changes made elsewhere overrides [method _refresh].
##
## [codeblock]
## class_name SqlBanStore extends DotBanStore
##
## func _load() -> DotResult:
##     var rows := await db.query("SELECT * FROM bans WHERE server_group = $1", [group])
##     var out := {}
##     for row in rows:
##         out[row["key"]] = _row_to_ban(row)
##     return DotResult.success(out)
##
## func _put(key: String, ban: Dictionary) -> DotResult:
##     return await db.upsert("bans", key, ban)
##
## func _remove(key: String) -> DotResult:
##     return await db.delete("bans", key)
## [/codeblock]

const CHANNEL := "bans.store"

## Seconds between [method refresh] calls. 0 disables polling.
##
## For a shared store: a ban added on another server should take effect here without
## a restart. Local stores leave it at 0.
@export_range(0.0, 3600.0, 5.0) var refresh_interval_sec: float = 0.0


# --- Subclass interface ----------------------------------------------------

## Short name, for `banlist` output and logs.
func _store_name() -> String:
	return "custom"


## Loads every ban. Returns [code]{key: ban_dictionary}[/code].
##
## May be a coroutine. Called once at startup and again by [method refresh].
##
## [b]A failure here must not be treated as "no bans".[/b] [DotBanManager] keeps
## whatever it already had and logs loudly, because silently starting with an empty
## list readmits everyone who was ever removed.
func _load() -> DotResult:
	return DotResult.success({})


## Writes one ban. May be a coroutine.
func _put(_key: String, _ban: Dictionary) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "%s is read-only." % _store_name()
	)


## Deletes one ban. May be a coroutine.
func _remove(_key: String) -> DotResult:
	return DotResult.fail(
		DotError.CODE_UNSUPPORTED, "%s is read-only." % _store_name()
	)


## Re-reads bans changed elsewhere. Defaults to a full [method _load].
##
## Override when the backing store can report a delta — reloading ten thousand bans
## every thirty seconds to find the one that changed is wasteful.
func _refresh() -> DotResult:
	return await _load()


## Whether this store accepts writes.
##
## False for a read-only mirror of a central list, where bans are managed elsewhere
## and this server only enforces them. `ban` then reports that rather than appearing
## to work.
func _writable() -> bool:
	return true


# --- Public API ------------------------------------------------------------

func store_name() -> String:
	return _store_name()


func writable() -> bool:
	return _writable()


func load_bans() -> DotResult:
	var result: Variant = await _load()

	if not (result is DotResult):
		return DotResult.fail(
			DotError.CODE_INTERNAL,
			"%s._load() returned something other than a DotResult." % _store_name()
		)

	var typed := result as DotResult

	if typed.ok and not (typed.value is Dictionary):
		return DotResult.fail(
			DotError.CODE_INTERNAL,
			"%s._load() must return a Dictionary of bans." % _store_name()
		)

	return typed


func put(key: String, ban: Dictionary) -> DotResult:
	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN,
			"The ban store is read-only.",
			"bans are managed centrally; add it there"
		)
	return await _put(key, ban)


func remove(key: String) -> DotResult:
	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "The ban store is read-only."
		)
	return await _remove(key)


func refresh() -> DotResult:
	return await _refresh()


func describe() -> Dictionary:
	return {
		"store": _store_name(),
		"writable": _writable(),
		"refresh_sec": refresh_interval_sec,
	}


# --- Built-in file store ---------------------------------------------------

## The default: a JSON file on this server.
##
## Correct for a single server, and the reason [DotBanManager] works with no
## configuration. Its limitation is the whole reason this class is abstract — one
## server, one list, no sharing.
class FileStore extends DotBanStore:
	## Format version, so a future change can migrate rather than misread.
	const FORMAT_VERSION := 1

	var path: String

	func _init(p_path: String) -> void:
		path = p_path

	func _store_name() -> String:
		return "file"

	func _load() -> DotResult:
		if not FileAccess.file_exists(path):
			return DotResult.success({})

		var read := DotPaths.read_json(path)
		if not read.ok:
			return read.wrap("Could not read the ban list.")

		var data: Variant = read.value
		if not (data is Dictionary):
			return DotResult.fail(
				DotError.CODE_PARSE, "The ban list must be a JSON object."
			)

		var entries: Variant = (data as Dictionary).get("bans", {})
		if not (entries is Dictionary):
			return DotResult.success({})

		var out := {}
		for key in (entries as Dictionary):
			var ban: Variant = (entries as Dictionary)[key]
			if ban is Dictionary:
				out[str(key)] = ban

		return DotResult.success(out)

	## Writes the whole file.
	##
	## Per-key writes would mean a read-modify-write per ban; the whole list is a few
	## hundred kilobytes at worst and [method DotPaths.write_json] is atomic, so a
	## crash mid-write leaves the old list rather than half of a new one.
	func write_all(bans: Dictionary) -> DotResult:
		return DotPaths.write_json(
			path, {"version": FORMAT_VERSION, "bans": bans}, false
		)

	func _put(_key: String, _ban: Dictionary) -> DotResult:
		# DotBanManager holds the authoritative in-memory set and calls write_all
		# after mutating it, so a per-key write here would be redundant.
		return DotResult.success(true)

	func _remove(_key: String) -> DotResult:
		return DotResult.success(true)
