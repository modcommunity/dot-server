@tool
extends "res://addons/dot_server/client/dot_client_link_signon.gd"

## Page visibility, scoreboard, replicated cvars, chat and notices of [DotClientLink].


## Subscribes to the browser's visibility events. No-op off-web.
##
## Deliberately not gated on [member background_keepalive]: that is an exported
## property a host can change at runtime, and a listener installed once in
## [method _ready] could not honour a later change to it. The flag is checked where it
## is acted on instead. Listening costs nothing off-web, where
## [method DotWeb.watch_visibility] installs nothing at all — and
## [signal page_visibility_changed] is about the page rather than about the keepalive,
## so a game that wants to pause or mute on a tab switch gets it either way.
func _watch_page_visibility() -> void:
	# Keyed by instance rather than by class: two links in one process would
	# otherwise root their listeners under the same name, and the second would
	# silently replace the first.
	var key := "dot_client_link_visibility_%d" % get_instance_id()
	if DotWeb.watch_visibility(
		key, func(visible: bool) -> void: _on_page_visibility(visible)
	):
		_visibility_key = key


func _on_page_visibility(visible: bool) -> void:
	page_visibility_changed.emit(visible)

	if not background_keepalive or not _connected:
		return

	DotLog.debug(
		CHANNEL,
		"page visibility changed",
		{"visible": visible, "grace": background_grace_sec}
	)

	send_kind(DotEnvelope.VISIBILITY, {"visible": visible, "grace": background_grace_sec})

	if visible:
		# Coming back, the heartbeat timer resumes on its own — but its next tick is
		# up to heartbeat_interval_sec away, and the server has been counting silence
		# for the whole time the tab was hidden. Say something now rather than spend
		# any more of a budget that is already nearly gone.
		_send_heartbeat()

	_flush_peer()


## Pushes what [code]rpc_id[/code] queued out of the socket without waiting for a
## frame.
##
## [b]The announcement above has no frame to wait for.[/b] `visibilitychange` arrives
## as a JavaScript-to-wasm call, not as a frame callback, and it fires as the browser
## is stopping [code]requestAnimationFrame[/code] — so the poll that would ordinarily
## do the sending may never happen again. An announcement that never leaves is the
## same as no announcement, and costs the player the slot it was asking to keep.
func _flush_peer() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer == null:
		return
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	peer.poll()


## Tells the server this client's scoreboard opened or closed. While it is open the server
## sends the roster twice a second; closed, nothing — a board nobody holds costs nothing.
## False when it was not sent (not connected, or a server that predates the kind).
func want_scoreboard(open: bool) -> bool:
	_scoreboard_held = open
	if not _connected:
		return false
	return send_kind(DotEnvelope.SCOREBOARD_WANT, {"open": open})


## Asks for ONE board, leaving a held board held. What a client's block list (dot-chat's
## `sm`) uses to learn who is here without the player opening Tab. The current held state
## goes with it, so a server that predates `once` reads "no change" instead of a close.
## False when it was not sent.
func request_scoreboard() -> bool:
	if not _connected:
		return false
	return send_kind(DotEnvelope.SCOREBOARD_WANT, {"open": _scoreboard_held, "once": true})


func _on_scoreboard(_peer_id: int, payload: Dictionary) -> void:
	# A board older than the one held arrived late (ENet sends unreliable unordered); it
	# says nothing the newer one did not. One with no `seq` is from a server before it,
	# and is taken as it always was.
	if payload.has("seq") and scoreboard.has("seq") and int(payload["seq"]) <= int(scoreboard["seq"]):
		return
	scoreboard = payload
	scoreboard_received.emit(payload)


## The server's value of a replicated cvar, or [param fallback] when it has not said one.
func replicated_cvar(cvar_name: String, fallback: String = "") -> String:
	return String(replicated_cvars.get(cvar_name, fallback))


func _on_cvars(_peer_id: int, payload: Dictionary) -> void:
	var raw: Variant = payload.get("values", {})
	if not (raw is Dictionary):
		return

	var values := raw as Dictionary
	var full := DotEnvelope.flag(payload, "full", false)
	var next := {} if full else replicated_cvars.duplicate()
	var changed := PackedStringArray()

	for key in values:
		if next.size() >= MAX_REPLICATED_CVARS and not next.has(String(key)):
			break
		if not (key is String or key is StringName):
			continue
		var cvar_name := String(key)
		if cvar_name == "" or cvar_name.to_utf8_buffer().size() > MAX_CVAR_NAME_BYTES:
			continue
		var value := str(values[key])
		if value.to_utf8_buffer().size() > MAX_CVAR_VALUE_BYTES:
			continue
		if not replicated_cvars.has(cvar_name) or String(replicated_cvars[cvar_name]) != value:
			changed.append(cvar_name)
		next[cvar_name] = value

	replicated_cvars = next

	for cvar_name in changed:
		replicated_cvar_changed.emit(cvar_name, String(next[cvar_name]))


## Sends a chat message, or a chat command when it starts with a prefix.
func send_chat(text: String, team_only: bool = false) -> void:
	if not _connected or _chat == null:
		return
	_chat.send(text, team_only)


## A chat line, or chat's state, from the server. Handed to whoever listens on
## [signal chat_received], exactly as the RPC it replaced did.
func _on_chat_line(_peer_id: int, payload: Dictionary) -> void:
	chat_received.emit(payload)


## Creates the child that mirrors the server's chat node.
##
## Named to match [DotServer]'s [code]chat_ref[/code] default, because the name is
## the routing.
func _ensure_chat() -> void:
	if _chat != null and is_instance_valid(_chat):
		return

	_chat = DotClientChat.new()
	_chat.name = "Chat"
	_chat.link = self
	add_child(_chat)


## The server's HUD line, countdown or cue. See [signal notice_received].
##
## Decoded through [method DotNotice.from_wire], which defaults and bounds every field:
## this is a Variant off the wire, and a server one build older or newer may send a shape
## this one has never seen. A payload that decodes to nothing is dropped here rather than
## handed to a HUD that would have to ask.
func _on_notice(_peer_id: int, payload: Dictionary) -> void:
	var notice := DotNotice.from_wire(payload)

	if notice.is_empty():
		return

	last_notice = notice
	DotLog.debug(CHANNEL, "notice", notice.describe())
	notice_received.emit(notice)


## The server explaining why it is about to close the connection.
##
## Sent before the socket closes, which is the only way a player learns they were
## banned rather than merely disconnected.
##
## A refusal for a protocol mismatch carries its code and detail, so a shell can tell
## "this build cannot play here" from a kick.
func _on_disconnect_notice(_peer_id: int, payload: Dictionary) -> void:
	var reason := DotEnvelope.text(payload, "reason")
	var code := DotEnvelope.text(payload, "code", DotError.CODE_FORBIDDEN)
	DotLog.info(CHANNEL, "disconnected by server", {"reason": reason, "code": code})
	last_error = DotError.make(code, reason, DotEnvelope.text(payload, "detail"))
	_set_phase(Phase.FAILED, reason)
	disconnected.emit(reason)
