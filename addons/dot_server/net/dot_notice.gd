class_name DotNotice
extends RefCounted

## Something the server wants a player to see on their HUD and hear, that is not chat.
##
## [codeblock]
## server.broadcast_notice(DotNotice.make(&"vote_warning", "A vote starts in", 10.0, &"vote"))
## link.notice_received.connect(func(n: DotNotice) -> void: hud.show(n))
## [/codeblock]
##
## [b]Why this exists at all.[/b] A client application talks to a server over exactly two
## RPC sets, [DotClientLink]'s and [DotClientChat]'s, and neither could say anything but a
## chat line. So a server-level vote — which is the server's, not the game's, and outlives
## every game it changes to — could only reach a player as text in a scrollback: no
## countdown on screen, no sound when the ballot opens. A loaded game's own wire is no help
## there, because it is the game's, it is replaced by the change the vote causes, and the
## host that runs the vote does not name a game's classes. This is the one message a
## server can send to the client APPLICATION rather than to whatever game it is showing.
##
## [b]Deliberately not about votes.[/b] A cue id, optional seconds, optional text and an
## optional topic cover a restart warning, a map vote a game did not wire itself, an
## operator's announcement and a ballot alike. A vote-shaped message would be the second
## [code]@rpc[/code] pair somebody has to add the next time, and every pair added is a
## signon revision every shipped client has to be rebuilt for — see [DotSignon].
##
## [b]A dictionary on the wire, and that is the protocol decision.[/b] Godot's RPC
## checksum is over method NAMES, so a field added to this dictionary later changes no
## revision and breaks no client, while a new argument or a new method breaks every one.
## [method from_wire] defaults every field for that reason: an older client meeting a newer
## field ignores it, and a newer client meeting an older payload shows a plainer notice.
##
## What each field means to a client:
##
## - [member cue]: a sound id — a dot-audio catalogue id, typically. Empty is silence. An id
##   a client does not have is silence too, which is dot-audio's own rule.
## - [member text]: a line for the HUD. Empty shows nothing.
## - [member seconds]: a countdown the client runs itself from the moment it arrives. -1 is
##   "no countdown". A server does not send a notice per frame; it sends one and the client
##   counts.
## - [member topic]: which line on the HUD this replaces. Two notices with one topic are one
##   line that changed, which is how "10… 9… 8…" stays one line rather than ten. A notice
##   with a topic and nothing else ([method is_clear]) takes that line down.
##
## A pure value object. It logs nothing.

## Longest [member text] a client is asked to draw. A HUD line, not a message of the day:
## past this it is wrapping over the game, and a server that means to say more has chat.
const MAX_TEXT := 160

## Longest [member cue] and [member topic]. Ids, not sentences.
const MAX_ID := 64

## Longest countdown a notice can carry. An hour is already longer than anything a HUD line
## is for, and a value past it is far more likely to be milliseconds sent as seconds.
const MAX_SECONDS := 3600.0

## A sound id. Empty is silence.
var cue: StringName = &""

## A HUD line. Empty draws nothing.
var text: String = ""

## A countdown, in seconds, from the moment this arrives. Negative is none.
var seconds: float = -1.0

## Which HUD line this is. Empty is a line of its own.
var topic: StringName = &""


## A notice. Every argument but [param cue] is optional, and [param cue] may be empty.
static func make(
	p_cue: StringName,
	p_text: String = "",
	p_seconds: float = -1.0,
	p_topic: StringName = &""
) -> DotNotice:
	var n := DotNotice.new()
	n.cue = _bounded_id(String(p_cue))
	n.text = _bounded_text(p_text)
	n.seconds = _bounded_seconds(p_seconds)
	n.topic = _bounded_id(String(p_topic))
	return n


## A notice that takes [param p_topic]'s line off the HUD.
##
## Needed because the server knows when a line stops being true and the client cannot: a
## countdown an admin called off would otherwise go on counting to a ballot that never
## opens.
static func clear(p_topic: StringName) -> DotNotice:
	return make(&"", "", -1.0, p_topic)


## Whether this carries a countdown.
func has_countdown() -> bool:
	return seconds >= 0.0


## Whether this only takes a topic's line down.
func is_clear() -> bool:
	return topic != &"" and cue == &"" and text == "" and not has_countdown()


## Whether a client has anything to do with this at all.
func is_empty() -> bool:
	return cue == &"" and text == "" and not has_countdown() and topic == &""


## The payload the RPC carries. See the class notes for why it is a dictionary.
##
## Fields at their defaults are left out: the common case — a cue with nothing else — is
## then one key, and a field that is absent and a field that is default decode the same.
func to_wire() -> Dictionary:
	var out := {}
	if cue != &"":
		out["cue"] = String(cue)
	if text != "":
		out["text"] = text
	if has_countdown():
		out["seconds"] = seconds
	if topic != &"":
		out["topic"] = String(topic)
	return out


## Reads a payload, whatever sent it.
##
## [b]Tolerant by design, and typed by hand.[/b] This is a wire message and a Variant, so
## every field is checked for its type before it is used — a comparison between two
## mismatched Variant types is a runtime error rather than a [code]false[/code], and an
## older or newer server may send a shape this build has never seen. What cannot be read is
## dropped, never raised.
static func from_wire(payload: Variant) -> DotNotice:
	var n := DotNotice.new()

	if not (payload is Dictionary):
		return n

	var d := payload as Dictionary

	var c: Variant = d.get("cue", "")
	if c is String or c is StringName:
		n.cue = _bounded_id(String(c))

	var t: Variant = d.get("text", "")
	if t is String:
		n.text = _bounded_text(t)

	var s: Variant = d.get("seconds", -1.0)
	if s is float or s is int:
		n.seconds = _bounded_seconds(float(s))

	var p: Variant = d.get("topic", "")
	if p is String or p is StringName:
		n.topic = _bounded_id(String(p))

	return n


func describe() -> Dictionary:
	return {
		"cue": String(cue),
		"text": text,
		"seconds": seconds,
		"topic": String(topic),
	}


static func _bounded_id(value: String) -> StringName:
	return StringName(value.strip_edges().substr(0, MAX_ID))


## Cleaned by [method DotChatManager.sanitise], because this is drawn, not logged, and
## drawn by the client that draws chat: a newline in a HUD line pushes the next one off the
## panel, and a bidi override or a zero-width character spoofs a line on the HUD exactly as
## it does in chat. This stripped only what is below 32, so DEL, the zero-width characters
## and the overrides all reached the screen — the same line refused as chat was drawn as a
## notice.
static func _bounded_text(value: String) -> String:
	return DotChatManager.sanitise(value, MAX_TEXT)


## NaN and infinity become "no countdown" rather than a clamped extreme. A countdown the
## server could not compute is not a countdown of an hour.
static func _bounded_seconds(value: float) -> float:
	if is_nan(value) or is_inf(value) or value < 0.0:
		return -1.0
	return minf(value, MAX_SECONDS)
