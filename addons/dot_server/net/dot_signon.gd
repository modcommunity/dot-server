@tool
class_name DotSignon
extends Object

## What a client and a server have to agree about before either can say a word.
##
## [b]Godot refuses an RPC unless both ends declare the same set of [code]@rpc[/code]
## methods on the node, and that refusal is the least legible failure in this
## project.[/b] A client built before [method DotClientLink.client_visibility] existed
## meets a server built after it, and what happens is:
##
## [codeblock]
## ERROR: The rpc node checksum failed. Make sure to have the same methods on both
##        nodes. Node path: /root/Server
## [/codeblock]
##
## ...and then the client sits in [code]AUTHENTICATING[/code] until the server times it
## out. Neither end says "version mismatch". The server reports a client that would not
## answer its challenge; the player sees a spinner and then "Timed out". The only way to
## find out what actually happened is to have been told, once, by somebody who had seen
## it before.
##
## This class is that fact, made checkable:
##
## [codeblock]
## var rev := DotSignon.revision([DotServer])       # on the server
## var rev := DotSignon.revision([DotClientLink])    # on the client
## [/codeblock]
##
## The two sides run different scripts and must produce the SAME string, because what
## Godot compares is the method NAMES and the pairs are named to match. A revision that
## differs is a client and a server that cannot complete a join, said in twelve
## characters that fit in a handshake, a server listing and a URL.
##
## [b]Derived, never written down.[/b] A hand-bumped constant is a second list, and a
## second list in this project is a list that goes stale -- the games were named by
## their old directory names in three files at once for weeks. [method revision] reads
## [method Script.get_rpc_config], which is the same declaration Godot itself
## checksums, so it cannot disagree with the engine about what was declared.
##
## [b]What is in the hash is method names and nothing else, and that was measured
## rather than assumed.[/b] Two nodes whose methods differ only in transfer mode or
## channel talk to each other perfectly -- the RPC id is an index into the sorted names,
## so only the names decide. Hashing the modes as well would report an incompatibility
## the engine does not have, and send a player to an older build for no reason.
##
## [b]Since 2026-09-26 the revision is the hash of six names that do not change.[/b]
## Every message is a kind inside [constant ENVELOPE]'s six RPCs, so a feature added on
## one end moves nothing here; what two builds disagree about is settled by the kinds each
## advertises -- see [DotEnvelope]. This class is still what catches a build whose
## ENVELOPE differs, and there should never be another.
##
## [b]The challenge still arrives when the checksum has already failed, which is what
## makes this work at all.[/b] The first call to a node goes out by full path; the
## checksum failure kills the path CACHE confirmation, not that first call. So a server
## whose revision this client cannot match still manages to deliver the one message
## carrying the revision -- and the client can say so, immediately, instead of waiting
## out a timeout for a reason nobody will guess.

# No log channel: static and pure. explain() builds the error rather than logging it,
# because the caller holds what the line needs -- DotClientLink logs a mismatch at ERROR
# with the host it was talking to.

## Bumped only for a change the method names cannot express.
##
## The revision below covers the RPC surface, which is what actually breaks. This is for
## a change in what a message MEANS while its name stays put -- a field that changes
## type, a challenge that starts requiring something. Nothing has needed it yet, and the
## right number of times to have bumped it is zero.
##
## [b]2 since 2026-09-26[/b], when every RPC but six became a kind on [DotEnvelope]. That
## change moved the revision too, and is the last one that should: the envelope's names
## are what is hashed now, and a feature is a kind rather than a method. A client that
## predates it meets a server that sends kinds on RPCs it never declared, and ends at its
## own signon watchdog ("said nothing") -- the old build's words, which is the best a
## build that old can do.
const PROTOCOL := 2

## The six RPC names both ends declare, and the only six. See [DotEnvelope].
##
## Written down, unlike everything else here, because it is the one thing that must NOT
## move: `signon_revision` asserts that [DotServer] and [DotClientLink] declare exactly
## these, so the commit that adds a seventh fails there rather than locking every shipped
## client out of every server built after it.
const ENVELOPE: Array[String] = [
	"_dot_down", "_dot_down_event", "_dot_down_unreliable",
	"_dot_up", "_dot_up_event", "_dot_up_unreliable",
]

## How much of the hash is shown. Twelve hex characters, matching dot-net's schema hash,
## which is the other half of this handshake and is printed beside it.
const REVISION_LENGTH := 12


## The signon revision of one side of the connection.
##
## Pass the scripts that carry this side's [code]@rpc[/code] methods -- [DotServer] on a
## server, [DotClientLink] on a client. Order does not matter; the names are sorted.
##
## [b]Scripts rather than nodes, and passed in rather than preloaded.[/b] Preloading
## [DotServer] from here would make this file part of a cycle the moment [DotServer]
## preloads it back, and GDScript resolves a cycle by failing to parse both. The caller
## already has the class it is asking about.
static func revision(scripts: Array) -> String:
	var names := rpc_method_names(scripts)

	if names.is_empty():
		# Not a hash of nothing: an empty answer has to be distinguishable from a real
		# one, or a build where this could not be computed would advertise a revision
		# every other build disagrees with and look like a protocol break.
		return ""

	return DotHash.sha256_text("\n".join(names)).substr(0, REVISION_LENGTH)


## Every [code]@rpc[/code] method name the given scripts declare, sorted and unique.
##
## Sorted because that is the order the engine assigns ids in, and because the answer
## has to be the same on two machines that loaded the scripts in different orders.
static func rpc_method_names(scripts: Array) -> PackedStringArray:
	var seen := {}

	for entry in scripts:
		var script: Script = entry as Script

		if script == null:
			continue

		# [b]Guarded, because a build that cannot answer must say so rather than answer
		# wrongly.[/b] `get_rpc_config` is what Godot reads to build its own checksum; a
		# runtime without it would silently produce the empty name set, which
		# [method revision] turns into "unknown" rather than into a hash everybody else
		# disagrees with.
		if not script.has_method("get_rpc_config"):
			continue

		for method in script.get_rpc_config().keys():
			seen[String(method)] = true

	var names := PackedStringArray(seen.keys())
	names.sort()
	return names


## Whether two revisions can complete a join.
##
## An empty revision on either side is NOT a mismatch. A server older than this class
## sends none, and refusing to talk to it would break every client against every server
## deployed before today -- which is the failure this exists to prevent, arrived at from
## the other direction.
static func compatible(ours: String, theirs: String) -> bool:
	if ours == "" or theirs == "":
		return true
	return ours == theirs


## What to tell a player, and what to log, when the two do not match.
##
## Deliberately says the shape of the fix rather than the cause: a player cannot do
## anything about an [code]@rpc[/code] method, and the person who can is reading the
## same line in a log.
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
