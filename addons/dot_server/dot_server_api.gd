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
# 4: the scoreboard roster: DotServer scoreboard_fields, scoreboard_extra,
#    scoreboard_interval_sec, scoreboard_snapshot(), SCOREBOARD_MAX_ROWS;
#    DotClientSession wants_scoreboard; DotClientLink want_scoreboard(), scoreboard,
#    scoreboard_received; DotEnvelope SCOREBOARD and SCOREBOARD_WANT.
const LEVEL := 4
const OLDEST := 1
