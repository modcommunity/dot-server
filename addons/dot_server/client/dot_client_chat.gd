class_name DotClientChat
extends Node

## The client's half of chat: a node named `Chat` under [DotClientLink].
## Chat is two envelope kinds (`chat.submit` up, `chat.line` down), so the node declares no RPC.
## It stays because games reach chat through it; [method send] is its whole job.

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
