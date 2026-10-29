class_name DotClientSession
extends RefCounted

## One connected client and its signon: CONNECTING, AUTHENTICATING, PROFILE, DOWNLOADING,
## LOADING, SPAWNED, or REJECTED / DISCONNECTED from any stage. Stages fail and time out
## separately so a stuck client can be told which; "connecting" alone is unsupportable.

enum State {
	## Transport connected, nothing known about them yet.
	CONNECTING,
	## Waiting for, or checking, a credential.
	AUTHENTICATING,
	## Fetching the current game's content via dot-cloud.
	DOWNLOADING,
	## Content present; loading the game scene.
	LOADING,
	## In the game and receiving state.
	SPAWNED,
	## Refused. [member reject_reason] says why; the peer is about to be closed.
	REJECTED,
	## Gone.
	DISCONNECTED,
	## Authenticated and held by a module before any content is sent; see
	## [method DotServer.hold_profile]. Last in the enum, not in signon order, because a
	## state is stored as its number elsewhere (replays); the order is [method _can_transition].
	PROFILE,
}

## Server-local sequential id, small and stable for the session ([code]kickid 3[/code]).
## Not the transport's peer id (reused) or the account uid (long).
var userid: int = 0

## Transport-level peer id, as [MultiplayerPeer] knows it.
var peer_id: int = 0

var state: State = State.CONNECTING

## Set when [member state] is [constant State.REJECTED].
var reject_reason: String = ""

## Identity from dot-auth once authenticated, else null. Typed loosely: dot-server
## does not depend on dot-auth.
var identity: Object = null

## Name shown in chat and `status`; never used for authorisation.
var display_name: String = "unnamed"

var address: String = ""

## Sent in this connection's challenge; a connect ticket bound to it is refused on any other.
var ticket_nonce: String = ""

## What kind of client this is -- `web`, `desktop` or `mobile` -- as it said at signon.
## Empty for a shell exported before clients said. See [method DotServer.platform_refusal_for].
var platform: String = ""

## Admin permission flags, resolved once at authentication and cached: a lookup can hit
## a file or remote source, and per-message lookups would let chat make the server work.
var permissions: PackedStringArray = PackedStringArray()

var immunity: int = 0

## The admin groups this player is in, by name. Kept besides the flags because a game
## wants to know who somebody IS (a "vip" group), and a role is a group name, not flags.
var groups: PackedStringArray = PackedStringArray()

## Unix seconds when the transport connected.
var connected_at: int = 0

## Unix seconds when they reached [constant State.SPAWNED]. 0 if never.
var spawned_at: int = 0

## Milliseconds since the last packet from this client.
var last_seen_ms: int = 0

## Round-trip time in milliseconds, -1 when unknown.
var ping_ms: int = -1

## Whether this client is holding its scoreboard open, and so is sent the roster. See
## [method DotServer.scoreboard_snapshot].
var wants_scoreboard: bool = false

## Whether the client said its page went into the background. A hidden tab stops the main
## loop, so heartbeats stop on a healthy socket and `sv_timeout` would drop it. Cleared by
## the next packet; see [member background_grace_sec].
var backgrounded: bool = false

## Seconds of silence allowed while [member backgrounded], clamped to the server's
## [code]sv_background_grace[/code]. 0 means the normal timeout. The client asks, the
## server decides: a self-set grace would hold a slot on a full server.
var background_grace_sec: float = 0.0

## Score, for `status` output and roster reporting. The game sets this.
var score: int = 0

## Who holds this session in [constant State.PROFILE], by the name each gave
## [method DotServer.hold_profile]; it leaves when the last releases. Names, not a count,
## so a double release cannot let the player in and `status` can say who is waited on.
var profile_holds: PackedStringArray = PackedStringArray()

## Content sync progress, 0..1. -1 when not downloading.
var content_progress: float = -1.0

## Content set this client has confirmed it has.
var content_key: String = ""

## Whether they may speak in chat.
var muted: bool = false

## Whether they may use text chat specifically. Usually called a gag.
var gagged: bool = false

