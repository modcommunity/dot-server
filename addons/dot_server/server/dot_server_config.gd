@tool
class_name DotServerConfig
extends DotConfig

## Everything configurable about the server itself.
##
## Layered like every [DotConfig]: exported defaults, then a JSON file, then
## [code]DOT_SERVER_*[/code] environment variables, then [code]--sv-*[/code]
## arguments.
##
## Note that most of these are also exposed as [DotConVar]s by [DotServer], so an
## operator can change at runtime whatever is safe to change at runtime. This
## resource is the boot-time source; cvars are the live view. Anything that cannot
## be changed on a running server carries
## [constant DotConVar.FLAG_STARTUP_ONLY] there.

@export_group("Identity")

## Name shown in server listings and `status`.
@export var hostname: String = "A dot server"

## Identifier this server is known by.
##
## Used as the audience for dot-auth connect tickets, so it must match what the
## issuer mints for — see [member DotAuthConfig.server_id].
@export var server_id: String = ""

## Free-form tags for listings.
@export var tags: PackedStringArray = PackedStringArray()

@export_group("Network")

## Port to listen on.
##
## 0 lets the OS pick a free one, which is what you want for tests and for running
## several instances on one box without assigning ports by hand. A server on an
## ephemeral port cannot be found by anything that was told a fixed address, so it
## is not useful for a real deployment — and it requires an explicit
## [member rcon_port], since there is no fixed port to derive one from.
@export_range(0, 65535, 1) var port: int = 27015

## Interface to bind. [code]*[/code] means every interface.
@export var bind_address: String = "*"

## Transport. Defaults to [DotTransportAuto], which prefers WebSocket so browser
## clients can connect.
##
## [b]This is the setting most likely to be wrong.[/b] A server that picks ENet
## cannot accept browser clients at all, and nothing about the server looks
## misconfigured when that happens. See [DotTransportAuto].
@export var transport: DotTransport = null

@export_range(1, 4096, 1) var max_players: int = 32

## Slots kept for players with the [constant DotAdminFlags.RESERVATION] flag.
##
## Counted inside [member max_players], as every server does it: a 32-slot server with 2
## reserved fills up for the public at 30.
@export_range(0, 64, 1) var reserved_slots: int = 0

## Password clients must send. Empty means none.
@export var password: String = ""

## Server ticks per second.
##
## The rate at which authoritative state is stepped and broadcast. Higher costs CPU
## and bandwidth on the server and reduces input latency for players.
@export_range(10, 240, 1) var tickrate: int = 60

@export_group("Timeouts")

## Seconds a client may spend authenticating before it is dropped.
@export_range(5.0, 300.0, 5.0) var auth_timeout_sec: float = 60.0

## Seconds a client may spend downloading content.
##
## Generous: this covers a full content download on whatever connection the player
## has, and a timeout that fires on a working download is worse than no timeout.
@export_range(30.0, 7200.0, 30.0) var download_timeout_sec: float = 1800.0

## Seconds a client may spend loading after content is present.
@export_range(5.0, 600.0, 5.0) var load_timeout_sec: float = 120.0

## Seconds without a packet before a spawned client is dropped.
@export_range(5.0, 600.0, 5.0) var client_timeout_sec: float = 60.0

@export_group("Hibernation")

## Reduce tick processing when nobody is connected.
##
## An empty dedicated server has nothing to simulate, and a box hosting twelve of
## them should not spend twelve cores on it. The familiar `sv_hibernate_when_empty`.
@export var hibernate_when_empty: bool = true

## Ticks per second while hibernating.
@export_range(1, 60, 1) var hibernate_tickrate: int = 5

@export_group("RCON")

## Password for remote console. Empty disables RCON entirely.
##
## [b]Empty means disabled, not "no password".[/b] An RCON listener with no password
## is a remote shell, so there is no configuration that produces one.
@export var rcon_password: String = ""

## TCP port for RCON. 0 uses [member port] + 1.
@export var rcon_port: int = 0

## Also serve RCON over WebSocket, for browser-based admin panels.
##
## Same authentication and rate limits; only the framing differs.
@export var rcon_websocket: bool = false

@export var rcon_websocket_port: int = 0

