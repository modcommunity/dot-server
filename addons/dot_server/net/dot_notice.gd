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
## - [member data]: structured content for a client that knows the [member topic], and
##   nothing to one that does not. A ballot to draw as a menu is the first: the text line
##   says how to vote by typing, and a shell that can draw [code]data[/code] draws the menu.
##   [b]Not cleaned the way [member text] is[/b] — it is a tree, and only its reader knows
##   which leaves are drawn — so a client draws every string in it as plain text, never as
##   markup, through [method sanitised_string].
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

## Largest [member data], encoded. A ballot of six options with sixty-four named voters is
## about four kilobytes; past this it is not a HUD's content any more and is dropped whole
## rather than cut, because half a tree is a tree a reader has to check for every missing
## branch.
const MAX_DATA_BYTES := 8192

## A sound id. Empty is silence.
var cue: StringName = &""

## A HUD line. Empty draws nothing.
var text: String = ""

## A countdown, in seconds, from the moment this arrives. Negative is none.
var seconds: float = -1.0

## Which HUD line this is. Empty is a line of its own.
var topic: StringName = &""

## Structured content for a client that knows [member topic]. See the class notes.
var data: Dictionary = {}


## A notice. Every argument but [param cue] is optional, and [param cue] may be empty.
static func make(
	p_cue: StringName,
	p_text: String = "",
	p_seconds: float = -1.0,
	p_topic: StringName = &"",
	p_data: Dictionary = {}
) -> DotNotice:
	var n := DotNotice.new()
	n.cue = _bounded_id(String(p_cue))
	n.text = _bounded_text(p_text)
	n.seconds = _bounded_seconds(p_seconds)
	n.topic = _bounded_id(String(p_topic))
	n.data = _bounded_data(p_data)
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
	return topic != &"" and cue == &"" and text == "" and not has_countdown() and data.is_empty()


## Whether a client has anything to do with this at all.
func is_empty() -> bool:
	return cue == &"" and text == "" and not has_countdown() and topic == &"" and data.is_empty()


## The payload the RPC carries. See the class notes for why it is a dictionary.
##
## Fields at their defaults are left out: the common case — a cue with nothing else — is
## then one key, and a field that is absent and a field that is default decode the same.
##
## [b]Bounded again here, not only in [method make].[/b] The fields are public, so a host
## that builds a notice with [code]new()[/code] and assigns [member text] itself skipped
## every rule — the receiving client cleaned it, but a client is not where the server gets
## to decide what it sends, and a shell built before a rule was added cleans nothing.
func to_wire() -> Dictionary:
	var out := {}
	var c := _bounded_id(String(cue))
	if c != &"":
		out["cue"] = String(c)
	var t := _bounded_text(text)
	if t != "":
		out["text"] = t
	var s := _bounded_seconds(seconds)
	if s >= 0.0:
		out["seconds"] = s
	var p := _bounded_id(String(topic))
	if p != &"":
		out["topic"] = String(p)
	var extra := _bounded_data(data)
	if not extra.is_empty():
		out["data"] = extra
	return out


## [member text] for a [RichTextLabel] with BBCode on: both brackets escaped in one pass.
##
## The wire carries plain text, and the shell draws it in a plain [Label], where an escape
## would be drawn literally as [code][lb][/code]. A client that draws a notice as rich text
## is the one that has to escape it, or a server's line — a player's name in a vote line,
## say — draws its own markup. One pass, not two replaces: `[` to `[lb]` inserts a `]` a
## second pass would then rewrite, which is dot-chat's [code]escape_bbcode[/code] finding.
func bbcode_text() -> String:
	var out := PackedStringArray()
	for i in text.length():
		var ch := text[i]
		if ch == "[":
			out.append("[lb]")
		elif ch == "]":
			out.append("[rb]")
		else:
			out.append(ch)
	return "".join(out)


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

	n.data = _bounded_data(d.get("data", {}))

	return n


func describe() -> Dictionary:
	return {
		"cue": String(cue),
		"text": text,
		"seconds": seconds,
		"topic": String(topic),
		"data": data.size(),
	}


## A string out of [member data], cleaned as [member text] is, for a client about to draw it.
static func sanitised_string(value: Variant, max_length: int = MAX_TEXT) -> String:
	if not (value is String or value is StringName):
		return ""
	return DotChatManager.sanitise(String(value), max_length)


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


## A dictionary of plain values within [constant MAX_DATA_BYTES], or an empty one.
##
## Only what JSON could carry survives: a nested [Object] or [Callable] is not content, and
## the engine would refuse to encode the first anyway — at the RPC, as an error, rather
## than here as an empty tree.
static func _bounded_data(value: Variant) -> Dictionary:
	if not (value is Dictionary) or (value as Dictionary).is_empty():
		return {}
	if not _is_plain(value, 0):
		return {}
	if var_to_bytes(value).size() > MAX_DATA_BYTES:
		return {}
	return (value as Dictionary).duplicate(true)


static func _is_plain(value: Variant, depth: int) -> bool:
	if depth > 8:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME:
			return true
		TYPE_ARRAY:
			for item: Variant in value:
				if not _is_plain(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			for key: Variant in value:
				if not (key is String or key is StringName or key is int):
					return false
				if not _is_plain((value as Dictionary)[key], depth + 1):
					return false
			return true
		_:
			return false


## NaN and infinity become "no countdown" rather than a clamped extreme. A countdown the
## server could not compute is not a countdown of an hour.
static func _bounded_seconds(value: float) -> float:
	if is_nan(value) or is_inf(value) or value < 0.0:
		return -1.0
	return minf(value, MAX_SECONDS)
