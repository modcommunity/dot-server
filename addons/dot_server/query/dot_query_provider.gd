class_name DotQueryProvider
extends RefCounted

## Where a game puts its own state into a query response.
##
## A server browser showing "de_dust2, 12/16" is showing a game that fits A2S's
## fixed fields. Any game that does not — a round number, per-team scores, the
## next map in rotation, a lobby's ready count, how much of a match is left — has
## historically had to smuggle it into the keywords string as
## [code]r3,t1:8,t2:5[/code] and hope. That is not a limitation worth reproducing.
##
## Subclass this, register it with [method DotQuerySource.add_provider], and write
## whatever the game knows into the snapshot. A provider may also correct the
## standard fields: the bot count is the obvious one, since only the game knows how
## many of its entities are bots.
##
## [codeblock]
## class ArenaQuery extends DotQueryProvider:
##     var match_state: DotMatchState
##
##     func _provider_name() -> String:
##         return "arena"
##
##     func _contribute(snapshot: DotQuerySnapshot) -> void:
##         snapshot.info["bots"] = match_state.bot_count()
##         snapshot.contribute_game({
##             "phase": match_state.phase_name(),
##             "round": match_state.round_number,
##             "scores": match_state.team_scores(),
##             "time_left": match_state.seconds_remaining(),
##         })
## [/codeblock]
##
## [b]A provider runs on the query path, which is reachable by anyone with the
## address.[/b] Keep it cheap and keep it free of anything a player should not see —
## the output is published to whoever asked. It is called at most once per rebuild
## interval, not once per query, so a flood costs one call.
##
## Registration is validated when it happens rather than when it is first called,
## so a mistyped provider is a startup error and not a section that silently never
## appears. Any object with [code]_contribute[/code] (or [code]contribute[/code])
## and a name is accepted, so a game can use a plain [Node] it already has instead
## of holding a second object alive.


## Identifier shown in `query_status` and used to remove the provider again.
func _provider_name() -> String:
	return "provider"


## Adds to, or corrects, the snapshot. Called after the standard sections are built.
func _contribute(_snapshot: DotQuerySnapshot) -> void:
	pass


# --- Duck-typed dispatch ---------------------------------------------------

## Checks an object can act as a provider, before it is registered.
static func validate(provider: Object) -> DotResult:
	if provider == null:
		return DotResult.fail(DotError.CODE_INVALID, "A provider cannot be null.")

	if not (provider.has_method("_contribute") or provider.has_method("contribute")):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A query provider needs a _contribute(snapshot) method.",
			"got a %s" % provider.get_class()
		)

	return DotResult.success(provider)


static func name_of(provider: Object) -> String:
	if provider == null:
		return ""
	if provider.has_method("_provider_name"):
		return str(provider.call("_provider_name"))
	if provider.has_method("provider_name"):
		return str(provider.call("provider_name"))
	if provider is Node:
		return str((provider as Node).name)
	return provider.get_class()


static func contribute_to(provider: Object, snapshot: DotQuerySnapshot) -> void:
	if provider == null:
		return
	if provider.has_method("_contribute"):
		provider.call("_contribute", snapshot)
		return
	if provider.has_method("contribute"):
		provider.call("contribute", snapshot)