## Addresses allowed to use RCON. Empty allows any.
##
## Worth populating. It is the control that survives a leaked password.
@export var rcon_allowed_addresses: PackedStringArray = PackedStringArray()

## Failed RCON authentications before an address is locked out.
@export_range(1, 100, 1) var rcon_max_failures: int = 5

## Seconds an address is locked out for.
@export_range(10.0, 86400.0, 10.0) var rcon_lockout_sec: float = 600.0

@export_group("Query")

## Answer the dot query protocol.
##
## On by default, and safe on by default: every UDP query is answered with an
## address-bound challenge before any payload is built, so the listener cannot be
## used to attack somebody else, and it is rate limited per address on top of that.
## See [DotQueryServer].
##
## A server nobody can query is a server nobody can find.
@export var query_enabled: bool = true

## UDP port for queries. 0 uses [member a2s_port]'s effective value — which is
## [member port] — so both protocols share one socket and both answer where a
## tracker looks.
##
## They are told apart by their first four bytes. Set this only when a UDP game
## transport (ENet) already holds the game port.
@export var query_port: int = 0

## Also serve queries over WebSocket, as plain JSON.
##
## What an in-browser server browser needs: a web page cannot open a UDP socket,
## so it can never speak A2S, at any price. Off by default because it is a second
## listener, and a deployment with no web front end has no use for it.
@export var query_websocket: bool = false

## TCP port for the WebSocket query listener. 0 uses [member port] + 3.
@export var query_websocket_port: int = 0

## How much of the player list a query may see.
##
## [code]full[/code] adds userid, ping, bot and signon state to the name, score and
## duration A2S would give ([code]names[/code]). [code]count[/code] publishes the
## number but no list; [code]none[/code] refuses the section. Never includes an
## account uid at any setting — see [DotQuerySource].
@export_enum("full", "names", "count", "none")
var query_player_detail: String = "full"

## Publish server variables in the [code]rules[/code] section.
@export var query_rules: bool = true

## Extra cvars to publish beyond the notify/replicated ones.
##
## Protected and hidden cvars are refused here regardless — naming one does not
## make it publishable.
@export var query_extra_rules: PackedStringArray = PackedStringArray()

## Seconds a challenge cookie stays valid. The real window is up to twice this.
@export_range(5.0, 300.0, 5.0) var query_challenge_ttl_sec: float = 30.0

## Queries answered per address per second, sustained.
@export_range(0.1, 100.0, 0.1) var query_rate_per_second: float = 2.0

## Queries an address may burst before the sustained rate applies.
@export_range(1.0, 200.0, 1.0) var query_rate_burst: float = 10.0

## Seconds a snapshot is reused before it is rebuilt.
##
## The control that stops a query flood costing CPU: a thousand queries in a second
## cost one walk of the session table, not a thousand.
@export_range(0.0, 60.0, 0.1) var query_cache_sec: float = 1.0

## Most players listed in one response.
@export_range(1, 4096, 1) var query_max_players_listed: int = 128

## Shared secret for signing query responses. Empty disables signing.
##
## For a listing service that must know this server really said this, rather than
## somebody forging a busy server to climb a list.
@export var query_secret: String = ""

@export_group("A2S")

## Answer the A2S query protocol as well.
##
## Off by default. A2S is a compatibility shim for twenty years of trackers,
## chat bots and uptime monitors that speak nothing else — worth having when
## being listed matters, and a strictly worse protocol otherwise. See
## [DotA2SServer].
@export var a2s_enabled: bool = false

## UDP port for A2S. 0 uses [member port], which is where every tracker looks.
@export var a2s_port: int = 0

## Application id reported in A2S_INFO. 0 for a game that has none.
@export var a2s_app_id: int = 0

## Short folder name, as A2S calls it. Slug-ish, and shown by some tools.
@export var a2s_game_folder: String = "dot"

## Game description shown in listings. Empty uses the current game's display name.
@export var a2s_game_description: String = ""

@export_group("Configuration files")

## Config executed at boot, before the listener opens.
@export var startup_config: String = "server.cfg"

## Config executed after the listener opens.
@export var autoexec_config: String = "autoexec.cfg"

## Config executed after each game change, for per-game overrides.
@export var game_config_prefix: String = "game_"

@export_group("Admin")

## File defining admins and groups.
@export var admins_path: String = "user://cfg/admins.json"

