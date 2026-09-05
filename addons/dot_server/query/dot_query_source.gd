@tool
class_name DotQuerySource
extends Node

## Builds the snapshot both query protocols answer from, and caches it.
##
## Registered as [code]dot_query_source[/code] in [DotRegistry], so a game can find
## it and add a [DotQueryProvider] without being handed a reference.
##
## [b]The cache is a security control, not an optimisation.[/b] Gathering a snapshot
## walks every session and every cvar. Doing that per packet means a querier can
## make the server do real work by sending small packets, which is the cheapest
## denial of service there is — and unlike a flood of game traffic it does not even
## need a connection. Rebuilding at most once per
## [member DotServerConfig.query_cache_sec] puts a ceiling on it: a thousand queries
## a second cost one rebuild and a thousand serialisations of an already-built
## dictionary.
##
## Nothing here opens a socket. [DotQueryServer] and [DotA2SServer] do that, and
## either, both or neither may be running.

const CHANNEL := "query"
const SERVICE := &"dot_query_source"

## Player detail policies, in decreasing order of what they reveal.
const DETAIL_FULL := "full"
const DETAIL_NAMES := "names"
const DETAIL_COUNT := "count"
const DETAIL_NONE := "none"

signal snapshot_rebuilt(snapshot: DotQuerySnapshot)

var server: DotServer = null

## Registered providers, in registration order.
var _providers: Array[Object] = []

var _snapshot: DotQuerySnapshot = null
var _built_ms: int = 0
var _rev: int = 0
var _last_etag: String = ""


func setup(p_server: DotServer) -> void:
	server = p_server
	DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


# --- Providers -------------------------------------------------------------

## Registers a provider. Validated now so a mistake is a startup error.
func add_provider(provider: Object) -> DotResult:
	var valid := DotQueryProvider.validate(provider)
	if not valid.ok:
		DotLog.error(
			CHANNEL, "refused a query provider", {"detail": valid.error.message}
		)
		return valid

	if _providers.has(provider):
		return DotResult.fail(
			DotError.CODE_STATE,
			"That query provider is already registered.",
			DotQueryProvider.name_of(provider)
		)

	_providers.append(provider)
	invalidate()

	DotLog.debug(
		CHANNEL,
		"query provider added",
		{"provider": DotQueryProvider.name_of(provider)}
	)

	return DotResult.success(provider)


func remove_provider(provider: Object) -> void:
	if not _providers.has(provider):
		return
	_providers.erase(provider)
	invalidate()


func provider_names() -> PackedStringArray:
	var out := PackedStringArray()
	for provider in _providers:
		out.append(DotQueryProvider.name_of(provider))
	return out


# --- Snapshots -------------------------------------------------------------

## The current snapshot, rebuilding it if the cache has expired.
func snapshot(force: bool = false) -> DotQuerySnapshot:
	var now := Time.get_ticks_msec()
	var cache_ms := int(maxf(0.0, _config().query_cache_sec) * 1000.0)

	if not force and _snapshot != null and now - _built_ms < cache_ms:
		return _snapshot

	_snapshot = _build()
	_built_ms = now
	snapshot_rebuilt.emit(_snapshot)
	return _snapshot


## Drops the cache, so the next query rebuilds.
##
## Worth calling after a game change or a scoring event a tracker should see
## promptly. Not required: the cache expires on its own.
func invalidate() -> void:
	_built_ms = 0


func revision() -> int:
	return _rev


func _build() -> DotQuerySnapshot:
	var snap := DotQuerySnapshot.new()

	snap.info = _build_info()
	snap.players = _build_players(snap)
	snap.rules = _build_rules()

	for provider in _providers:
		# A provider that throws would otherwise take the query listener down with
		# it, so each is called in isolation and a freed one is skipped rather than
		# dereferenced — a module unloaded without removing its provider is exactly
		# the case that produces one.
		if provider == null or not is_instance_valid(provider):
			continue
		DotQueryProvider.contribute_to(provider, snap)

	_stamp_revision(snap)
	return snap


