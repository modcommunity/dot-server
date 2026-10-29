class_name DotNotice
extends RefCounted

## Something the server wants a player to see on their HUD and hear, that is not chat: the one
## message sent to the client APPLICATION, not the loaded game. A dictionary on the wire.
## Example: [code]DotNotice.make(&"vote_warning", "A vote starts in", 10.0, &"vote")[/code]

## Longest [member text] a client is asked to draw. A HUD line, not a message of the day:
## past this it is wrapping over the game, and a server that means to say more has chat.
const MAX_TEXT := 160

## Longest [member cue] and [member topic]. Ids, not sentences.
const MAX_ID := 64

## Longest countdown a notice can carry. An hour is already longer than anything a HUD line
## is for, and a value past it is far more likely to be milliseconds sent as seconds.
const MAX_SECONDS := 3600.0

## Largest [member data], encoded. Past this it is dropped whole, not cut: half a tree needs
## checking for every missing branch.
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


## A notice that takes [param p_topic]'s line off the HUD: only the server knows a line stopped
## being true (a countdown called off).
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


## The payload the RPC carries; fields at their defaults are left out. Bounded here as well as
## in [method make], since the fields are public and a host may assign them directly.
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


## [member text] for a [RichTextLabel] with BBCode on: both brackets escaped in one pass (two
## replaces would rewrite the `]` the first inserted). The wire is plain text, so only a client
## drawing rich text must escape it, or a player's name draws its own markup.
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


## Reads a payload, whatever sent it. Tolerant: every field is type-checked (mismatched Variant
## comparisons are runtime errors) and what cannot be read is dropped, never raised.
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


## Cleaned by [method DotChatManager.sanitise]: it is drawn by the client that draws chat, so a
## newline or bidi override must not get through here that chat refuses.
static func _bounded_text(value: String) -> String:
	return DotChatManager.sanitise(value, MAX_TEXT)


## A dictionary of plain values within [constant MAX_DATA_BYTES], or an empty one. Only what JSON
## could carry survives; an [Object] or [Callable] is not content.
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
