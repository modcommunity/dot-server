@tool
class_name DotEnvelope
extends RefCounted

## The named kinds a [DotServer] and a [DotClientLink] say to each other, over six RPCs that do not change.
## The RPC surface is frozen because Godot checksums the @rpc set; a feature is a new kind, and each end
## advertises what it knows. Unknown kinds are dropped, REQUIRED ones refuse the join (docs/design-notes.md).

const CHANNEL := "signon.kinds"

## Which RPC a kind travels on. The kind does not decide the lane -- the sender does, per
## send -- but every core kind has one it always uses, written beside it below.
enum Lane {
	## Reliable, ordered, on the control channel. The join, and anything that must arrive.
	CONTROL,
	## Unreliable, on the control channel. Heartbeats and ping, where a newer one supersedes.
	UNRELIABLE,
	## Reliable, ordered, on the event channel. What a player sees, so it never queues
	## behind a content sync.
	EVENT,
}

# Server to client.
const CHALLENGE := &"signon.challenge"          ## CONTROL. Identify yourself.
const DISCONNECT := &"signon.disconnect"        ## CONTROL. Why the socket is about to close.
const CONTENT_SYNC := &"content.sync"           ## CONTROL. Fetch this before you can play.
const LOAD_GAME := &"game.load"                 ## CONTROL. Load this scene.
const HEARTBEAT_ACK := &"heartbeat.ack"         ## UNRELIABLE. Your timestamp, back.
const NOTICE := &"notice"                       ## EVENT. A HUD line; see DotNotice.
const CHAT_LINE := &"chat.line"                 ## EVENT. A chat line, or chat's state.
const SCOREBOARD := &"scoreboard"               ## UNRELIABLE. Who is here; see DotServer.scoreboard_snapshot.
const CVARS := &"cvars"                         ## CONTROL. The replicated cvars: {"values": {name: value}, "full": bool}.
# Client to server.
const CREDENTIALS := &"signon.credentials"      ## CONTROL. The answer to the challenge.
const CONTENT_PROGRESS := &"content.progress"   ## CONTROL. How far a download has got.
const CONTENT_READY := &"content.ready"         ## CONTROL. The content is mounted.
const LOADED := &"game.loaded"                  ## CONTROL. The scene is loaded.
const HEARTBEAT := &"heartbeat"                 ## UNRELIABLE. I am alive, and when.
const PING := &"ping"                           ## UNRELIABLE. What I measured.
const VISIBILITY := &"visibility"               ## CONTROL. My tab went away, or came back.
const CHAT_SUBMIT := &"chat.submit"             ## EVENT. Something I typed.
const SCOREBOARD_WANT := &"scoreboard.want"     ## CONTROL. My scoreboard opened, or closed.

## Kinds that are sent before either end has the other's advert, so nothing can be
## filtered against it yet. Always sent, always known.
const BOOTSTRAP: Array[StringName] = [CHALLENGE, CREDENTIALS, DISCONNECT]

## The kinds without which no join completes, whichever end sends them. A peer missing
## any of these cannot play and is told so rather than timed out.
const CORE_REQUIRED: Array[StringName] = [
	CHALLENGE, CREDENTIALS, DISCONNECT, CONTENT_SYNC, CONTENT_READY, LOAD_GAME, LOADED,
	HEARTBEAT,
]

## The kinds a join can do without. An older peer lacking one of these loses the feature
## and keeps the game.
const CORE_OPTIONAL: Array[StringName] = [
	CONTENT_PROGRESS, HEARTBEAT_ACK, PING, VISIBILITY, NOTICE, CHAT_LINE, CHAT_SUBMIT,
	SCOREBOARD, SCOREBOARD_WANT, CVARS,
]

## Longest kind name accepted off the wire. A kind is a label, not a payload.
const MAX_KIND_BYTES := 64

## Most kinds a peer may advertise. Bounds a table somebody else sent us.
const MAX_KINDS := 512

## name -> {"handler": Callable, "required": bool}
var _kinds: Dictionary = {}

## peer_id -> {"kinds": {name: true}, "required": PackedStringArray}
var _peers: Dictionary = {}

## Sends skipped because the peer does not know the kind.
var skipped_sends: int = 0

## Arrivals dropped because nothing here handles the kind.
var dropped_arrivals: int = 0

