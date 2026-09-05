@tool
extends EditorPlugin

## Editor entry point for dot-server. Registers inspector types only.
##
## No autoloads: a project may run a server and a client in one process — which is
## exactly what testing a listen server means — and a singleton would make that
## impossible.

const _ICON := "res://addons/dot_server/icon_placeholder.svg"

const _TYPES := [
	["DotServer", "Node", "res://addons/dot_server/server/dot_server.gd"],
	["DotConsole", "Node", "res://addons/dot_server/console/dot_console.gd"],
	["DotAdminManager", "Node", "res://addons/dot_server/admin/dot_admin_manager.gd"],
	["DotBanManager", "Node", "res://addons/dot_server/moderation/dot_ban_manager.gd"],
	["DotAuditLog", "Node", "res://addons/dot_server/moderation/dot_audit_log.gd"],
	["DotRconServer", "Node", "res://addons/dot_server/rcon/dot_rcon_server.gd"],
	["DotChatManager", "Node", "res://addons/dot_server/chat/dot_chat_manager.gd"],
	["DotGameManager", "Node", "res://addons/dot_server/game/dot_game_manager.gd"],
	["DotVoteManager", "Node", "res://addons/dot_server/vote/dot_vote_manager.gd"],
	["DotEventBus", "Node", "res://addons/dot_server/events/dot_event_bus.gd"],
	["DotModuleHost", "Node", "res://addons/dot_server/modules/dot_module_host.gd"],
	["DotClientLink", "Node", "res://addons/dot_server/client/dot_client_link.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	# Reversed so a type is never removed before something that referenced it,
	# which matters when the editor reloads the plugin.
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
