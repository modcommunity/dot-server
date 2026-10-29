@tool
class_name DotSignon
extends Object

## What a client and a server must agree about before either can speak: both ends' sorted
## [code]@rpc[/code] names, hashed from [method Script.get_rpc_config] (never written down).
## The engine only says "rpc node checksum failed"; this names it. See docs/signon.md.

# No log channel: static and pure. explain() builds the error rather than logging it,
# because the caller holds what the line needs -- DotClientLink logs a mismatch at ERROR
# with the host it was talking to.

## Bumped only for a change the method names cannot express (a field changing type, a challenge
## that starts requiring something). 2 when every RPC but six became a kind on [DotEnvelope].
const PROTOCOL := 2

## The six RPC names both ends declare, and the only six; see [DotEnvelope]. Written down because
## it must NOT move: `signon_revision` fails the commit that adds a seventh.
const ENVELOPE: Array[String] = [
	"_dot_down", "_dot_down_event", "_dot_down_unreliable",
	"_dot_up", "_dot_up_event", "_dot_up_unreliable",
]

## How much of the hash is shown. Twelve hex characters, matching dot-net's schema hash,
## which is the other half of this handshake and is printed beside it.
const REVISION_LENGTH := 12


## The signon revision of one side: pass the scripts carrying its [code]@rpc[/code] methods
## ([DotServer] or [DotClientLink]); order does not matter. Scripts, passed in, because
## preloading [DotServer] here would make a cycle GDScript fails to parse.
static func revision(scripts: Array) -> String:
	var names := rpc_method_names(scripts)

	if names.is_empty():
		# Not a hash of nothing: an empty answer has to be distinguishable from a real
		# one, or a build where this could not be computed would advertise a revision
		# every other build disagrees with and look like a protocol break.
		return ""

	return DotHash.sha256_text("\n".join(names)).substr(0, REVISION_LENGTH)


## Every [code]@rpc[/code] method name the given scripts declare, sorted (the engine's id order)
## and unique, so two machines agree.
static func rpc_method_names(scripts: Array) -> PackedStringArray:
	var seen := {}

	for entry in scripts:
		var script: Script = entry as Script

		if script == null:
			continue

		# Guarded: a runtime without `get_rpc_config` would yield an empty name set, which
		# [method revision] turns into "unknown" rather than a hash everyone disagrees with.
		if not script.has_method("get_rpc_config"):
			continue

		for method in script.get_rpc_config().keys():
			seen[String(method)] = true

	var names := PackedStringArray(seen.keys())
	names.sort()
	return names


## Whether two revisions can complete a join. An empty revision on either side is NOT a mismatch:
## a server older than this class sends none, and refusing it would break deployed pairs.
static func compatible(ours: String, theirs: String) -> bool:
	if ours == "" or theirs == "":
		return true
	return ours == theirs


## What to tell a player, and what to log, when the two do not match: the shape of the fix, not
## the cause, since a player cannot act on an [code]@rpc[/code] method.
static func explain(ours: String, theirs: String) -> DotError:
	return DotError.make(
		DotError.CODE_UNSUPPORTED,
		"This server needs a different build of the game client.",
		"the server's signon revision is %s and this client is %s -- they were built "
		% [theirs, ours]
		+ "against different versions of dot-server, and Godot will not complete a "
		+ "join between them"
	)


## The same refusal for a [constant PROTOCOL] that differs: a kind that kept its name and
## changed its meaning, so the revision alone cannot see it.
static func explain_protocol(ours: int, theirs: int) -> DotError:
	return DotError.make(
		DotError.CODE_UNSUPPORTED,
		"This server needs a different build of the game client.",
		"the server speaks signon protocol %d and this client %d" % [theirs, ours]
	)


## For a console command, a server listing, and the query response.
static func describe(scripts: Array) -> Dictionary:
	var names := rpc_method_names(scripts)
	return {
		"protocol": PROTOCOL,
		"revision": revision(scripts),
		"rpc_methods": names.size(),
		"names": names,
	}