## Assigns the revision, bumping it only when something meaningful changed.
##
## [b]Volatile fields are excluded from the hash on purpose.[/b] Uptime advances
## every second and per-player timers advance with it; hashing those would make
## every rebuild a new revision, and conditional polling — the whole reason the
## revision exists — would never once save a byte.
func _stamp_revision(snap: DotQuerySnapshot) -> void:
	var stable_info := snap.info.duplicate(true)
	stable_info.erase("uptime")

	var stable_players: Array = []
	for entry in snap.players:
		var player: Dictionary = (entry as Dictionary).duplicate(true)
		player.erase("duration")
		player.erase("ping")
		stable_players.append(player)

	var etag := DotHash.sha256_text(JSON.stringify({
		"info": stable_info,
		"players": stable_players,
		"rules": snap.rules,
		"game": snap.game,
	}))

	if etag != _last_etag:
		_rev += 1
		_last_etag = etag

	snap.rev = _rev
	snap.etag = etag


# --- Sections --------------------------------------------------------------

func _build_info() -> Dictionary:
	var config := _config()
	var console := server.console if server != null else null

	var sessions: Array[DotClientSession] = []
	var playing := 0
	if server != null:
		sessions = server.sessions()
		playing = server.player_count()

	var transport_name := ""
	var web_clients := false
	if server != null:
		var described := server.describe()
		transport_name = str(described.get("transport", ""))
		web_clients = bool(described.get("web_clients", false))

	var info := {
		"protocol": DotQueryProtocol.VERSION,
		"name": config.hostname,
		"server_id": config.server_id,
		"version": DotServer.VERSION,
		"map": server.games.current_content_id() if _has_games() else "",
		"game_id": server.games.current().game_id if _has_current_game() else "",
		"game": _game_description(),
		"folder": config.a2s_game_folder,
		"players": playing,
		# Overridden by any provider that knows better. Nothing in dot-server can:
		# a bot is a game concept and the server never sees one connect.
		"bots": 0,
		# The count A2S has no field for, and the one that tells an operator their
		# server is unreachable rather than empty: clients that are connecting but
		# have not spawned.
		"connecting": sessions.size() - playing,
		"max_players": config.max_players,
		"reserved_slots": config.reserved_slots,
		"visibility": "password" if config.password != "" else "public",
		"server_type": "dedicated" if DotPlatform.is_headless() else "listen",
		"os": _os_name(),
		"tags": Array(config.tags),
		"port": config.port,
		"tickrate": config.tickrate,
		"uptime": server.uptime_seconds() if server != null else 0,
		"state": server.state_name().to_lower() if server != null else "stopped",
		"transport": transport_name,
		"web_clients": web_clients,
		"secure": false,
	}

	# Advertised so a tracker that found this server through A2S on the game port
	# can discover the richer protocol without being told where it is.
	if config.query_enabled:
		info["query"] = {
			"protocol": DotQueryProtocol.MAGIC,
			"version": DotQueryProtocol.VERSION,
			"port": config.effective_query_port(),
			"websocket_port": config.effective_query_websocket_port() \
				if config.query_websocket else 0,
		}

	if _has_current_game():
		var descriptor := server.games.current()
		info["game_version"] = descriptor.version
		info["content"] = descriptor.manifest_url != ""

	if console != null:
		# Read through the console rather than the config: an operator who typed
		# `hostname "Something Else"` expects the listing to say so, and the config
		# is only the boot-time value.
		info["name"] = console.get_string("hostname", config.hostname)
		info["max_players"] = console.get_int("sv_maxplayers", config.max_players)
		info["visibility"] = "password" \
			if console.get_string("sv_password", "") != "" else "public"

	return info


func _build_players(snap: DotQuerySnapshot) -> Array:
	var config := _config()
	var detail := player_detail()

	if detail == DETAIL_NONE or detail == DETAIL_COUNT:
		return []

	if server == null:
		return []

	var out: Array = []
	var limit := maxi(1, config.query_max_players_listed)

	for session in server.playing_sessions():
		if out.size() >= limit:
			snap.mark_truncated(DotQuerySnapshot.SECTION_PLAYERS)
			break

		var entry := {
			"name": session.display_name,
			"score": session.score,
			"duration": session.connected_seconds(),
		}

		if detail == DETAIL_FULL:
			entry["userid"] = session.userid
			entry["ping"] = session.ping_ms
			entry["bot"] = false
			entry["state"] = session.state_name().to_lower()
			# Never the account uid. A query response is public, and dot-user's
			# whole point is that an operator cannot correlate their players across
			# servers — publishing the identifier to anyone who sends a datagram
			# would undo that from the other direction.

		out.append(entry)

	return out


