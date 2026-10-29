@tool
class_name DotChatManager
extends Node

## Chat, and the chat-trigger path into the console: routing, flood control, length limits,
## mutes, and turning [code]!kick someone[/code] into a command with the speaker's own flags.
## Chat is the least trusted input: cap length, strip controls, rate-limit before parsing.

const CHANNEL := "chat"
const SERVICE := &"dot_chat_manager"

const CHANNEL_EVENT := DotTransport.Channel.EVENT

## Code points [method sanitise] removes outright: zero-width and formatting characters, the
## directional marks, overrides and isolates, and the byte-order mark. The same list as
## dot-chat's [code]DotChatFilter.INVISIBLE[/code] — see [method is_refused] for why.
const INVISIBLE: Array[int] = [
	0x00AD, 0x061C, 0x180E,
	0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
	0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
	0x2060, 0x2061, 0x2062, 0x2063, 0x2064,
	0x2066, 0x2067, 0x2068, 0x2069,
	0x206A, 0x206B, 0x206C, 0x206D, 0x206E, 0x206F,
	0xFEFF,
]

## Emitted after a message is accepted and broadcast.
signal message_sent(session: DotClientSession, text: String, team_only: bool)

## Emitted when a message is refused, for abuse detection.
signal message_blocked(session: DotClientSession, reason: String)

@export_group("Announcements")

## Announce joins and leaves.
@export var announce_joins: bool = true

## Prefix on system messages, so players can tell them from player chat.
@export var system_prefix: String = "[Server]"

## Prefix on admin chat.
@export var admin_prefix: String = "[ADMIN]"

var server: DotServer = null

var _limiter: DotRateLimiter = null


func setup(p_server: DotServer) -> void:
	server = p_server
	DotRegistry.register(SERVICE, self)

	var per_minute := server.config.chat_rate_per_minute
	# Burst equal to a quarter of the per-minute budget: enough for a player typing
	# three quick lines, not enough to paste a wall of text.
	_limiter = DotRateLimiter.new(
		float(per_minute) / 60.0, maxf(3.0, float(per_minute) / 4.0)
	)

	if server.events != null:
		server.events.declare("chat_filtered", "A message was rejected.")


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)



## Handles a chat message from a client. Cheap structural checks first, then rate limiting,
## mute, the command path, the cancellable event hook, then broadcast: reject before working.
func handle_message(
	session: DotClientSession,
	raw: String,
	team_only: bool = false
) -> DotResult:
	if session == null or not session.is_playing():
		return DotResult.fail(
			DotError.CODE_STATE, "You are not in the game yet."
		)

	var text := sanitise(raw, server.config.chat_max_length)

	if text == "":
		return DotResult.fail(DotError.CODE_INVALID, "Empty message.")

	if not _limiter.allow(session.userid):
		DotLog.debug(
			CHANNEL, "chat rate limited", {"user": session.label()}
		)
		send_system_to(session, "You are sending messages too quickly.")
		message_blocked.emit(session, "rate limited")
		return DotResult.fail(
			DotError.CODE_RATE_LIMITED, "Sending too quickly."
		)

	# A chat command is checked before the mute, so a muted player can still use
	# their own admin commands. Muting is about speech, not about tooling.
	var prefix := _command_prefix(text)
	if prefix != "":
		return _handle_command(session, text.substr(prefix.length()))

	if session.is_silenced():
		send_system_to(session, "You are muted.")
		message_blocked.emit(session, "muted")
		return DotResult.fail(DotError.CODE_FORBIDDEN, "You are muted.")

	if server.events != null:
		var event := server.events.fire("player_chat", {
			"userid": session.userid,
			"name": session.display_name,
			"text": text,
			"team_only": team_only,
			"session": session,
		})

		if event.cancelled:
			message_blocked.emit(session, event.cancel_reason)
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				event.cancel_reason if event.cancel_reason != "" else "Message blocked."
			)

		# A pre-hook may rewrite the text — that is how a word filter works without
		# having to reject the whole message.
		text = sanitise(
			event.get_string("text", text), server.config.chat_max_length
		)
		if text == "":
			return DotResult.fail(DotError.CODE_INVALID, "Empty message.")

	_broadcast_chat(session, text, team_only)

	DotLog.info(
		CHANNEL,
		"chat",
		{
			"user": session.label(),
			"team": team_only,
			"text": text,
		}
	)

	message_sent.emit(session, text, team_only)
	return DotResult.success(text)


## Which configured prefix a message starts with, or [code]""[/code].
func _command_prefix(text: String) -> String:
	for prefix in server.config.chat_command_prefixes:
		if prefix != "" and text.begins_with(prefix):
			return prefix
	return ""


