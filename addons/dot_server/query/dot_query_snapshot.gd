class_name DotQuerySnapshot
extends RefCounted

## What the server looks like from outside, at one moment.
##
## Both query protocols read this and nothing else. A2S flattens it into its fixed
## byte layout and loses most of it; DQP serialises it as-is. That is deliberate:
## a game contributes its state once, and both listeners — and anything else that
## wants server state, like the backbone stats report — see the same numbers. Two
## code paths gathering the same facts is two code paths that disagree the first
## time one is changed.
##
## Sections are separate because a querier wants different ones at different times.
## A server browser refreshing a list wants [code]info[/code] alone, twenty times a
## second across a thousand servers; a player looking at one server wants
## [code]players[/code] too. A2S has the same split and it is the right one.

const SECTION_INFO := "info"
const SECTION_PLAYERS := "players"
const SECTION_RULES := "rules"
const SECTION_GAME := "game"

const ALL_SECTIONS: Array[String] = [
	SECTION_INFO, SECTION_PLAYERS, SECTION_RULES, SECTION_GAME
]

## Monotonic revision, bumped only when the content actually changed.
##
## What makes conditional polling work: a tracker sends the revision it holds and
## a server that has not changed replies with a few dozen bytes instead of a few
## kilobytes. Derived from [member etag] rather than from a timer, so a server
## sitting idle for an hour keeps the same revision for that hour.
var rev: int = 0

## Hash of the content, which is what [member rev] is derived from.
var etag: String = ""

## Unix seconds this snapshot was built.
var built_at: int = 0

## Identity, counts, addresses. The section a server browser lists from.
var info: Dictionary = {}

## One entry per connected client. May be empty by policy.
var players: Array = []

## Server variables a querier is allowed to see.
var rules: Dictionary = {}

## Whatever the game contributes: round number, scores, teams, next map.
##
## Free-form on purpose. This is the section A2S has no room for, and the reason a
## game currently has to smuggle its state into the keywords string.
var game: Dictionary = {}

## Sections that were cut short by a size or policy limit.
##
## Reported rather than silently truncated, because a tracker showing 128 of 400
## players with no indication is worse than one showing none.
var truncated: PackedStringArray = PackedStringArray()


func _init() -> void:
	built_at = int(Time.get_unix_time_from_system())


# --- Access ----------------------------------------------------------------

func section(name: String) -> Variant:
	match name:
		SECTION_INFO: return info
		SECTION_PLAYERS: return players
		SECTION_RULES: return rules
		SECTION_GAME: return game
	return null


func has_section(name: String) -> bool:
	return ALL_SECTIONS.has(name)


func mark_truncated(name: String) -> void:
	if not truncated.has(name):
		truncated.append(name)


## Convenience for providers: merge a dictionary into the game section.
func contribute_game(values: Dictionary) -> void:
	for key in values:
		game[key] = values[key]


func player_count() -> int:
	return int(info.get("players", 0))


func bot_count() -> int:
	return int(info.get("bots", 0))


# --- Serialisation ---------------------------------------------------------

## The DQP response body, carrying only the sections that were asked for.
##
## Unknown section names are reported in [code]unknown[/code] rather than ignored:
## a querier that misspells one otherwise sees an empty result and concludes the
## server has no players.
func to_dict(sections: PackedStringArray = PackedStringArray()) -> Dictionary:
	var wanted := sections
	if wanted.is_empty():
		wanted = PackedStringArray([SECTION_INFO])

	var out := {
		"rev": rev,
		"etag": etag,
		"ts": built_at,
		"sections": {},
	}

	var unknown := PackedStringArray()
	var body: Dictionary = out["sections"]

	for name in wanted:
		if not has_section(name):
			unknown.append(name)
			continue
		body[name] = section(name)

	if not unknown.is_empty():
		out["unknown"] = Array(unknown)

	if not truncated.is_empty():
		out["truncated"] = Array(truncated)

	return out


## The body sent when a querier already holds this revision.
func to_unchanged_dict() -> Dictionary:
	return {"rev": rev, "etag": etag, "ts": built_at, "unchanged": true}


## Everything, for `query_status` and for a bug report.
func to_full_dict() -> Dictionary:
	return to_dict(PackedStringArray(ALL_SECTIONS))


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("rev         %d (%s)" % [rev, etag.substr(0, 12)])
	out.append("built       %d seconds ago" % [
		int(Time.get_unix_time_from_system()) - built_at
	])
	out.append("name        %s" % str(info.get("name", "")))
	out.append("map         %s" % str(info.get("map", "")))
	out.append("players     %d/%d (%d bots, %d connecting)" % [
		int(info.get("players", 0)),
		int(info.get("max_players", 0)),
		int(info.get("bots", 0)),
		int(info.get("connecting", 0)),
	])
	out.append("listed      %d players, %d rules, %d game keys" % [
		players.size(), rules.size(), game.size()
	])
	if not truncated.is_empty():
		out.append("truncated   %s" % ", ".join(Array(truncated)))
	return out
