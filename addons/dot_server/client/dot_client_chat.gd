class_name DotClientChat
extends Node

## The client's half of chat: a node named `Chat` under [DotClientLink].
##
## [b]It used to be an RPC shim and is not any more.[/b] It existed so its two
## [code]@rpc[/code] methods sat at the same node path as [DotChatManager]'s, because
## Godot routes an RPC by path and refuses the pair unless both ends declare the same set.
## Chat is two kinds on the envelope now -- `chat.submit` up and `chat.line` down, see
## [DotEnvelope] -- so neither node declares an RPC and neither can break the other. The
## node stays because games reach chat through it, and [method send] is its whole job.

# No log channel: a message is logged, filtered and rate-limited by DotChatManager on the
# server, and what arrives is handed to DotClientLink.chat_received for the game to show.

## The link this reports to. Set by [DotClientLink] when it creates this node.
var link: DotClientLink = null


## Sends a chat message to the server. False when it was not sent -- not connected, or a
## server that does not take chat.
func send(text: String, team_only: bool = false) -> bool:
	if link == null:
		return false
	return link.send_kind(
		DotEnvelope.CHAT_SUBMIT, {"text": text, "team": team_only}, DotEnvelope.Lane.EVENT
	)