## Runs a chat command with the speaker's permissions.
func _handle_command(
	session: DotClientSession,
	command_line: String
) -> DotResult:
	var trimmed := command_line.strip_edges()
	if trimmed == "":
		return DotResult.fail(DotError.CODE_INVALID, "No command given.")

	var tokens := DotConsole.tokenize(trimmed)
	if tokens.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "No command given.")

	var command_name := tokens[0].to_lower()

	if server.events != null:
		var event := server.events.fire("player_command", {
			"userid": session.userid,
			"name": session.display_name,
			"command": command_name,
			"args": Array(tokens).slice(1),
			"session": session,
		})
		if event.cancelled:
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "Command blocked."
			)

	var cmd := server.console.find_command(command_name)

	if cmd == null:
		# Not a command: ignored silently, since an error would confirm which commands
		# exist to anyone probing.
		DotLog.debug(
			CHANNEL,
			"unknown chat command ignored",
			{"user": session.label(), "command": command_name}
		)
		return DotResult.fail(
			DotError.CODE_INVALID, "Unknown command."
		)

	# Replies go to the speaker only. A chat command's output is for the person who
	# ran it; broadcasting it would leak admin output to everyone.
	var ctx := session.make_context(
		command_name,
		PackedStringArray(Array(tokens).slice(1)),
		DotCmdContext.Source.CHAT,
		func(line: String) -> void: send_system_to(session, line)
	)

	# Dispatched through the console so permissions, argument checks and the audit
	# trail all apply exactly as they do over RCON.
	return server.console.execute(trimmed, ctx)



func _broadcast_chat(
	session: DotClientSession,
	text: String,
	team_only: bool
) -> void:
	var payload := {
		"kind": "team" if team_only else "all",
		"userid": session.userid,
		"name": session.display_name,
		"text": text,
		"admin": session.is_admin(),
	}

	for other in server.playing_sessions():
		if team_only and not _same_team(session, other):
			continue
		if not _can_reach(other):
			continue
		server.send_kind(other.peer_id, DotEnvelope.CHAT_LINE, payload, DotEnvelope.Lane.EVENT)


## Whether two sessions are on the same team, from a [code]team[/code] key in session data.
## Without one everyone is on one team, so team chat never silently reaches nobody.
func _same_team(a: DotClientSession, b: DotClientSession) -> bool:
	var team_a: Variant = a.data.get("team")
	var team_b: Variant = b.data.get("team")
	if team_a == null or team_b == null:
		return true
	return team_a == team_b



## Whether chat is also carried somewhere off this server. `() -> bool`, a callable because
## dot-server cannot name dot-chat's relay. Unset means no.
var relay_fn: Callable = Callable()

## Points [member relay_fn] at a relay and tells everybody what changed. Duck-typed (a
## method `is_carrying() -> bool`) because naming [code]DotChatRelay[/code] would not compile
## without dot-chat. A null relay, or one without the method, means nothing carries chat.
func watch_relay(relay: Object) -> void:
	if relay != null and relay.has_method("is_carrying"):
		relay_fn = Callable(relay, "is_carrying")
	else:
		relay_fn = Callable()

	announce_state()


## What the client is told about the conversation it just joined. Only the server knows
## whether a player's lines already reach a web page; what the client does with that
## ([code]DotChatWindow.enabled[/code] and a setting) is the client's.
func chat_state() -> Dictionary:
	return {
		"kind": "state",
		"relay": is_relayed(),
	}


## Whether anything is carrying chat off this server right now.
func is_relayed() -> bool:
	if not relay_fn.is_valid():
		return false

	var answer: Variant = relay_fn.call()
	return answer is bool and answer


## Tells one joining client what is carrying chat, before the join announcement so it has
## the answer before any line to draw. Called by [DotServer] as a session starts playing.
func greet(session: DotClientSession) -> void:
	if not _can_reach(session):
		return

	server.send_kind(session.peer_id, DotEnvelope.CHAT_LINE, chat_state(), DotEnvelope.Lane.EVENT)


## Tells everybody, for a relay that came up or went down mid-match.
func announce_state() -> void:
	if server == null:
		return

	var payload := chat_state()

	for session in server.playing_sessions():
		if _can_reach(session):
			server.send_kind(session.peer_id, DotEnvelope.CHAT_LINE, payload, DotEnvelope.Lane.EVENT)

	DotLog.info(CHANNEL, "chat state", payload)


