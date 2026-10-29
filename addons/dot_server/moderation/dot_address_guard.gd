@tool
class_name DotAddressGuard
extends RefCounted

## How many clients one address may have connected at the same time.
## Neither a ban nor a rate limit stops one machine holding many slots; this does. It is told the addresses
## in use rather than counting, so it cannot drift when a path forgets to decrement (docs/design-notes.md).

## Addresses this never applies to, whatever the limit is.
## Loopback is here so a limit never locks the operator's own listen client or test harness out.
const ALWAYS_EXEMPT := ["127.0.0.1", "::1", "localhost"]

## What [DotServer] uses when the transport cannot report a peer's address.
const UNKNOWN := "unknown"

## Most simultaneous connections from one address. 0 removes the limit.
## Off by default: a household, a university or CGNAT is one address, the same bluntness as banning an address.
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
		# An address the transport could not report must not be limited: every such client would share one bucket.
		return true

	if ALWAYS_EXEMPT.has(host):
		return true

	for entry in exempt_addresses:
		if DotBanManager.normalise_address(entry) == host:
			return true

	return false


## How many of [param in_use] are the same address as [param address] ([param in_use] includes duplicates).
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
## A failure carries a player-facing message so the peer is rejected with a reason; a silent drop makes it reconnect at once.
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
