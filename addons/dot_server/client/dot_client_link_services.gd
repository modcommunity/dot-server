@tool
extends "res://addons/dot_server/client/dot_client_link_signon.gd"

## Page visibility, scoreboard, replicated cvars, chat and notices of [DotClientLink].


## Subscribes to the browser's visibility events. No-op off-web.
## Not gated on [member background_keepalive] because a host can change it at runtime; the flag is checked where acted on.
## [signal page_visibility_changed] is about the page, so a game can pause or mute on a tab switch either way.
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
		# Coming back, the heartbeat timer resumes, but its next tick may be far off while the server
		# counts silence from the whole hidden time. Say something now rather than spend the nearly gone budget.
		_send_heartbeat()

	_flush_peer()


## Pushes what [code]rpc_id[/code] queued out of the socket without waiting for a frame.
## visibilitychange arrives as a JS-to-wasm call as the browser stops requestAnimationFrame, so the poll that would send it may never run again;
## an announcement that never leaves costs the player the slot it asked to keep.
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
	return send_kind(DotEnvelope.SCOREBOARD_WANT, {"open": open, "paged": true})


## Asks for ONE board, leaving a held board held; a client's block list (dot-chat's `sm`) uses it to learn who is here.
## The held state goes along, so a server that predates `once` reads "no change" instead of a close. False when not sent.
func request_scoreboard() -> bool:
	if not _connected:
		return false
	return send_kind(DotEnvelope.SCOREBOARD_WANT, {"open": _scoreboard_held, "once": true, "paged": true})


func _on_scoreboard(_peer_id: int, payload: Dictionary) -> void:
	if payload.has("pages"):
		_on_scoreboard_page(payload)
		return
	# A board older than the one held arrived late (ENet sends unreliable unordered); it
	# says nothing the newer one did not. One with no `seq` is from a server before it,
	# and is taken as it always was.
	if payload.has("seq") and scoreboard.has("seq") and int(payload["seq"]) <= int(scoreboard["seq"]):
		return
	scoreboard = payload
	scoreboard_received.emit(payload)


## Pages are unreliable and unordered. The board is rebuilt once every page of the newest seq is here, or when
## that seq's last page arrives, filling gaps from the previous seq's copy (and marking the board `partial`).
func _on_scoreboard_page(payload: Dictionary) -> void:
	var page := int(payload.get("page", 0))
	var pages := int(payload.get("pages", 1))
	var seq := int(payload.get("seq", 0))
	var epoch := int(payload.get("ep", 0))
	if page < 0 or pages < 1 or page >= pages:
		return
	# A new epoch is a restarted server: its seq starts again at 1, so nothing held is comparable.
	if epoch != _sb_epoch:
		_reset_scoreboard_state()
		_sb_epoch = epoch
	var now := Time.get_ticks_msec()
	var held: Variant = _sb_pages.get(page)
	if held != null and int((held as Dictionary)["seq"]) >= seq:
		return
	_sb_pages[page] = {"seq": seq, "pages": pages, "rows": payload.get("players", []), "t": now}
	if page == 0:
		_sb_head = payload.duplicate()
		for k in ["players", "page", "pages", "v", "ep"]:
			_sb_head.erase(k)
	var newest := 0
	for i in _sb_pages:
		newest = maxi(newest, int((_sb_pages[i] as Dictionary)["seq"]))
	if seq != newest or _sb_head.is_empty():
		return
	var ttl_msec := int(scoreboard_page_ttl_sec * 1000.0)
	var use: Array = []
	var partial := false
	var fresh := {}
	for i in pages:
		var entry: Variant = _sb_pages.get(i)
		if entry == null or int((entry as Dictionary)["pages"]) != pages:
			partial = true
			continue
		if int(entry["seq"]) != newest:
			partial = true
			if int(entry["seq"]) != newest - 1 or now - int(entry["t"]) > ttl_msec:
				continue
		else:
			for row in entry["rows"]:
				fresh[(row as Dictionary).get("peer", null)] = true
		use.append(entry)
	if partial and page != pages - 1:
		return
	# A peer on a newest page wins over the same peer on an older kept page.
	var rows: Array = []
	var seen := {}
	for entry in use:
		for row in entry["rows"]:
			var id: Variant = (row as Dictionary).get("peer", null)
			if id != null:
				if seen.has(id) or (int(entry["seq"]) != newest and fresh.has(id)):
					continue
				seen[id] = true
			rows.append(row)
	for i in _sb_pages.keys():
		if int(i) >= pages:
			_sb_pages.erase(i)
	var board := _sb_head.duplicate()
	board["players"] = rows
	board["seq"] = newest
	if partial:
		board["partial"] = true
	scoreboard = board
	scoreboard_received.emit(board)


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
## Named to match [DotServer]'s [code]chat_ref[/code] default, because the name is the routing.
func _ensure_chat() -> void:
	if _chat != null and is_instance_valid(_chat):
		return

	_chat = DotClientChat.new()
	_chat.name = "Chat"
	_chat.link = self
	add_child(_chat)


## The server's HUD line, countdown or cue. See [signal notice_received].
## Decoded through [method DotNotice.from_wire], which defaults and bounds every field, since a server one build off may send an unknown shape;
## a payload that decodes to nothing is dropped here rather than handed to a HUD.
func _on_notice(_peer_id: int, payload: Dictionary) -> void:
	var notice := DotNotice.from_wire(payload)

	if notice.is_empty():
		return

	last_notice = notice
	DotLog.debug(CHANNEL, "notice", notice.describe())
	notice_received.emit(notice)


## The server explaining why it is about to close the connection.
## Sent before the socket closes: the only way a player learns they were banned rather than disconnected.
## A protocol-mismatch refusal carries its code and detail, so a shell can tell "this build cannot play here" from a kick.
func _on_disconnect_notice(_peer_id: int, payload: Dictionary) -> void:
	var reason := DotEnvelope.text(payload, "reason")
	var code := DotEnvelope.text(payload, "code", DotError.CODE_FORBIDDEN)
	DotLog.info(CHANNEL, "disconnected by server", {"reason": reason, "code": code})
	last_error = DotError.make(code, reason, DotEnvelope.text(payload, "detail"))
	_set_phase(Phase.FAILED, reason)
	disconnected.emit(reason)
