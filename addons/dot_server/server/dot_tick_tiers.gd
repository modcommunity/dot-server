class_name DotTickTiers
extends RefCounted

## A table mapping a player count to a tick rate, from one string:
## [code]players<=32:66,<=64:33,else:22[/code]
##
## [b]Why.[/b] A server's cost is per player per tick, so the rate a server can hold falls as it fills
## (measured on the arena: ~16-20 players at 66 Hz, ~16-28 at 33 Hz, ~32-48 at 22 Hz on one core).
## An operator who wants 128 slots picks the rate by the slot count instead of by hand.
##
## [b]Grammar.[/b] Comma-separated tiers, first match wins. A tier is [code][players]<=N:RATE[/code]
## (the [code]players[/code] word is optional) or [code]else:RATE[/code] / [code]RATE[/code] alone as the catch-all.
## Rates are clamped to [constant MIN_RATE]..[constant MAX_RATE]. An empty string is "off".
## A string that does not parse is "off" too ([member error] says why), never a half-read table.

## The slowest and fastest rate a table may name.
const MIN_RATE := 15
const MAX_RATE := 128

## [code][max_players, rate][/code] pairs, rising in player count.
var tiers: Array = []
var fallback: int = 0
var error: String = ""


## The table [param spec] names. [member error] is empty when it parsed; an empty [param spec] is a valid, empty table.
static func parse(spec: String) -> DotTickTiers:
	var table := DotTickTiers.new()
	var text := spec.strip_edges()
	if text == "":
		return table

	var last_limit := -1
	for raw in text.split(",", false):
		var part := raw.strip_edges().to_lower()
		if part.begins_with("players"):
			part = part.substr(7).strip_edges()
		var colon := part.find(":")
		var head := part.substr(0, colon).strip_edges() if colon >= 0 else "else"
		var rate_text := part.substr(colon + 1).strip_edges() if colon >= 0 else part
		if not rate_text.is_valid_int():
			return _fail(table, "tier '%s' has no whole-number rate" % raw.strip_edges())
		var rate := clampi(rate_text.to_int(), MIN_RATE, MAX_RATE)

		if head == "else" or head == "*":
			if table.fallback != 0:
				return _fail(table, "two catch-all tiers")
			table.fallback = rate
			continue

		if not head.begins_with("<="):
			return _fail(table, "tier '%s' must read <=N:RATE or else:RATE" % raw.strip_edges())
		var limit_text := head.substr(2).strip_edges()
		if not limit_text.is_valid_int() or limit_text.to_int() < 0:
			return _fail(table, "tier '%s' has no player limit" % raw.strip_edges())
		var limit := limit_text.to_int()
		if limit <= last_limit or table.fallback != 0:
			return _fail(table, "tiers must rise in player count and end with else")
		last_limit = limit
		table.tiers.append([limit, rate])

	return table


static func _fail(table: DotTickTiers, why: String) -> DotTickTiers:
	table.tiers.clear()
	table.fallback = 0
	table.error = why
	return table


## True when the table names no rate (empty or unparsed): the plain [code]sv_tickrate[/code] stands.
func is_off() -> bool:
	return tiers.is_empty() and fallback == 0


## The rate for [param players], or [param default_rate] when the table is off or no tier matches
## (a table without an [code]else[/code] tier leaves the rest at the default).
func rate_for(players: int, default_rate: int) -> int:
	for tier in tiers:
		if players <= int(tier[0]):
			return int(tier[1])
	return fallback if fallback != 0 else default_rate