## Reload the admin file when it changes on disk.
##
## Lets an operator promote somebody without restarting. Cheap: a modification-time
## check on a timer.
@export var admins_auto_reload: bool = true

@export_group("Moderation")

@export var bans_path: String = "user://cfg/bans.json"

## Audit log of every administrative action.
##
## Separate from the general log because it is the record a moderation dispute is
## resolved from, and it must not be rotated away with routine noise.
@export var audit_log_path: String = "user://logs/audit.jsonl"

## Announce administrative actions in chat.
##
## On by default: visible moderation is a deterrent, and players who see a cheater
## removed stop reporting them.
@export var announce_admin_actions: bool = true

## Most simultaneous connections allowed from one address. 0 removes the limit.
##
## Neither a ban nor the connect rate limiter covers this: connections that arrive
## slowly, from nobody banned, still let one machine hold every slot on a small server.
## See [DotAddressGuard], which also explains why the default is off — a household, a
## university and everybody behind CGNAT are each one address.
@export_range(0, 64, 1) var max_connections_per_ip: int = 0

## Addresses the per-address limit never applies to, on top of loopback.
##
## For a LAN party, an office, or a known NAT everybody plays from.
@export var connection_limit_exempt_addresses: PackedStringArray = PackedStringArray()

@export_group("Chat")

## Prefixes that turn a chat message into a command.
@export var chat_command_prefixes: PackedStringArray = PackedStringArray(["!", "/"])

## Chat messages allowed per player per minute.
@export_range(1, 240, 1) var chat_rate_per_minute: int = 20

## Longest chat message accepted, in characters.
@export_range(16, 2048, 16) var chat_max_length: int = 256

@export_group("Content")

## Manifest URL for the game clients should load on connect. Empty means none.
@export var content_manifest_url: String = ""

## Let clients fetch content over the game connection when they cannot reach the
## content host.
##
## Costs this server's bandwidth. See [DotCloudSourceNetchan].
@export var allow_netchan_content: bool = true

## Bytes per in-band content chunk.
@export_range(1024, 262144, 1024) var netchan_chunk_bytes: int = 65536

## In-band content chunks a client may request per second.
##
## The limit that stops an in-band download from starving gameplay traffic, and
## stops a client from using the content channel as a bandwidth amplifier.
##
## [b]Reserved.[/b] The server does not serve chunks yet — see "Things deliberately
## not here" in CLAUDE.md — so this and [member netchan_chunk_bytes] are sent to
## clients and enforced by nothing. Declared honestly rather than quietly ignored.
@export_range(1, 512, 1) var netchan_chunks_per_second: int = 32


func env_prefix() -> String:
	return "DOT_SERVER_"


func cli_prefix() -> String:
	return "--sv-"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["rcon_password", "password", "query_secret"])


func validate() -> DotResult:
	if port < 0 or port > 65535:
		return DotResult.fail(
			DotError.CODE_INVALID, "port must be between 0 and 65535."
		)

	# With an ephemeral game port there is nothing to derive an RCON port from, and
	# port + 1 would be 1 — privileged, and almost certainly not what was meant.
	if port == 0 and rcon_password != "" and rcon_port <= 0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"An explicit rcon_port is required when port is 0.",
			"there is no fixed game port to derive one from"
		)

	if reserved_slots >= max_players:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"reserved_slots must be fewer than max_players.",
			"otherwise no ordinary player can ever join"
		)

	if tickrate < 1:
		return DotResult.fail(
			DotError.CODE_INVALID, "tickrate must be at least 1."
		)

	if rcon_password != "" and rcon_password.length() < 8:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"rcon_password must be at least 8 characters.",
			"RCON is a remote shell; a short password is guessed in minutes"
		)

	if effective_rcon_port() == port:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The RCON port must differ from the game port.",
			"both are %d" % port
		)

	if not ["full", "names", "count", "none"].has(query_player_detail):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"query_player_detail must be full, names, count or none.",
			"got '%s'" % query_player_detail
		)

	# Only the TCP listeners can collide with each other. The query and A2S ports
	# are UDP, and sharing a number with a TCP listener is not a conflict — sharing
	# it with the game port is exactly what an ENet deployment must avoid, and that
	# is caught at bind time where the transport is actually known.
	if query_enabled and query_websocket:
		var ws_port := effective_query_websocket_port()
		for taken in [
			["the game port", port],
			["the RCON port", effective_rcon_port()],
			["the RCON WebSocket port", effective_rcon_websocket_port() if rcon_websocket else 0],
		]:
			if ws_port > 0 and ws_port == int(taken[1]):
				return DotResult.fail(
					DotError.CODE_INVALID,
					"The query WebSocket port must differ from %s." % str(taken[0]),
					"both are %d" % ws_port
				)

	return DotResult.success(null)