## Sends a system message to everyone playing.
func broadcast_system(text: String) -> void:
	var payload := {
		"kind": "system",
		"name": system_prefix,
		"text": text,
	}

	for session in server.playing_sessions():
		if _can_reach(session):
			server.send_kind(session.peer_id, DotEnvelope.CHAT_LINE, payload, DotEnvelope.Lane.EVENT)

	DotLog.info(CHANNEL, "system message", {"text": text})


## Whether a line to this session can be put on the wire. `is_active()` is not enough: between
## a player leaving and the server noticing, `rpc_id` prints an engine error per reply line.
## The host's own id is not in `get_peers()`; `rpc_id` to oneself is refused anyway.
func _can_reach(session: DotClientSession) -> bool:
	if session == null or not session.is_active():
		return false
	var mp := multiplayer
	if mp == null or mp.multiplayer_peer == null:
		return false
	return session.peer_id > 0 and Array(mp.get_peers()).has(session.peer_id)


## Sends a system message to one client.
func send_system_to(session: DotClientSession, text: String) -> void:
	if not _can_reach(session):
		return

	server.send_kind(session.peer_id, DotEnvelope.CHAT_LINE, {
		"kind": "system",
		"name": system_prefix,
		"text": text,
	}, DotEnvelope.Lane.EVENT)


## Sends admin chat to everyone holding [constant DotAdminFlags.CHAT], filtered server-side:
## asking clients to hide messages is not a control.
func broadcast_admin(from: String, text: String) -> void:
	var payload := {
		"kind": "admin",
		"name": "%s %s" % [admin_prefix, from],
		"text": text,
	}

	var recipients := 0
	for session in server.playing_sessions():
		if session.has_permission(DotAdminFlags.CHAT) and _can_reach(session):
			server.send_kind(session.peer_id, DotEnvelope.CHAT_LINE, payload, DotEnvelope.Lane.EVENT)
			recipients += 1

	DotLog.info(
		CHANNEL,
		"admin chat",
		{"from": from, "text": text, "recipients": recipients}
	)


## Announces an administrative action, if the config allows: visible moderation deters.
func announce_action(text: String) -> void:
	if not server.config.announce_admin_actions:
		return
	broadcast_system(text)


func announce_join(session: DotClientSession) -> void:
	if not announce_joins:
		return
	broadcast_system("%s joined the game." % session.display_name)


func announce_leave(session: DotClientSession) -> void:
	if not announce_joins:
		return
	broadcast_system("%s left the game." % session.display_name)


# No RPCs here: a line in arrives as the envelope's `chat.submit` kind, a line out goes as
# `chat.line` through [method DotServer.send_kind]. RPCs here would be a second surface
# a client had to match exactly; see [DotEnvelope].



## Cleans untrusted chat text: strips controls and invisibles ([method is_refused]), collapses
## whitespace, truncates; does NOT escape BBCode (a [RichTextLabel] caller does). Shared with
## [DotNotice]. Linear: stops reading one character past the limit.
static func sanitise(raw: String, max_length: int) -> String:
	var out := PackedStringArray()
	var last_space := true   # so a leading space is dropped, which is strip_edges' left half

	for i in range(raw.length()):
		var code := raw.unicode_at(i)

		# Tab and newline become spaces rather than being dropped, so words on
		# either side do not run together.
		if code == 9 or code == 10 or code == 13:
			code = 32

		if is_refused(code):
			continue

		if code == 32:
			if last_space:
				continue
			last_space = true
			out.append(" ")
		else:
			last_space = false
			out.append(raw[i])

		# One past the limit: whatever comes next cannot change the first max_length.
		if max_length > 0 and out.size() > max_length:
			break

	if max_length > 0 and out.size() > max_length:
		# Cut rather than stripped. A space at the cut is followed by something that is
		# not one — collapsing guarantees it — so strip-then-cut would have kept it too.
		out.resize(max_length)
	elif not out.is_empty() and out[out.size() - 1] == " ":
		out.resize(out.size() - 1)

	return "".join(out)


## Whether [method sanitise] drops [param code]: controls, DEL, and [constant INVISIBLE].
## Keep equal to dot-chat's [code]DotChatFilter[/code]; a character one passes is a spoof
## route. Copied because dot-server names no other addon.
static func is_refused(code: int) -> bool:
	if code < 32 or code == 127 or (code >= 0x80 and code <= 0x9F):
		return true
	return code in INVISIBLE


func describe() -> Dictionary:
	return {
		"rate_per_minute": server.config.chat_rate_per_minute if server != null else 0,
		"max_length": server.config.chat_max_length if server != null else 0,
		"prefixes": Array(server.config.chat_command_prefixes) if server != null else [],
		"tracked": _limiter.tracked_count() if _limiter != null else 0,
	}
