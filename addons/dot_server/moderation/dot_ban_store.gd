@tool
class_name DotBanStore
extends Resource

## Where bans are kept. Subclass ([method _load], [method _put], [method _remove]) to share one
## list across servers via a database or HTTP service. Load may be slow, checks are not:
## [DotBanManager] answers joins from memory. Override [method _refresh] to poll for changes.

const CHANNEL := "bans.store"

## Seconds between [method refresh] calls; 0 disables polling. For a shared store, so a ban
## added elsewhere takes effect without a restart.
@export_range(0.0, 3600.0, 5.0) var refresh_interval_sec: float = 0.0



## Short name, for `banlist` output and logs.
func _store_name() -> String:
	return "custom"


## Loads every ban as [code]{key: ban_dictionary}[/code]; may be a coroutine. Called at
## startup and by [method refresh]. A failure must not mean "no bans": [DotBanManager] keeps
## what it had and logs, since an empty list readmits everyone removed.
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


## Re-reads bans changed elsewhere; a full [method _load] by default. Override when the
## backing store can report a delta.
func _refresh() -> DotResult:
	return await _load()


## Whether this store accepts writes. False for a read-only mirror of a central list, so
## `ban` reports that rather than appearing to work.
func _writable() -> bool:
	return true



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
	var res: DotResult = await _put(key, ban)
	_report_write("a ban was not recorded", key, res)
	return res


func remove(key: String) -> DotResult:
	if not _writable():
		return DotResult.fail(
			DotError.CODE_FORBIDDEN, "The ban store is read-only."
		)
	var res: DotResult = await _remove(key)
	_report_write("a ban was not lifted", key, res)
	return res


## Logged here because every store's write passes through it. ERROR: a ban that did not reach a
## shared store is a player other servers still admit. Load and refresh failures are logged by
## DotBanManager, which knows whether the last good list applies.
func _report_write(what: String, key: String, res: DotResult) -> void:
	if res == null or res.ok:
		return
	DotLog.error(CHANNEL, what, {
		"store": _store_name(),
		"key": key,
		"code": res.code(),
		"error": res.error.message if res.error != null else "",
	})


func refresh() -> DotResult:
	return await _refresh()


func describe() -> Dictionary:
	return {
		"store": _store_name(),
		"writable": _writable(),
		"refresh_sec": refresh_interval_sec,
	}



## The default: a JSON file on this server. Correct for a single server; one server, one
## list, no sharing is why this class is abstract.
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

	## Writes the whole file ([method DotPaths.write_json] is atomic, so a crash leaves the
	## old list; the list is small enough that per-key writes would not pay).
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
