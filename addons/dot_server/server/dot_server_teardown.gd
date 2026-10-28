@tool
extends "res://addons/dot_server/server/dot_server_wire.gd"

## Chat submit, kicks and disconnects of [DotServer].

## A client sending chat. Handled by [DotChatManager], which is where every rule about
## chat lives; this only finds the session.
func _on_chat_submit(peer_id: int, payload: Dictionary) -> void:
	if chat == null:
		return
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return
	session.touch()
	chat.handle_message(
		session,
		DotEnvelope.text(payload, "text"),
		DotEnvelope.flag(payload, "team", false)
	)


## Disconnects a client with a reason they will see.
##
## [param why] rides along so a version mismatch reads as that, not as a kick; see [method DotClientLink.last_error].
func kick(session: DotClientSession, reason: String = "Kicked", why: DotError = null) -> DotResult:
	if session == null or not session.is_active():
		return DotResult.fail(DotError.CODE_INVALID, "No such player.")

	DotLog.info(
		CHANNEL, "kicked", {"user": session.label(), "reason": reason}
	)

	_notify_peer_disconnect(session.peer_id, reason, why)

	session.transition_to(DotClientSession.State.DISCONNECTED)
	_disconnect_peer(session.peer_id)

	_sessions.erase(session.peer_id)
	envelope.forget(session.peer_id)
	_by_userid.erase(session.userid)

	client_disconnected.emit(session, reason)

	if events != null:
		events.fire("client_kicked", {
			"userid": session.userid,
			"name": session.display_name,
			"reason": reason,
		})

	return DotResult.success(session)


func _reject_session(session: DotClientSession, reason: String, why: DotError = null) -> void:
	session.reject(reason)
	client_state_changed.emit(session)

	_notify_peer_disconnect(session.peer_id, reason, why)
	_disconnect_peer(session.peer_id)

	_sessions.erase(session.peer_id)
	envelope.forget(session.peer_id)
	_by_userid.erase(session.userid)


func _reject_peer(peer_id: int, reason: String) -> void:
	_notify_peer_disconnect(peer_id, reason)
	_disconnect_peer(peer_id)


func _notify_disconnect(session: DotClientSession, reason: String) -> void:
	_notify_peer_disconnect(session.peer_id, reason)


func _notify_peer_disconnect(peer_id: int, reason: String, why: DotError = null) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	var session: DotClientSession = _sessions.get(peer_id)
	if session != null and session.local:
		# Adopted sessions have no peer. Sending to one is an engine error on a path
		# that is otherwise working perfectly, which is how error output stops being
		# read at all.
		return
	# Sent before closing so the client can show why; the close follows deferred so the packet
	# leaves. The code and detail ride along so a shell can tell a mismatch from a kick.
	var payload := {"reason": reason}
	if why != null:
		payload["code"] = why.code
		payload["detail"] = why.detail
	send_kind(peer_id, DotEnvelope.DISCONNECT, payload)


func _disconnect_peer(peer_id: int) -> void:
	if multiplayer.multiplayer_peer == null:
		return

	var session: DotClientSession = _sessions.get(peer_id)
	if session != null and session.local:
		return
	# Deferred so a rejection message sent in the same frame actually goes out;
	# closing immediately drops it.
	_close_peer.call_deferred(peer_id)


## Flushes what is queued for a peer, then closes it after [constant CLOSE_GRACE_SEC].
## Closing in the same frame lost the reason: a closing client drops what it has not yet handed on.
## `poll()` sends now; the session is already gone, so nothing sent in between is handled.
func _close_peer(peer_id: int) -> void:
	var peer := multiplayer.multiplayer_peer if multiplayer != null else null
	if peer == null:
		return
	peer.poll()
	if is_inside_tree():
		await get_tree().create_timer(CLOSE_GRACE_SEC, true, false, true).timeout
	peer = multiplayer.multiplayer_peer if multiplayer != null else null
	if peer == null or peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	peer.disconnect_peer(peer_id)