## Each dropped kind is logged once per peer, not once per packet: an older peer is sent
## nothing it does not know, but a newer one may send a kind this end has never heard of
## every second, and a DEBUG line per heartbeat is a log nobody reads again.
var _noted: Dictionary = {}


## Declares a kind this end knows. [param handler] is [code]func(peer_id: int, payload: Dictionary) -> void[/code],
## or empty for a kind this end only sends. [param required] means a peer that does not know the kind cannot play
## with this end; use it only where the join cannot complete without it.
func register(kind: StringName, handler: Callable = Callable(), required: bool = false) -> void:
	if kind == &"":
		push_error("DotEnvelope.register: a kind needs a name")
		return
	var existing: Dictionary = _kinds.get(kind, {})
	_kinds[kind] = {
		"handler": handler if handler.is_valid() else existing.get("handler", Callable()),
		"required": required,
	}


## Sets or replaces the handler for a kind already known, keeping whether it is required.
func handle(kind: StringName, handler: Callable) -> void:
	if not _kinds.has(kind):
		register(kind, handler, false)
		return
	_kinds[kind]["handler"] = handler


## Forgets a kind entirely. How a test stands in for an older build.
func unregister(kind: StringName) -> void:
	_kinds.erase(kind)


## Registers the core kinds, required and optional as listed above. The handlers are
## attached separately, by whichever node handles each.
func register_core() -> void:
	for kind in CORE_REQUIRED:
		register(kind, Callable(), true)
	for kind in CORE_OPTIONAL:
		register(kind, Callable(), false)


func knows(kind: StringName) -> bool:
	return _kinds.has(kind)


func is_required(kind: StringName) -> bool:
	return _kinds.has(kind) and bool(_kinds[kind]["required"])


## Every kind this end knows, sorted.
func kinds() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _kinds.keys():
		out.append(String(k))
	out.sort()
	return out


## The kinds a peer must know to play with this end, sorted.
func required_kinds() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _kinds.keys():
		if bool(_kinds[k]["required"]):
			out.append(String(k))
	out.sort()
	return out


## What this end tells the other: every kind it knows, and which it requires.
func advert() -> Dictionary:
	return {"kinds": Array(kinds()), "required": Array(required_kinds())}



## Takes a peer's [method advert] and says whether the two ends can play, in both directions.
## A malformed advert is refused as one: this is off the wire, before the peer has authenticated.
func adopt(peer_id: int, raw: Variant, is_server: bool) -> DotResult:
	if not (raw is Dictionary):
		return DotResult.fail(
			DotError.CODE_VERSION,
			"This %s does not say what it can do." % ("client" if is_server else "server"),
			"no kinds advertised; it predates DotEnvelope, and a build that old cannot "
			+ "complete a join with this one"
		)

	var theirs := _names(raw.get("kinds", []))
	var their_required := _names(raw.get("required", []))

	if theirs.size() > MAX_KINDS or their_required.size() > MAX_KINDS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The peer advertised too many kinds.",
			"%d, limit %d" % [theirs.size(), MAX_KINDS]
		)

	var known := {}
	for k in theirs:
		known[k] = true

	var missing_there := PackedStringArray()
	for k in required_kinds():
		if not known.has(k):
			missing_there.append(k)

	var missing_here := PackedStringArray()
	for k in their_required:
		if not _kinds.has(StringName(k)):
			missing_here.append(k)
	missing_here.sort()

	_peers[peer_id] = {"kinds": known, "required": their_required}

	var err := explain(missing_there, missing_here, is_server)
	if err != null:
		return DotResult.failure(err)

	var only_theirs := 0
	for k in known.keys():
		if not _kinds.has(StringName(k)):
			only_theirs += 1

	DotLog.debug(CHANNEL, "peer's kinds adopted", {
		"peer": peer_id, "kinds": known.size(), "theirs_only": only_theirs,
	})
	return DotResult.success(peer_id)


