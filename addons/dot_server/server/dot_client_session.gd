class_name DotClientSession
extends RefCounted

## One connected client, and how far through joining it is.
##
## [b]The signon state machine is the load-bearing part.[/b] Joining a dot-server
## is not one step — a client connects, proves who it is, downloads whatever content
## the current game needs, loads it, and only then exists in the world. Each stage
## can fail differently, each has its own timeout, and a client stuck in one needs
## to be told which. Every dedicated server that has this problem models it the
## same way, and for the same reason.
##
## [codeblock]
## CONNECTING -> AUTHENTICATING -> DOWNLOADING -> LOADING -> SPAWNED
##      \              \               \             \
##       ------------- REJECTED / DISCONNECTED -------------
## [/codeblock]
##
## A client that never leaves [constant State.DOWNLOADING] is on a slow connection;
## one stuck in [constant State.AUTHENTICATING] has a credential problem. Collapsing
## these into "connecting" is what makes a server impossible to support.

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
}

## Server-local sequential id — a userid, in the usual sense.
##
## Small and stable for the session's lifetime, which is what makes
## [code]kickid 3[/code] usable. Distinct from the transport's peer id (which can
## be large and is reused) and from the account uid (which is long).
var userid: int = 0

## Transport-level peer id, as [MultiplayerPeer] knows it.
var peer_id: int = 0

var state: State = State.CONNECTING

## Set when [member state] is [constant State.REJECTED].
var reject_reason: String = ""

## Identity from dot-auth, once authenticated. Null before that.
##
## Typed loosely because dot-server does not depend on dot-auth; holds a
## [code]DotAuthIdentity[/code] when that addon is installed.
var identity: Object = null

## Name shown in chat and `status`.
##
## Comes from the identity when authenticated, from the client's request when a
## guest. Never used for authorisation.
var display_name: String = "unnamed"

var address: String = ""

## Admin permission flags, resolved once at authentication.
##
## Cached rather than re-resolved per command: a permission lookup can hit a file
## or a remote source, and doing that on every chat message would be both slow and
## a way to make the server do work by talking.
var permissions: PackedStringArray = PackedStringArray()

var immunity: int = 0

## Unix seconds when the transport connected.
var connected_at: int = 0

## Unix seconds when they reached [constant State.SPAWNED]. 0 if never.
var spawned_at: int = 0

## Milliseconds since the last packet from this client.
var last_seen_ms: int = 0

## Round-trip time in milliseconds, -1 when unknown.
var ping_ms: int = -1

## Score, for `status` output and roster reporting. The game sets this.
var score: int = 0

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
##
## Keeps a game from having to maintain a parallel dictionary keyed by peer id and
## then keep it in sync with connect and disconnect.
var data: Dictionary = {}

## Whether this client occupies a reserved slot.
var used_reserved_slot: bool = false

## Whether this session has no transport peer behind it.
##
## True for anything the host adopted rather than the listener created — a server-side
## bot, a listen server's own player, a test. Everything that counts players must still
## count them, which is why they are sessions at all; everything that talks to a socket
## must not, because there is no socket. See [method DotServer.adopt_session].
var local: bool = false

var _state_entered_ms: int = 0


func _init(p_userid: int = 0, p_peer_id: int = 0) -> void:
	userid = p_userid
	peer_id = p_peer_id
	connected_at = int(Time.get_unix_time_from_system())
	last_seen_ms = Time.get_ticks_msec()
	_state_entered_ms = Time.get_ticks_msec()


# --- State -----------------------------------------------------------------

## Moves to a new state. Returns false when the transition is not allowed.
##
## Transitions are checked rather than assumed because the interesting bugs in a
## join flow are all ordering bugs — a spawn message arriving before content
## finished, a second authentication for an already-spawned client — and a state
## machine that accepts anything cannot catch them.
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
			# Content is optional: a server whose current game needs nothing new
			# sends an authenticated client straight to loading.
			return to == State.DOWNLOADING or to == State.LOADING
		State.DOWNLOADING:
			return to == State.LOADING
		State.LOADING:
			# Back to downloading on a game change, exactly as from SPAWNED below. A
			# `changelevel` does not wait for a client to finish joining, and one that
			# connected a second before it is in LOADING when it arrives — so
			# refusing this left that client in the game everybody else has left,
			# with one warning line and nothing else. Worse, the server then counted
			# it as neither ready nor waiting, decided every client was synced, and
			# swapped without ever telling it.
			return to == State.SPAWNED or to == State.DOWNLOADING
		State.SPAWNED:
			# Back to downloading on a game change, which is the whole point of
			# hot-swapping content while players are connected.
			return to == State.DOWNLOADING or to == State.LOADING

	return false


func state_name() -> String:
	return State.keys()[state]


## Seconds spent in the current state.
##
## What a timeout sweep and a `status` listing both need: "authenticating for 90
## seconds" is actionable in a way that "authenticating" is not.
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


## Whether this is an authenticated, non-guest account.
##
## The distinction bans care about: a guest can always come back as a different
## guest, so a ban on one means very little.
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


## The account name, or [code]""[/code] when there is none.
##
## Distinct from [member display_name], which a guest picks for themselves and an
## account holder can usually change: a report, a ticket or an appeal names somebody by
## their username, so an admin command has to accept one. Never used for authorisation —
## that is [method uid].
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


# --- Moderation ------------------------------------------------------------

## Whether a mute or gag is currently in force, clearing it if it expired.
##
## Checked lazily on read rather than swept on a timer: a mute that has expired but
## not yet been noticed is indistinguishable from one still in force, and the read
## path is where it matters.
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


# --- Permissions -----------------------------------------------------------

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


# --- Reporting -------------------------------------------------------------

## Short label for logs: userid, name and account.
##
## All three because each answers a different question — the userid is what an
## admin types, the name is who players see, the uid is who it actually was.
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

	return "# %-4d %-20s %-10s %-6s %-5s %-4s %s" % [
		userid,
		display_name.substr(0, 20),
		state_name().to_lower(),
		clock,
		str(ping_ms) if ping_ms >= 0 else "-",
		flags,
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
		"connected": connected_seconds(),
		"ping": ping_ms,
		"admin": is_admin(),
		"permissions": Array(permissions),
		"immunity": immunity,
		"silenced": is_silenced(),
		"content": content_key,
		"progress": content_progress,
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
