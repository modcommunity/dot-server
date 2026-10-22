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
# 5: DotBotQuota (bot_quota, bot_quota_mode, bot_quota_empty); DotServer addon_set and
#    DotClientLink server_addons (shipped in v0.1.9 without a level of their own);
#    DotClientLink.rtt_ms().
# 6: DotClientLink net_meter() (its peer behind a dot-core DotMeteredPeer, level 3);
#    the heartbeat.ack carries "sv": {fps, var_ms, tick}.
# 7: the PROFILE signon stage: DotClientSession.State.PROFILE and profile_holds;
#    DotServer hold_profile(), release_profile(), refuse_profile();
#    DotServerConfig.profile_timeout_sec. Nothing on the wire: a client waits through it
#    in its own AUTHENTICATING phase, so every shipped client still joins.
# 8: replicated cvars reach clients: DotEnvelope.CVARS; DotConsole cvar_registered,
#    replicated_values(), is_replicated(); DotClientLink replicated_cvars,
#    replicated_cvar(), replicated_cvar_changed. Optional on the wire: an older client is
#    sent nothing and keeps its defaults.
# 9: a client's block list: scoreboard rows carry "key" (DotServer.player_key(), a
#    per-server salted digest of the account) and "peer"; DotClientLink
#    request_scoreboard() asks for one board without holding it ("once" on
#    SCOREBOARD_WANT). Optional on the wire both ways.
# 10: DotClientLink tls_connect_timeout_sec: a native WebSocket join to a public bare
#    host:port tries wss:// first (a listed server's game port is a TLS port). Nothing on
#    the wire.
# 11: DotServerConfig worker_threads / threads_net / threads_npc (cvars sv_worker_threads,
#    sv_threads_net, sv_threads_npc), net_snapshot_workers(), npc_workers(), and
#    DotServer.describe_threads() ("threads" in describe()). Nothing on the wire.
# 12: DotAdminCfg.load_groups and load_users read cfg/addons/dot_server/groups.yml and
#    permissions.yml and the operator's cfg/server/addons/dot_server/, with the flat cfg/<file>.yml as
#    a shim until 2026-12-31. Needs dot-core API level 16.
const LEVEL := 12
const OLDEST := 1
