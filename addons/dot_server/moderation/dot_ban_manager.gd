@tool
class_name DotBanManager
extends Node

## Bans, by account and by address, with durations and an audit trail.
##
## [b]Two kinds of ban, because they fail differently.[/b] An account ban is precise
## and survives a reconnect, but only works on authenticated players — a guest just
## comes back as a different guest. An address ban catches anyone on that address,
## including household members and everyone behind a shared NAT, and is defeated by a
## router reboot. Both exist; neither is sufficient alone.
##
## Bans are checked before authentication where possible (address) and immediately
## after where not (account), so a banned player's connection is refused rather than
## admitted and then dropped.

const CHANNEL := "bans"
const SERVICE := &"dot_ban_manager"

## Stored format version.
const FORMAT_VERSION := 1

## Emitted when a ban is added.
signal ban_added(ban: Dictionary)

## Emitted when a ban is lifted.
signal ban_removed(key: String)

@export var config: DotServerConfig = null

## Where bans are persisted. Defaults to a JSON file on this server.
##
## Assign a [DotBanStore] subclass to share one ban list across a group of servers —
## the most-requested thing from anyone running more than one. See [DotBanStore].
@export var store: DotBanStore = null

## Audit log, if one is attached. Every ban and unban is recorded there too.
var audit: DotAuditLog = null

var _refresh_timer: Timer = null

## key -> ban dictionary. Keys are [code]uid:<uid>[/code] or [code]ip:<address>[/code].
var _bans: Dictionary = {}

var _dirty: bool = false
var _sweep_timer: Timer = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	DotRegistry.register(SERVICE, self)

	if config != null:
		await load_bans()

	# Expired bans are dropped periodically so the file does not grow without
	# bound, but expiry is also checked on read — a ban that has expired but not
	# been swept must not still block anyone.
	_sweep_timer = Timer.new()
	_sweep_timer.wait_time = 300.0
	_sweep_timer.autostart = true
	_sweep_timer.timeout.connect(_sweep)
	add_child(_sweep_timer)


func _exit_tree() -> void:
	if _dirty:
		save_bans()
	DotRegistry.unregister_instance(SERVICE, self)


# --- Keys ------------------------------------------------------------------

static func uid_key(uid: String) -> String:
	return "uid:%s" % uid


static func ip_key(address: String) -> String:
	return "ip:%s" % normalise_address(address)


## Strips a port and normalises an address for comparison.
##
## Peer addresses arrive with ports attached and in varying IPv6 forms; without
## normalising, a ban on [code]1.2.3.4[/code] would not match
## [code]1.2.3.4:51234[/code].
static func normalise_address(address: String) -> String:
	var parts := DotTransport.normalise_address(address, 0)
	var host := str(parts["host"])
	return host if host != "" else address


# --- Checking --------------------------------------------------------------

## Whether an account is banned. Returns the ban when it is.
func check_uid(uid: String) -> DotResult:
	if uid == "":
		return DotResult.success(null)
	return _check(uid_key(uid))


## Whether an address is banned.
func check_address(address: String) -> DotResult:
	if address == "":
		return DotResult.success(null)
	return _check(ip_key(address))


## Checks both, for a session that has just authenticated.
##
## Returns a failure carrying a player-facing message when either matches, so the
## caller can reject with something the player can act on — which for a temporary
## ban means telling them when it lifts.
func check_session(session: DotClientSession) -> DotResult:
	var by_address := check_address(session.address)
	if not by_address.ok:
		return by_address

	var by_uid := check_uid(session.uid())
	if not by_uid.ok:
		return by_uid

	return DotResult.success(null)


func _check(key: String) -> DotResult:
	if not _bans.has(key):
		return DotResult.success(null)

	var ban: Dictionary = _bans[key]
	var expires := int(ban.get("expires_at", 0))

	if expires > 0 and int(Time.get_unix_time_from_system()) >= expires:
		# Expired. Dropped on read so it cannot block anyone even if the sweep has
		# not run.
		_bans.erase(key)
		_dirty = true
		return DotResult.success(null)

	var err := DotError.make(
		DotError.CODE_FORBIDDEN,
		_player_message(ban),
		"ban %s, reason: %s" % [key, str(ban.get("reason", ""))]
	)
	err.context = ban

	return DotResult.failure(err)


## The message shown to the banned player.
##
## Includes the remaining time for a temporary ban: a player who does not know
## whether they are banned for ten minutes or forever will keep reconnecting, which
## is worse for the server than telling them.
func _player_message(ban: Dictionary) -> String:
	var reason := str(ban.get("reason", ""))
	var expires := int(ban.get("expires_at", 0))

	if expires <= 0:
		if reason != "":
			return "You are banned from this server: %s" % reason
		return "You are banned from this server."

	var remaining := expires - int(Time.get_unix_time_from_system())
	var window := format_duration(maxi(0, remaining))

	if reason != "":
		return "You are banned for %s: %s" % [window, reason]
	return "You are banned for %s." % window


