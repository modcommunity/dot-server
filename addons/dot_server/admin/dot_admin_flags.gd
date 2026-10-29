class_name DotAdminFlags
extends RefCounted

## Permission flags and immunity. Flags are strings so a game adds its own and a server composes
## its own roles; immunity is a separate numeric level ("may kick" is not "may be kicked"), and
## equal levels cannot act on each other.


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

## Change cheat-flagged console variables, and use a game's cheats on players: noclip,
## god mode, setting health, speed and gravity, giving and stripping items. Deliberately
## distinct from [constant CVAR]: "may adjust the round timer" is not "may turn on noclip".
const CHEATS := "cheats"

## May toggle noclip on themselves, and nothing else of [constant CHEATS]. A game that offers a free-fly key checks this (or CHEATS, which implies it).
const NOCLIP := "noclip"

## Act on a player's body without changing the rules (slay, slap, freeze, respawn, rename, burn).
## Not [constant CHEATS] on purpose: freezing a griefer is not giving somebody a rocket launcher.
## dot-moderation's [code]DotModToolCommands[/code] checks it.
const SLAY := "slay"

## Move players: bring, goto, send, return. Separate from [constant SLAY] because
## teleporting is the power that looks most like cheating from the outside — "an admin
## moved themselves behind me" — and a community may want it held more narrowly.
const TELEPORT := "teleport"

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

## Manage other admins. Effectively grants everything (one can add oneself with more flags),
## so guard it like [constant ROOT].
const ADMIN := "admin"

## Every flag this addon defines. A game's own flags are simply not in this list.
const ALL: Array[String] = [
	ROOT, RESERVATION, GENERIC, KICK, BAN, UNBAN, MUTE, CHANGEMAP,
	CVAR, CHEATS, NOCLIP, SLAY, TELEPORT, CONFIG, RCON, CHAT, VOTE, PASSWORD, MODULES, LOGS, ADMIN,
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
	NOCLIP: "toggle noclip on yourself",
	CHEATS: "change cheat-flagged variables; noclip, god, health, speed, give",
	SLAY: "slay, slap, freeze, respawn and rename players",
	TELEPORT: "bring, goto, send and return players",
	CONFIG: "execute config files",
	RCON: "use remote console",
	CHAT: "use admin chat",
	VOTE: "start and end votes",
	PASSWORD: "bypass the server password",
	MODULES: "load and unload modules",
	LOGS: "read logs and the audit trail",
	ADMIN: "manage other admins",
}


## Immunity of a player with no admin entry.
const NO_IMMUNITY := 0

## Ceiling. The local console and [constant ROOT] hold this.
const MAX_IMMUNITY := 100


## Whether [param held] satisfies a requirement for [param needed]. [constant ROOT] satisfies
## everything; an empty requirement is satisfied by anybody (a public command).
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


## Parses a flag list: [code]"kick,ban"[/code], [code]"kick ban"[/code] and [code]"kick, ban"[/code]
## all appear in hand-edited files.
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


## Flags not in [constant ALL] (a game's own, or a typo). Reported at load, not refused, which
## would break games defining their own flags.
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