## When a mute or gag expires, in Unix seconds. 0 means indefinite.
var mute_expires_at: int = 0

## Free-form per-session storage for game code and modules.
var data: Dictionary = {}

## Whether this client occupies a reserved slot.
var used_reserved_slot: bool = false

## Whether no transport peer is behind this session: a bot, a listen server's own player,
## a test. These still count as players but must never be sent a packet. See
## [method DotServer.adopt_session].
var local: bool = false

var _state_entered_ms: int = 0


func _init(p_userid: int = 0, p_peer_id: int = 0) -> void:
	userid = p_userid
	peer_id = p_peer_id
	connected_at = int(Time.get_unix_time_from_system())
	last_seen_ms = Time.get_ticks_msec()
	_state_entered_ms = Time.get_ticks_msec()



## Moves to a new state. Returns false when the transition is not allowed. Checking
## catches the ordering bugs of a join flow, such as a spawn before content finished.
func transition_to(new_state: State) -> bool:
	if state == new_state:
		return true

	if not _can_transition(state, new_state):
		DotLog.warn(
			"session",
			"invalid state transition",
			{
				"user": label(),
				"from": state_name(),
				"to": State.keys()[new_state],
			}
		)
		return false

	state = new_state
	_state_entered_ms = Time.get_ticks_msec()

	# A hold belongs to the stage. One left over would read as "waiting on X" in status
	# for a player who is in the game.
	if new_state != State.PROFILE:
		profile_holds = PackedStringArray()

	if new_state == State.SPAWNED and spawned_at == 0:
		spawned_at = int(Time.get_unix_time_from_system())

	return true


static func _can_transition(from: State, to: State) -> bool:
	# Terminal states go nowhere. Anything can be rejected or disconnected.
	if from == State.DISCONNECTED:
		return false
	if to == State.DISCONNECTED or to == State.REJECTED:
		return true
	if from == State.REJECTED:
		return false

	match from:
		State.CONNECTING:
			return to == State.AUTHENTICATING
		State.AUTHENTICATING:
			# DotServer always goes through PROFILE; the direct moves stay legal for hosts
			# that drive the machine themselves. Content is optional: a game that needs
			# nothing new sends an authenticated client straight to loading.
			return to == State.PROFILE or to == State.DOWNLOADING or to == State.LOADING
		State.PROFILE:
			# Out to content only. Never straight to SPAWNED: a held player who sends
			# `game.loaded` early must not appear, which is the whole point of the stage.
			return to == State.DOWNLOADING or to == State.LOADING
		State.DOWNLOADING:
			return to == State.LOADING
		State.LOADING:
			# Back to downloading on a game change, as from SPAWNED: a `changelevel` does
			# not wait for joiners, and refusing this left a LOADING client in the old
			# game, counted as neither ready nor waiting, never told about the swap.
			return to == State.SPAWNED or to == State.DOWNLOADING
		State.SPAWNED:
			# Back to downloading on a game change, which is the whole point of
			# hot-swapping content while players are connected.
			return to == State.DOWNLOADING or to == State.LOADING

	return false


func state_name() -> String:
	return State.keys()[state]


## Seconds spent in the current state, for timeout sweeps and `status`.
func time_in_state() -> float:
	return float(Time.get_ticks_msec() - _state_entered_ms) / 1000.0


func is_active() -> bool:
	return state != State.DISCONNECTED and state != State.REJECTED


func is_playing() -> bool:
	return state == State.SPAWNED


func is_authenticated() -> bool:
	if identity == null:
		return false
	if identity.has_method("is_valid") and not identity.call("is_valid"):
		return false
	return true


## Whether this is an authenticated, non-guest account (a guest can return as another guest).
func is_account() -> bool:
	if not is_authenticated():
		return false
	if identity.has_method("get") and identity.get("is_guest") != null:
		return not bool(identity.get("is_guest"))
	return true


## Stable account identifier, or [code]""[/code] when there is none.
##
## The key bans, admin entries and audit records use. Never the display name.
func uid() -> String:
	if identity == null:
		return ""
	var value: Variant = identity.get("uid")
	return str(value) if value != null else ""