# --- Adding ---------------------------------------------------------------

## Bans an account.
##
## [param duration_sec] of 0 is permanent. [param by] is the admin's label, recorded
## in the ban and the audit log — a ban with no attribution cannot be reviewed.
func ban_uid(
	uid: String,
	reason: String,
	duration_sec: int = 0,
	by: String = "console",
	name: String = ""
) -> DotResult:
	if uid.strip_edges() == "":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Cannot ban without an account id.",
			"the player may be a guest; ban their address instead"
		)

	return await _add(uid_key(uid), {
		"kind": "uid",
		"target": uid,
		"name": name,
		"reason": reason,
		"by": by,
		"created_at": int(Time.get_unix_time_from_system()),
		"expires_at": _expiry(duration_sec),
		"duration_sec": duration_sec,
	})


## Bans an address.
##
## Catches everybody behind that address, so it is the blunt instrument. Prefer
## [method ban_uid] for authenticated players.
func ban_address(
	address: String,
	reason: String,
	duration_sec: int = 0,
	by: String = "console",
	name: String = ""
) -> DotResult:
	var host := normalise_address(address)

	if host == "":
		return DotResult.fail(DotError.CODE_INVALID, "No address given.")

	# Banning loopback locks the operator out of their own listen server and is
	# almost always a mistyped argument.
	if host == "127.0.0.1" or host == "::1" or host == "localhost":
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Refusing to ban the loopback address.",
			"this would lock out local connections"
		)

	return await _add(ip_key(host), {
		"kind": "ip",
		"target": host,
		"name": name,
		"reason": reason,
		"by": by,
		"created_at": int(Time.get_unix_time_from_system()),
		"expires_at": _expiry(duration_sec),
		"duration_sec": duration_sec,
	})


## Bans a connected session by account, falling back to address.
##
## The right entry point for a `ban` command: it picks the precise ban when the
## player has an account and the blunt one when they do not, and says which it did.
func ban_session(
	session: DotClientSession,
	reason: String,
	duration_sec: int = 0,
	by: String = "console"
) -> DotResult:
	var uid := session.uid()

	if session.is_account() and uid != "":
		return await ban_uid(uid, reason, duration_sec, by, session.display_name)

	DotLog.info(
		CHANNEL,
		"no account to ban; banning the address instead",
		{"user": session.label()}
	)

	return await ban_address(
		session.address, reason, duration_sec, by, session.display_name
	)


func _add(key: String, ban: Dictionary) -> DotResult:
	# A read-only store must refuse before anything is recorded, or the ban appears
	# to work locally and vanishes on the next refresh.
	var written := await _store().put(key, ban)
	if not written.ok:
		return written.wrap("Could not record the ban.")

	var existing := _bans.has(key)
	_bans[key] = ban
	_dirty = true

	DotLog.info(
		CHANNEL,
		"ban updated" if existing else "ban added",
		{
			"key": key,
			"reason": ban["reason"],
			"by": ban["by"],
			"duration": "permanent" if int(ban["expires_at"]) == 0
				else format_duration(int(ban["duration_sec"])),
		}
	)

	if audit != null:
		audit.record("ban", str(ban["by"]), key, {
			"reason": ban["reason"],
			"duration_sec": ban["duration_sec"],
			"name": ban.get("name", ""),
		})

	save_bans()
	ban_added.emit(ban)

	return DotResult.success(ban)


static func _expiry(duration_sec: int) -> int:
	if duration_sec <= 0:
		return 0
	return int(Time.get_unix_time_from_system()) + duration_sec


# --- Removing -------------------------------------------------------------

## Lifts a ban by its key, or by a bare uid or address.
##
## Accepting all three because an operator reading a ban list sees keys, but one
## responding to an appeal has a uid.
func unban(key_or_target: String, by: String = "console") -> DotResult:
	var candidates := PackedStringArray([
		key_or_target,
		uid_key(key_or_target),
		ip_key(key_or_target),
	])

	for key in candidates:
		if _bans.has(key):
			var removed := await _store().remove(key)
			if not removed.ok:
				return removed.wrap("Could not lift the ban.")

			_bans.erase(key)
			_dirty = true

			DotLog.info(CHANNEL, "ban lifted", {"key": key, "by": by})

			if audit != null:
				audit.record("unban", by, key, {})

			save_bans()
			ban_removed.emit(key)

			return DotResult.success(key)

	return DotResult.fail(
		DotError.CODE_INVALID, "No ban found for '%s'." % key_or_target
	)


