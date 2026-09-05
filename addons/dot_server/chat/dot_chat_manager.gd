@tool
class_name DotChatManager
extends Node

## Chat, and the chat-trigger path into the console.
##
## Handles routing (all / team / admin), flood control, length limits, mute
## enforcement, and turning [code]!kick someone[/code] into a console command with
## the speaker's own permissions.
##
## [b]Chat is the least trustworthy input the server takes.[/b] It is unauthenticated
## in the sense that anyone in the game can send it, it is attacker-controlled text
## that ends up in other players' UI and in the log, and it is the path an admin
## command arrives through. So: length is capped before anything else, control
## characters are stripped, the rate limiter runs before the command parser, and a
## command from chat only reaches commands that opted in with
## [member DotConCommand.chat_allowed].

const CHANNEL := "chat"
const SERVICE := &"dot_chat_manager"

const CHANNEL_EVENT := DotTransport.Channel.EVENT

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


# --- Receiving -------------------------------------------------------------

## Handles a chat message from a client.
##
## Called by the RPC endpoint. Order is deliberate: cheap structural checks first,
## then rate limiting, then mute, then the command path, then the event hook that a
## module can cancel, then broadcast. Anything that can reject should reject before
## work is done on the message.
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
		# Not a command. Silently ignored rather than answered: a player typing
		# "!!" or a message that happens to start with a slash should not get a
		# console error, and answering also confirms which commands exist to
		# anyone probing.
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


# --- Sending ---------------------------------------------------------------

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
		_receive_chat.rpc_id(other.peer_id, payload)


## Whether two sessions are on the same team.
##
## Reads a [code]team[/code] key from session data, which a game sets. Without one
## every player is on the same team and team chat behaves like all chat — the safe
## default, since the alternative is team chat silently reaching nobody.
func _same_team(a: DotClientSession, b: DotClientSession) -> bool:
	var team_a: Variant = a.data.get("team")
	var team_b: Variant = b.data.get("team")
	if team_a == null or team_b == null:
		return true
	return team_a == team_b


## Sends a system message to everyone playing.
func broadcast_system(text: String) -> void:
	var payload := {
		"kind": "system",
		"name": system_prefix,
		"text": text,
	}

	for session in server.playing_sessions():
		_receive_chat.rpc_id(session.peer_id, payload)

	DotLog.info(CHANNEL, "system message", {"text": text})


## Sends a system message to one client.
func send_system_to(session: DotClientSession, text: String) -> void:
	if session == null or not session.is_active():
		return

	_receive_chat.rpc_id(session.peer_id, {
		"kind": "system",
		"name": system_prefix,
		"text": text,
	})


## Sends admin chat to everyone holding [constant DotAdminFlags.CHAT].
##
## Filtered server-side. Asking clients to hide messages they are not entitled to
## see is not a control at all.
func broadcast_admin(from: String, text: String) -> void:
	var payload := {
		"kind": "admin",
		"name": "%s %s" % [admin_prefix, from],
		"text": text,
	}

	var recipients := 0
	for session in server.playing_sessions():
		if session.has_permission(DotAdminFlags.CHAT):
			_receive_chat.rpc_id(session.peer_id, payload)
			recipients += 1

	DotLog.info(
		CHANNEL,
		"admin chat",
		{"from": from, "text": text, "recipients": recipients}
	)


## Announces an administrative action, if the config allows.
##
## Visible moderation is a deterrent, and players who see a cheater removed stop
## reporting them.
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


# --- RPC -------------------------------------------------------------------

## A client sending chat.
@rpc("any_peer", "reliable", "call_remote", CHANNEL_EVENT)
func submit_chat(text: String, team_only: bool) -> void:
	var session: DotClientSession = server.session_of(
		multiplayer.get_remote_sender_id()
	)
	if session == null:
		return

	session.touch()
	handle_message(session, text, team_only)


## Server to client. Implemented on the client side.
@rpc("authority", "reliable", "call_remote", CHANNEL_EVENT)
func _receive_chat(_payload: Dictionary) -> void:
	pass


# --- Sanitising -----------------------------------------------------------

## Cleans untrusted chat text.
##
## Strips control characters (which can corrupt a terminal reading the log, and
## break UI layout), collapses whitespace, and truncates. Done before length
## checking so a message padded with 4000 newlines does not pass a character count
## and then render as a wall.
static func sanitise(raw: String, max_length: int) -> String:
	var out := ""

	for i in range(raw.length()):
		var code := raw.unicode_at(i)

		# Tab and newline become spaces rather than being dropped, so words on
		# either side do not run together.
		if code == 9 or code == 10 or code == 13:
			out += " "
			continue

		if code < 32 or code == 127:
			continue

		# Zero-width and bidirectional-override characters: used to spoof names,
		# hide text, and reverse how a message renders.
		if code == 0x200B or code == 0x200C or code == 0x200D or code == 0xFEFF:
			continue
		if code >= 0x202A and code <= 0x202E:
			continue
		if code >= 0x2066 and code <= 0x2069:
			continue

		out += raw[i]

	while out.contains("  "):
		out = out.replace("  ", " ")

	out = out.strip_edges()

	if max_length > 0 and out.length() > max_length:
		out = out.substr(0, max_length)

	return out


func describe() -> Dictionary:
	return {
		"rate_per_minute": server.config.chat_rate_per_minute if server != null else 0,
		"max_length": server.config.chat_max_length if server != null else 0,
		"prefixes": Array(server.config.chat_command_prefixes) if server != null else [],
		"tracked": _limiter.tracked_count() if _limiter != null else 0,
	}