func warn_about_risky_settings() -> void:
	if rcon_password != "" and rcon_allowed_addresses.is_empty():
		DotLog.warn(
			"server",
			"RCON is enabled with no address allow-list — the password is the "
			+ "only thing protecting it",
			{"setting": "rcon_allowed_addresses"}
		)

	# An entry that can never match is worse than no entry: the operator believes
	# they have an allow-list, and the only symptom is being refused by their own
	# console. "192.168" is the shape that produces it — a subnet prefix written
	# without the trailing dot that makes it one.
	for raw in rcon_allowed_addresses:
		var entry := DotBanManager.normalise_address(raw)
		if entry == "":
			DotLog.warn(
				"server",
				"an RCON allow-list entry is empty and matches nothing",
				{"setting": "rcon_allowed_addresses"}
			)
			continue

		# A trailing dot is a deliberate prefix; a colon is IPv6; four octets is a
		# whole address. None of those is the mistake being looked for.
		if entry.ends_with(".") or entry.contains(":"):
			continue

		var parts := entry.split(".", false)
		if parts.size() >= 4:
			continue

		var numeric := not parts.is_empty()
		for part in parts:
			if not part.is_valid_int():
				numeric = false
				break

		if numeric:
			DotLog.warn(
				"server",
				"an RCON allow-list entry looks like a subnet prefix but does "
				+ "not end in a dot, so it matches nothing",
				{"entry": raw, "did you mean": entry + "."}
			)

	if bind_address == "*" and password == "":
		DotLog.info(
			"server",
			"listening on every interface with no password (a public server)"
		)

	if a2s_enabled and query_player_detail == "full":
		# A2S publishes names, scores and connection times to anyone who asks, and
		# always has. Worth saying out loud once, because an operator who turned
		# A2S on to be listed may not have meant to publish a roster.
		DotLog.info(
			"server",
			"A2S is enabled: player names, scores and connection times are public",
			{"setting": "query_player_detail"}
		)


func effective_rcon_port() -> int:
	return rcon_port if rcon_port > 0 else port + 1


func effective_rcon_websocket_port() -> int:
	return rcon_websocket_port if rcon_websocket_port > 0 else effective_rcon_port() + 1


## UDP port A2S answers on. 0 when there is none to derive.
##
## Defaults to the game port, because that is the only port a tracker will try.
## With a UDP game transport that port is already taken and an explicit one is
## required; the bind failure says so.
func effective_a2s_port() -> int:
	if a2s_port > 0:
		return a2s_port
	return port


## UDP port the dot query protocol answers on. 0 when there is none to derive.
##
## The same port as A2S by default: the two are told apart by their first four
## bytes, so one socket serves both and a tracker that found this server over A2S
## can be pointed at the better protocol without being given a second address.
func effective_query_port() -> int:
	if query_port > 0:
		return query_port
	return effective_a2s_port()


## TCP port the WebSocket query listener answers on. 0 when there is none to derive.
func effective_query_websocket_port() -> int:
	if query_websocket_port > 0:
		return query_websocket_port
	# +1 and +2 are RCON's. A derived port has to come from somewhere, and the
	# family already derives RCON's from the game port the same way.
	return port + 3 if port > 0 else 0


## Slots available to players without a reservation.
func public_slots() -> int:
	return maxi(0, max_players - reserved_slots)


## The transport, creating a default if none was configured.
func resolve_transport() -> DotTransport:
	if transport == null:
		var auto := DotTransportAuto.new()
		# Default to WebSocket so browser clients work. A native-only deployment
		# turns this off and gets ENet's unreliable channels.
		auto.require_web_clients = true
		transport = auto

	transport.max_clients = max_players
	return transport
