@tool
class_name DotAddressGuard
extends RefCounted

## How many clients one address may have connected at the same time.
##
## [b]This is not a ban and not a rate limit, and it is the control neither of them
## gives you.[/b] A ban answers "may this person be here at all"; the connect rate
## limiter ([DotRateLimiter], applied per address in [DotServer]) answers "how fast may
## they try". Neither stops one machine holding twelve slots on a sixteen-slot server —
## the connections arrive slowly, from nobody banned, and the server fills up with one
## person's clients. That is how a small server is denied to its own community, and it
## needs no exploit: a loop with a five-second sleep does it.
##
## [codeblock]
## var guard := DotAddressGuard.new()
## guard.limit = 2
## guard.check("203.0.113.9", server.addresses_in_use())   # ok, or a refusal to show
## [/codeblock]
##
## [b]Pure by design.[/b] The guard is told the addresses currently in use rather than
## holding a count of its own. A counter maintained by hand drifts the first time a code
## path forgets to decrement it — a rejected peer, a kick, a transport that closes
## without a signal — and the symptom is a server that refuses everybody from an address
## nobody is connected from. Counting the session list cannot drift, because the session
## list is the thing being limited.

## Addresses this never applies to, whatever the limit is.
##
## Loopback is in here because an operator's own listen client, a local bot harness and
## every headless test connect from it, and a limit of 2 that locks the operator out of
## their own server is a limit nobody leaves on.
const ALWAYS_EXEMPT := ["127.0.0.1", "::1", "localhost"]

## What [DotServer] uses when the transport cannot report a peer's address.
const UNKNOWN := "unknown"

## Most simultaneous connections from one address. 0 removes the limit.
##
## Two is the useful setting for a competitive server and wrong for most others: a
## household behind one NAT is one address, and so is a university, a phone network and
## every player behind CGNAT. That is the same bluntness [method DotBanManager.ban_address]
## carries, which is why this defaults to off rather than to a number that seems safe.
var limit: int = 0

## Addresses exempt on top of [constant ALWAYS_EXEMPT] — a LAN party, a known NAT, an
## office everybody plays from.
var exempt_addresses: PackedStringArray = PackedStringArray()

## Refusals since boot, for `status` and for noticing that a limit is doing something.
var refused: int = 0


func _init(p_limit: int = 0) -> void:
	limit = p_limit


## Whether [param address] is never limited.
func is_exempt(address: String) -> bool:
	var host := DotBanManager.normalise_address(address)

	if host == "" or host == UNKNOWN:
		# [b]An address the transport could not report must not be limited.[/b]
		# Every such client would otherwise share one bucket and the server would
		# refuse its fourth player on a limit of 3 while looking empty. A limit that
		# cannot be applied honestly is not applied.
		return true

	if ALWAYS_EXEMPT.has(host):
		return true

	for entry in exempt_addresses:
		if DotBanManager.normalise_address(entry) == host:
			return true

	return false


## How many of [param in_use] are the same address as [param address].
##
## [param in_use] is every address currently holding a session, including duplicates —
## that is what makes the count a count.
func count_for(address: String, in_use: PackedStringArray) -> int:
	var host := DotBanManager.normalise_address(address)
	if host == "":
		return 0

	var total := 0
	for entry in in_use:
		if DotBanManager.normalise_address(entry) == host:
			total += 1

	return total


## Whether one more connection from [param address] may be accepted.
##
## Returns a failure carrying a player-facing message, so a caller can reject the peer
## with something they can act on rather than dropping them silently — a client that is
## refused with no reason reconnects immediately, which is the behaviour the limit exists
## to stop.
func check(address: String, in_use: PackedStringArray) -> DotResult:
	if limit <= 0:
		return DotResult.success(0)

	if is_exempt(address):
		return DotResult.success(0)

	var current := count_for(address, in_use)

	if current < limit:
		return DotResult.success(current)

	refused += 1

	return DotResult.fail(
		DotError.CODE_FORBIDDEN,
		"Too many connections from your address (%d allowed)." % limit,
		"%s already has %d" % [DotBanManager.normalise_address(address), current]
	)


func describe() -> Dictionary:
	return {
		"limit": limit,
		"exempt": Array(exempt_addresses),
		"refused": refused,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if limit <= 0:
		out.append("per-address limit: off")
		return out

	out.append("per-address limit: %d simultaneous, %d refused since boot" % [
		limit, refused
	])

	if not exempt_addresses.is_empty():
		out.append("exempt: %s" % ", ".join(Array(exempt_addresses)))

	return out


func _to_string() -> String:
	return "DotAddressGuard(limit=%d)" % limit