static func _names(raw: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	var list: Array = []
	if raw is PackedStringArray:
		list = Array(raw as PackedStringArray)
	elif raw is Array:
		list = raw as Array
	for v in list:
		if v is String or v is StringName:
			var s := String(v)
			if s != "" and s.to_utf8_buffer().size() <= MAX_KIND_BYTES:
				out.append(s)
	return out


## Whether a peer's advert has arrived.
func knows_peer(peer_id: int) -> bool:
	return _peers.has(peer_id)


## Whether the peer knows a kind. True before its advert arrives, and always for the
## bootstrap kinds -- those are how the adverts travel.
func peer_knows(peer_id: int, kind: StringName) -> bool:
	if BOOTSTRAP.has(kind) or not _peers.has(peer_id):
		return true
	return (_peers[peer_id]["kinds"] as Dictionary).has(String(kind))


func forget(peer_id: int) -> void:
	_peers.erase(peer_id)
	for key in _noted.keys():
		if String(key).begins_with("%d:" % peer_id):
			_noted.erase(key)


## Whether this send should go out. Counts and notes it when it should not.
func should_send(peer_id: int, kind: StringName) -> bool:
	if peer_knows(peer_id, kind):
		return true
	skipped_sends += 1
	_note(peer_id, kind, "not sent: the peer does not know this kind")
	return false


## Hands an arrival to its handler. False when there was none, or it was malformed.
## Nothing here trusts the arrival: a non-string kind or non-Dictionary payload is dropped, not passed on.
func dispatch(peer_id: int, kind: Variant, payload: Variant) -> bool:
	if not (kind is String or kind is StringName):
		dropped_arrivals += 1
		return false

	var name := StringName(kind)
	var entry: Dictionary = _kinds.get(name, {})
	var handler: Callable = entry.get("handler", Callable())

	if not handler.is_valid():
		dropped_arrivals += 1
		_note(peer_id, name, "dropped: nothing here handles this kind")
		return false

	if not (payload is Dictionary):
		dropped_arrivals += 1
		_note(peer_id, name, "dropped: the payload is not a dictionary")
		return false

	handler.call(peer_id, payload)
	return true


func _note(peer_id: int, kind: StringName, what: String) -> void:
	var key := "%d:%s" % [peer_id, kind]
	if _noted.has(key):
		return
	_noted[key] = true
	DotLog.debug(CHANNEL, what, {"peer": peer_id, "kind": String(kind)})


## What to tell a player, and what to log, when two ends' kinds cannot work together. Null when they can.
## Says who has to update, not which kinds differ (like [method DotSignon.explain]); the names go in the detail.
static func explain(
	missing_there: PackedStringArray,
	missing_here: PackedStringArray,
	is_server: bool
) -> DotError:
	if missing_there.is_empty() and missing_here.is_empty():
		return null

	var message := ""
	var parts := PackedStringArray()

	if not missing_there.is_empty():
		message = (
			"This server needs a newer game client." if is_server
			else "This server is older than this game client and cannot host it."
		)
		parts.append("the %s does not know: %s"
			% ["client" if is_server else "server", ", ".join(missing_there)])

	if not missing_here.is_empty():
		if message == "":
			message = (
				"This server is older than this game client and cannot host it." if is_server
				else "This server needs a newer game client."
			)
		parts.append("the %s does not know: %s"
			% ["server" if is_server else "client", ", ".join(missing_here)])

	return DotError.make(
		DotError.CODE_VERSION,
		message,
		"; ".join(parts) + " -- they were built against different versions of dot-server"
	)


# Every wire field is a Variant whose type the sender chose; comparing it with the wrong type is a
# runtime error in an RPC handler. These default and convert, so a missing or extra field is harmless.

static func number(payload: Dictionary, key: String, default: float = 0.0) -> float:
	var v: Variant = payload.get(key, default)
	return float(v) if (v is int or v is float) else default


static func text(payload: Dictionary, key: String, default: String = "") -> String:
	var v: Variant = payload.get(key, default)
	return String(v) if (v is String or v is StringName) else default


static func flag(payload: Dictionary, key: String, default: bool = false) -> bool:
	var v: Variant = payload.get(key, default)
	return v if v is bool else default


func describe() -> Dictionary:
	return {
		"kinds": kinds().size(),
		"required": required_kinds().size(),
		"peers": _peers.size(),
		"skipped_sends": skipped_sends,
		"dropped_arrivals": dropped_arrivals,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for k in kinds():
		var entry: Dictionary = _kinds[StringName(k)]
		out.append("  %-24s %-8s %s" % [
			k,
			"required" if bool(entry["required"]) else "optional",
			"handled" if (entry["handler"] as Callable).is_valid() else "sent",
		])
	return out
