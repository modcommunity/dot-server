extends RefCounted

## dot-server's API level. The rule for bumping it is on [DotAddonApi].
## LEVEL rises by one for anything new a game could call; OLDEST is raised to LEVEL when something is
## removed or changes meaning, because every pack built before that no longer compiles.

# What each level added: docs/api-levels.md.
const LEVEL := 15
const OLDEST := 1
