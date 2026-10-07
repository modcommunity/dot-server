extends RefCounted

## dot-server's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 2: DotGameDescriptor.server_dependencies and .maps; DotGameManager
#    current_server_dependencies() and current_maps().
# 3: DotServerConfig transport_mode, enet_port, enet_bind_address, enet_share_udp_port;
#    DotServer share_udp_port(), unshare_udp_port(), enet_port(), peer_transport();
#    DotClientLink transport_preference, udp_address, udp_connect_timeout_sec,
#    transport_used.
const LEVEL := 3
const OLDEST := 1
