extends RefCounted

## dot-server's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 2: DotGameDescriptor.server_dependencies and .maps; DotGameManager
#    current_server_dependencies() and current_maps().
const LEVEL := 2
const OLDEST := 1
