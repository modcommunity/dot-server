class_name DotClientChat
extends Node

## The client's half of chat. Exists so the RPC node paths line up.
##
## [b]Why this is a separate node and not two methods on [DotClientLink].[/b] Godot
## routes an RPC by the receiver's node path relative to its [MultiplayerAPI] root,
## and it refuses the call outright unless both ends declare the [i]same set[/i] of
## [code]@rpc[/code] methods — it compares a checksum over them.
##
## On the server, chat lives on [DotChatManager], a child of [DotServer] named
## [code]Chat[/code]. Declaring the same two methods on [DotClientLink] therefore
## broke twice over: the paths did not match, and the extra pair changed
## [DotClientLink]'s checksum so that [i]every[/i] RPC between client and server was
## refused — including the handshake. A client could open a socket and then never
## complete signon, with the only symptom a timeout.
##
## Nothing caught it because the handshake needs a client and a server at once, and
## dot-server's own self-test runs a server alone. dot-platform's
## [code]sandbox_server[/code] example is what found it, on its first run.
##
## So: same name as the server's node, same two methods, nothing else.

const CHANNEL := "server.client"

## Matches [constant DotTransport.Channel.EVENT] on the server side.
const CHANNEL_EVENT := 2

## The link this reports to. Set by [DotClientLink] when it creates this node.
var link: DotClientLink = null


## Sends a chat message to the server.
func send(text: String, team_only: bool = false) -> void:
	submit_chat.rpc_id(1, text, team_only)


## Implemented on the server by [DotChatManager].
@rpc("any_peer", "reliable", "call_remote", CHANNEL_EVENT)
func submit_chat(_text: String, _team_only: bool) -> void:
	pass


## A chat message from the server.
@rpc("authority", "reliable", "call_remote", CHANNEL_EVENT)
func _receive_chat(payload: Dictionary) -> void:
	if link != null:
		link.chat_received.emit(payload)