## Removes expired bans from the in-memory set.
##
## Local only: a shared [DotBanStore] owns its own expiry, and having every server in
## a group race to delete the same expired rows would be pointless write traffic.
## Expired bans are refused on read regardless — see [method _check].
func _sweep() -> void:
	var now := int(Time.get_unix_time_from_system())
	var expired: Array = []

	for key in _bans:
		var expires := int((_bans[key] as Dictionary).get("expires_at", 0))
		if expires > 0 and now >= expires:
			expired.append(key)

	if expired.is_empty():
		return

	for key in expired:
		_bans.erase(key)

	_dirty = true
	save_bans()

	DotLog.debug(CHANNEL, "expired bans removed", {"count": expired.size()})


# --- Persistence ----------------------------------------------------------

## The store, creating the default file store if none was assigned.
func _store() -> DotBanStore:
	if store == null:
		store = DotBanStore.FileStore.new(config.bans_path)
	return store


func load_bans() -> DotResult:
	var loaded := await _store().load_bans()

	if not loaded.ok:
		# A ban list that cannot be read must be loud, and must NOT clear what is
		# already in force — silently starting with no bans readmits everyone who
		# was ever removed. Keeping the previous set is the safe failure.
		DotLog.error(
			CHANNEL,
			"could not load the ban list; keeping %d ban(s) already in force"
				% _bans.size(),
			{"store": _store().store_name(), "detail": loaded.error.detail}
		)
		return loaded

	_bans = loaded.value

	DotLog.info(
		CHANNEL,
		"bans loaded",
		{"count": _bans.size(), "store": _store().store_name()}
	)

	return DotResult.success(_bans.size())


## Re-reads bans changed elsewhere. Only meaningful for a shared store.
func refresh_bans() -> DotResult:
	var refreshed := await _store().refresh()

	if not refreshed.ok:
		DotLog.warn(
			CHANNEL,
			"ban refresh failed; keeping the current list",
			{"detail": refreshed.error.message}
		)
		return refreshed

	var before := _bans.size()
	_bans = refreshed.value

	if _bans.size() != before:
		DotLog.info(
			CHANNEL,
			"ban list changed",
			{"was": before, "now": _bans.size()}
		)

	return DotResult.success(_bans.size())


func save_bans() -> DotResult:
	var target := _store()

	# The file store owns the whole document, so it is written wholesale; a custom
	# store persisted each ban as it was made and has nothing left to do here.
	if target is DotBanStore.FileStore:
		var written := (target as DotBanStore.FileStore).write_all(_bans)
		if written.ok:
			_dirty = false
		return written

	_dirty = false
	return DotResult.success(_bans.size())


# --- Queries --------------------------------------------------------------

func count() -> int:
	return _bans.size()


func all_bans() -> Dictionary:
	return _bans


## Bans matching a substring of target, name or reason.
func search(query: String) -> Array:
	var out: Array = []
	var needle := query.to_lower()

	for key in _bans:
		var ban: Dictionary = _bans[key]
		var haystack := "%s %s %s" % [
			str(ban.get("target", "")),
			str(ban.get("name", "")),
			str(ban.get("reason", "")),
		]
		if haystack.to_lower().contains(needle):
			out.append(ban)

	return out


## A duration in a form an operator reads without counting zeroes.
static func format_duration(seconds: int) -> String:
	if seconds <= 0:
		return "permanent"
	if seconds < 60:
		return "%ds" % seconds
	if seconds < 3600:
		return "%dm" % (seconds / 60)
	if seconds < 86400:
		return "%dh" % (seconds / 3600)
	return "%dd" % (seconds / 86400)


## Parses a duration like [code]30m[/code], [code]2h[/code], [code]7d[/code].
##
## A bare number is minutes, because that is what admins already have in their
## fingers from every other server they have run. [code]0[/code] and
## [code]perm[/code] are permanent.
static func parse_duration(text: String) -> int:
	var s := text.strip_edges().to_lower()

	if s == "" or s == "0" or s == "perm" or s == "permanent" or s == "forever":
		return 0

	if s.is_valid_int():
		return s.to_int() * 60

	var unit := s[s.length() - 1]
	var value := s.substr(0, s.length() - 1)

	if not value.is_valid_float():
		return -1

	var n := value.to_float()

	match unit:
		"s": return int(n)
		"m": return int(n * 60.0)
		"h": return int(n * 3600.0)
		"d": return int(n * 86400.0)
		"w": return int(n * 604800.0)
		_: return -1


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if _bans.is_empty():
		out.append("no bans")
		return out

	var now := int(Time.get_unix_time_from_system())

	for key in _bans:
		var ban: Dictionary = _bans[key]
		var expires := int(ban.get("expires_at", 0))
		var remaining := "permanent" if expires == 0 else format_duration(
			maxi(0, expires - now)
		)

		out.append("%-40s %-10s %-16s %s" % [
			key,
			remaining,
			str(ban.get("by", "")).substr(0, 16),
			str(ban.get("reason", "")),
		])

	return out
