@tool
class_name DotClientLink
extends "res://addons/dot_server/client/dot_client_link_services.gd"

## The client's half of the connection to a [DotServer]: the six envelope RPCs (the same six, and they never change), content sync, the game scene, chat.
## A game or addon adds a kind with [member envelope], never an RPC; see [DotEnvelope].


func _ready() -> void:
	_ensure_chat()

	if Engine.is_editor_hint():
		return

	DotRegistry.register(SERVICE, self)

	if game_root_ref == null:
		game_root_ref = DotNodeRef.of_created(&"GameRoot", Node)
	_game_root = game_root_ref.resolve_or_null(self, CHANNEL)

	_heartbeat = Timer.new()
	_heartbeat.wait_time = heartbeat_interval_sec
	_heartbeat.timeout.connect(_send_heartbeat)
	add_child(_heartbeat)

	_signon_watchdog = Timer.new()
	_signon_watchdog.one_shot = true
	_signon_watchdog.timeout.connect(_on_signon_timeout)
	add_child(_signon_watchdog)

	_watch_page_visibility()


func _exit_tree() -> void:
	_load_gen += 1
	DotRegistry.unregister_instance(SERVICE, self)

	if _visibility_key != "":
		DotWeb.unwatch_visibility(_visibility_key)
		_visibility_key = ""


func _make_envelope() -> DotEnvelope:
	var env := DotEnvelope.new()
	env.register_core()
	env.handle(DotEnvelope.CHALLENGE, _on_challenge)
	env.handle(DotEnvelope.CONTENT_SYNC, _on_content_sync)
	env.handle(DotEnvelope.LOAD_GAME, _on_load_game)
	env.handle(DotEnvelope.HEARTBEAT_ACK, _on_heartbeat_ack)
	env.handle(DotEnvelope.NOTICE, _on_notice)
	env.handle(DotEnvelope.DISCONNECT, _on_disconnect_notice)
	env.handle(DotEnvelope.CHAT_LINE, _on_chat_line)
	env.handle(DotEnvelope.SCOREBOARD, _on_scoreboard)
	env.handle(DotEnvelope.CVARS, _on_cvars)
	return env


## Sends a kind to the server. False when it was not sent: not connected, or a server
## that does not know the kind -- which is what an older server looks like, and is not an
## error. See [DotEnvelope].
func send_kind(
	kind: StringName,
	payload: Dictionary = {},
	lane: DotEnvelope.Lane = DotEnvelope.Lane.CONTROL
) -> bool:
	if multiplayer == null or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	if not envelope.should_send(1, kind):
		return false

	match lane:
		DotEnvelope.Lane.UNRELIABLE:
			_dot_up_unreliable.rpc_id(1, String(kind), payload)
		DotEnvelope.Lane.EVENT:
			_dot_up_event.rpc_id(1, String(kind), payload)
		_:
			_dot_up.rpc_id(1, String(kind), payload)
	return true


## The same six as [DotServer]'s, by name -- the names are the checksum. See the note
## there before adding one: the answer is a kind, never a seventh method.
@rpc("authority", "reliable", "call_remote", CHANNEL_CONTROL)
func _dot_down(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(1, kind, payload)


@rpc("authority", "unreliable", "call_remote", CHANNEL_CONTROL)
func _dot_down_unreliable(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(1, kind, payload)


@rpc("authority", "reliable", "call_remote", CHANNEL_EVENT)
func _dot_down_event(kind: Variant, payload: Variant) -> void:
	envelope.dispatch(1, kind, payload)


@rpc("any_peer", "reliable", "call_remote", CHANNEL_CONTROL)
func _dot_up(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("any_peer", "unreliable", "call_remote", CHANNEL_CONTROL)
func _dot_up_unreliable(_kind: Variant, _payload: Variant) -> void:
	pass


@rpc("any_peer", "reliable", "call_remote", CHANNEL_EVENT)
func _dot_up_event(_kind: Variant, _payload: Variant) -> void:
	pass
