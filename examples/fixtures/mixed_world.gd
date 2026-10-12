extends Node

## The game half of `mixed_transports`: a world whose only rule is "what one player says,
## every other player hears", relayed by the server the way a game relays a shot or a
## chat line. It is a script of its own, rather than a method on the suite, because a
## game's RPCs live on nodes inside the game scene, and that is the path that has to
## route the same way for a WebSocket peer and an ENet peer.

## Every instance in this process, keyed by its MultiplayerAPI's unique id (1 is the
## server). One process holds the server and both clients, so a static is the only place
## the suite can find the instance each one loaded.
static var instances: Dictionary = {}

## [from_peer, text] for every line this instance heard, reliable or not.
var heard: Array = []
## Sequence numbers of unreliable updates heard, per sender.
var moves: Dictionary = {}


func _ready() -> void:
	instances[multiplayer.get_unique_id()] = self


func _exit_tree() -> void:
	# By id would need the peer, which a disconnect has already taken away.
	for id: int in instances.keys():
		if instances[id] == self:
			instances.erase(id)


## A client says something; the server passes it on to everybody else.
@rpc("any_peer", "call_remote", "reliable")
func say(text: String) -> void:
	if not multiplayer.is_server():
		return
	var from := multiplayer.get_remote_sender_id()
	for peer in multiplayer.get_peers():
		if peer != from:
			hear.rpc_id(peer, from, text)


@rpc("authority", "call_remote", "reliable")
func hear(from: int, text: String) -> void:
	heard.append([from, text])


## The unreliable half: a stream of position-like updates, relayed the same way.
@rpc("any_peer", "call_remote", "unreliable")
func move(seq: int) -> void:
	if not multiplayer.is_server():
		return
	var from := multiplayer.get_remote_sender_id()
	for peer in multiplayer.get_peers():
		if peer != from:
			moved.rpc_id(peer, from, seq)


@rpc("authority", "call_remote", "unreliable")
func moved(from: int, seq: int) -> void:
	if not moves.has(from):
		moves[from] = []
	(moves[from] as Array).append(seq)
