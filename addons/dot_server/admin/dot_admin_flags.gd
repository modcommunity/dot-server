class_name DotAdminFlags
extends RefCounted

## Permission flags and immunity, modelled on the admin systems community servers
## have run for twenty years.
##
## [b]Why flags rather than roles.[/b] Server operators do not agree on what a
## "moderator" is. One community's moderators can change the map, another's cannot.
## A fixed role hierarchy forces every server to either accept someone else's
## definition or bypass the system. Flags let a server define its own roles by
## composition, and the addon never has to have an opinion.
##
## [b]Why immunity is separate from flags.[/b] "May kick" and "may be kicked" are
## different questions. Without immunity, any two admins with [constant KICK] can
## kick each other, and there is no correct resolution — so a numeric level decides,
## and equal levels cannot act on each other at all.
##
## Flags are strings rather than bits so a game can add its own
## ([code]"slay"[/code], [code]"noclip"[/code], [code]"give_weapon"[/code]) without
## coordinating with this file or running out of bits.

# --- Standard flags --------------------------------------------------------

## Everything. Bypasses every check including immunity.
##
## Give it to nobody you would not give the server's shell to.
const ROOT := "root"

## Reserved slot: may join a full server.
const RESERVATION := "reservation"

## Generic admin — the baseline that marks somebody as staff at all.
const GENERIC := "generic"

const KICK := "kick"
const BAN := "ban"
const UNBAN := "unban"

## Mute and gag.
const MUTE := "mute"

## Change the current game or map.
const CHANGEMAP := "changemap"

## Change console variables.
const CVAR := "cvar"

## Change cheat-flagged console variables. Deliberately distinct from
## [constant CVAR]: "may adjust the round timer" is not "may turn on noclip".
const CHEATS := "cheats"

## Execute config files and reload configuration.
const CONFIG := "config"

## Use RCON at all.
const RCON := "rcon"

## Send admin chat and see it.
const CHAT := "chat"

## Start votes, and end them early.
const VOTE := "vote"

## Bypass the server password.
const PASSWORD := "password"

## Load, unload and reload server modules.
const MODULES := "modules"

## Read logs and the audit trail.
const LOGS := "logs"

## Manage other admins.
##
## Effectively grants everything indirectly — anyone who can add an admin can add
## themselves with more flags — so it is separated out and worth guarding as
## closely as [constant ROOT].
const ADMIN := "admin"

## Every flag this addon defines. A game's own flags are simply not in this list.
const ALL: Array[String] = [
	ROOT, RESERVATION, GENERIC, KICK, BAN, UNBAN, MUTE, CHANGEMAP,
	CVAR, CHEATS, CONFIG, RCON, CHAT, VOTE, PASSWORD, MODULES, LOGS, ADMIN,
]

## Human-readable descriptions, for `admin_flags` output.
const DESCRIPTIONS := {
	ROOT: "everything, including bypassing immunity",
	RESERVATION: "join a full server",
	GENERIC: "recognised as staff",
	KICK: "kick players",
	BAN: "ban players",
	UNBAN: "remove bans",
	MUTE: "mute and gag players",
	CHANGEMAP: "change the game or map",
	CVAR: "change console variables",
	CHEATS: "change cheat-flagged variables",
	CONFIG: "execute config files",
	RCON: "use remote console",
	CHAT: "use admin chat",
	VOTE: "start and end votes",
	PASSWORD: "bypass the server password",
	MODULES: "load and unload modules",
	LOGS: "read logs and the audit trail",
	ADMIN: "manage other admins",
}

# --- Immunity -------------------------------------------------------------

## Immunity of a player with no admin entry.
const NO_IMMUNITY := 0

## Ceiling. The local console and [constant ROOT] hold this.
const MAX_IMMUNITY := 100


## Whether [param held] satisfies a requirement for [param needed].
##
## [constant ROOT] satisfies everything. An empty requirement is satisfied by
## anybody — that is what marks a command as public.
static func granted(held: PackedStringArray, needed: String) -> bool:
	if needed == "":
		return true
	if held.has(ROOT):
		return true
	return held.has(needed)


## Whether [param held] satisfies every flag in [param needed].
static func granted_all(held: PackedStringArray, needed: PackedStringArray) -> bool:
	if held.has(ROOT):
		return true
	for flag in needed:
		if not held.has(flag):
			return false
	return true


## Whether [param held] satisfies any flag in [param needed].
static func granted_any(held: PackedStringArray, needed: PackedStringArray) -> bool:
	if needed.is_empty():
		return true
	if held.has(ROOT):
		return true
	for flag in needed:
		if held.has(flag):
			return true
	return false


## Parses a flag list from a config string.
##
## Accepts [code]"kick,ban"[/code], [code]"kick ban"[/code] and
## [code]"kick, ban"[/code], because all three appear in hand-edited files and
## refusing two of them is a support burden with no upside.
static func parse(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var normalised := text.replace(",", " ")

	for token in normalised.split(" ", false):
		var flag := token.strip_edges().to_lower()
		if flag != "" and not out.has(flag):
			out.append(flag)

	return out


static func format(flags: PackedStringArray) -> String:
	if flags.is_empty():
		return "(none)"
	var sorted := flags.duplicate()
	sorted.sort()
	return ", ".join(sorted)


## Merges flag lists, dropping duplicates.
##
## How group membership composes: a player in two groups holds the union of both.
static func merge(a: PackedStringArray, b: PackedStringArray) -> PackedStringArray:
	var out := a.duplicate()
	for flag in b:
		if not out.has(flag):
			out.append(flag)
	return out


## Flags that are not in [constant ALL] — a game's own, or a typo.
##
## Reported at load rather than refused: refusing unknown flags would break every
## game that defines its own, and silently accepting them makes
## [code]"kcik"[/code] indistinguishable from a custom flag.
static func unknown(flags: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for flag in flags:
		if not ALL.has(flag):
			out.append(flag)
	return out


static func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for flag in ALL:
		out.append("%-14s %s" % [flag, DESCRIPTIONS.get(flag, "")])
	return out