func _build_rules() -> Dictionary:
	var config := _config()
	if not config.query_rules or server == null or server.console == null:
		return {}

	var console := server.console
	var out := {}

	for name in console.cvar_names():
		var cvar := console.find_cvar(name)
		if cvar == null:
			continue
		if not _rule_visible(cvar, config):
			continue
		out[name] = cvar.get_string()

	return out


## Whether a cvar may appear in a query response.
##
## [b]The refusals are not overridable.[/b] An operator naming a protected cvar in
## [member DotServerConfig.query_extra_rules] gets it refused, not published: the
## flag exists precisely because that value must never leave the server, and a
## config file is not a good enough reason to make an exception. Hidden cvars are
## implementation detail nobody outside benefits from.
static func _rule_visible(cvar: DotConVar, config: DotServerConfig) -> bool:
	if cvar.has_flag(DotConVar.FLAG_PROTECTED):
		return false
	if cvar.has_flag(DotConVar.FLAG_HIDDEN):
		return false

	if config.query_extra_rules.has(cvar.name):
		return true

	# Source publishes FCVAR_NOTIFY in A2S_RULES; these two flags are the same idea
	# — a variable whose value changes how the game plays, which is what somebody
	# deciding whether to join wants to know.
	return cvar.has_flag(DotConVar.FLAG_NOTIFY) \
		or cvar.has_flag(DotConVar.FLAG_REPLICATED)


# --- Signing ---------------------------------------------------------------

## Adds an HMAC over the response body when a shared secret is configured.
##
## For a listing service that must know the server really said this, rather than
## someone forging a well-populated server to climb a list. Same shape as the
## backbone's integration requests — timestamp, nonce, signature — because a site
## verifying both should not need two implementations.
##
## Off unless [member DotServerConfig.query_secret] is set: a signature nobody
## checks is cost with no benefit.
func sign(body: Dictionary) -> Dictionary:
	var secret := _config().query_secret
	if secret == "":
		return body

	var stamped := body.duplicate(true)
	var ts := int(Time.get_unix_time_from_system())
	var nonce := DotHash.random_hex(8)

	# Signed over the body with the auth block absent, so a verifier reproduces it
	# by removing the same block. Signing a canonicalisation the server then does
	# not send is the mistake dot-cloud made and shipped.
	var payload := "%d.%s.%s" % [ts, nonce, JSON.stringify(stamped)]

	stamped["auth"] = {
		"ts": ts,
		"nonce": nonce,
		"sig": DotHash.hmac_sha256_hex(secret, payload),
	}

	return stamped


# --- Helpers ---------------------------------------------------------------

## The player policy in force, preferring the live cvar over the boot config.
##
## An operator hiding the roster mid-incident types `sv_query_players none` and
## expects the next query to honour it, not the next restart.
func player_detail() -> String:
	if server != null and server.console != null:
		return server.console.get_string(
			"sv_query_players", _config().query_player_detail
		)
	return _config().query_player_detail


func _config() -> DotServerConfig:
	if server != null and server.config != null:
		return server.config
	return DotServerConfig.new()


func _has_games() -> bool:
	return server != null and server.games != null


func _has_current_game() -> bool:
	return _has_games() and server.games.current() != null


func _game_description() -> String:
	var config := _config()
	if config.a2s_game_description != "":
		return config.a2s_game_description
	if _has_current_game():
		var descriptor := server.games.current()
		if descriptor.display_name != "":
			return descriptor.display_name
	return config.a2s_game_folder


static func _os_name() -> String:
	var name := OS.get_name().to_lower()
	if name.contains("windows"):
		return "windows"
	if name.contains("macos") or name.contains("ios"):
		return "macos"
	if name.contains("android"):
		return "android"
	if name.contains("web"):
		return "web"
	return "linux"


func describe() -> Dictionary:
	var snap := snapshot()
	return {
		"rev": snap.rev,
		"providers": Array(provider_names()),
		"cache_sec": _config().query_cache_sec,
		"player_detail": player_detail(),
		"rules": snap.rules.size(),
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("providers   %s" % (
		", ".join(Array(provider_names())) if not _providers.is_empty() else "none"
	))
	out.append("cache       %.1fs" % _config().query_cache_sec)
	out.append("players     %s" % player_detail())
	out.append("")
	out.append_array(snapshot().describe_lines())
	return out