## The account name, or [code]""[/code]. Not [member display_name], which a guest picks;
## reports and appeals name somebody by it. Never used for authorisation (that is [method uid]).
func username() -> String:
	if identity == null:
		return ""
	var value: Variant = identity.get("username")
	return str(value) if value != null else ""


func reject(reason: String) -> void:
	reject_reason = reason
	transition_to(State.REJECTED)


func touch() -> void:
	last_seen_ms = Time.get_ticks_msec()


## Seconds since the last packet from this client.
func idle_seconds() -> float:
	return float(Time.get_ticks_msec() - last_seen_ms) / 1000.0


func connected_seconds() -> int:
	return int(Time.get_unix_time_from_system()) - connected_at



## Whether a mute or gag is in force, clearing it if expired. Checked lazily on read, where it matters.
func is_silenced() -> bool:
	if not (muted or gagged):
		return false

	if mute_expires_at > 0 and int(Time.get_unix_time_from_system()) >= mute_expires_at:
		muted = false
		gagged = false
		mute_expires_at = 0
		return false

	return true


func silence(voice: bool, text: bool, duration_sec: int = 0) -> void:
	muted = voice
	gagged = text
	mute_expires_at = 0
	if duration_sec > 0:
		mute_expires_at = int(Time.get_unix_time_from_system()) + duration_sec


func unsilence() -> void:
	muted = false
	gagged = false
	mute_expires_at = 0



func has_permission(flag: String) -> bool:
	return DotAdminFlags.granted(permissions, flag)


func is_admin() -> bool:
	return not permissions.is_empty()


## Builds a [DotCmdContext] for a command this client is running.
func make_context(
	command: String,
	args: PackedStringArray,
	source: DotCmdContext.Source,
	reply_sink: Callable = Callable()
) -> DotCmdContext:
	var ctx := DotCmdContext.new()
	ctx.source = source
	ctx.command = command
	ctx.args = args
	ctx.identity = identity
	ctx.session = self
	ctx.permissions = permissions
	ctx.immunity = immunity
	ctx.address = address
	ctx.reply_sink = reply_sink
	return ctx



## Short label for logs: userid (what an admin types), name (what players see), uid (who it was).
func label() -> String:
	var account := uid()
	if account != "":
		return "#%d %s <%s>" % [userid, display_name, account]
	return "#%d %s" % [userid, display_name]


## A `status`-style line.
func status_line() -> String:
	var duration := connected_seconds()
	var clock := "%d:%02d" % [duration / 60, duration % 60]

	var flags := ""
	if is_admin():
		flags += "A"
	if is_silenced():
		flags += "M"
	if used_reserved_slot:
		flags += "R"
	if backgrounded:
		flags += "B"

	return "# %-4d %-20s %-10s %-6s %-5s %-4s %-22s %s" % [
		userid,
		display_name.substr(0, 20),
		state_name().to_lower(),
		clock,
		str(ping_ms) if ping_ms >= 0 else "-",
		flags,
		uid() if uid() != "" else "-",
		address,
	]


func describe() -> Dictionary:
	return {
		"userid": userid,
		"peer_id": peer_id,
		"name": display_name,
		"uid": uid(),
		"state": state_name(),
		"address": address,
		"platform": platform,
		"connected": connected_seconds(),
		"ping": ping_ms,
		"admin": is_admin(),
		"permissions": Array(permissions),
		"immunity": immunity,
		"silenced": is_silenced(),
		"backgrounded": backgrounded,
		"background_grace": background_grace_sec,
		"content": content_key,
		"progress": content_progress,
		"profile_holds": Array(profile_holds),
	}


## The shape [code]DotBackboneClient.report_users[/code] expects.
func to_roster_entry() -> Dictionary:
	return {
		"name": display_name,
		"score": score,
		"seconds": connected_seconds(),
	}


func _to_string() -> String:
	return "DotClientSession(%s, %s)" % [label(), state_name()]
