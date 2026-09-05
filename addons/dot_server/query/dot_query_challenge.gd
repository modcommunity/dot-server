class_name DotQueryChallenge
extends RefCounted

## Address-bound challenge cookies, stored nowhere.
##
## [b]This is the control that stops a query listener being a DDoS amplifier.[/b]
## UDP source addresses are trivially forged, and a query protocol is a small
## request producing a large response — exactly the shape an attacker wants. Send a
## 30-byte request with a victim's address in the source field and the server mails
## the victim a kilobyte. A2S was used this way for years, which is why a challenge
## was bolted
## a challenge onto [code]A2S_INFO[/code] in 2020.
##
## The fix is to answer an unchallenged request with nothing but a cookie, and to
## bind that cookie to the address and port it was sent to. A forger never receives
## it, so it can never present one — and the reply to the forgery is 26 bytes, which
## is smaller than the request that provoked it.
##
## [b]Nothing is stored.[/b] The cookie is
## [code]HMAC(secret, address|port|time-bucket)[/code], recomputed on arrival and
## compared. A stateful challenge table is itself a memory-exhaustion target: an
## attacker asks for a million challenges from a million forged addresses and the
## server holds them all. This holds one 32-byte secret regardless of how many
## challenges are outstanding. Same reasoning as a SYN cookie.
##
## The secret is generated at boot and never persisted, so restarting invalidates
## every outstanding challenge — which is correct, since a restart invalidates
## everything else a querier knew too.

const SECRET_BYTES := 32

## Seconds a cookie stays valid for.
##
## The previous bucket is accepted as well, so the real window is between one and
## two of these. Without that, a cookie issued a millisecond before a boundary
## would be refused by the time it came back and a querier one RTT away could never
## succeed at all — a bug that only appears under load and looks like packet loss.
var ttl_sec: float = 30.0

var _secret: PackedByteArray = PackedByteArray()


func _init(p_ttl_sec: float = 30.0) -> void:
	ttl_sec = maxf(1.0, p_ttl_sec)
	_secret = DotHash.random_bytes(SECRET_BYTES)


## Throws away every outstanding cookie.
func rotate_secret() -> void:
	_secret = DotHash.random_bytes(SECRET_BYTES)


# --- Issuing and verifying -------------------------------------------------

## An 8-byte cookie for the dot query protocol, as a positive integer.
func issue(address: String, port: int) -> int:
	return _decode(_cookie(address, port, _bucket(_now()), 8))


func verify(address: String, port: int, value: int) -> bool:
	return _verify(address, port, value, 8)


## A 4-byte cookie, for A2S's int32 challenge field.
func issue_a2s(address: String, port: int) -> int:
	return _decode(_cookie(address, port, _bucket(_now()), 4))


func verify_a2s(address: String, port: int, value: int) -> bool:
	return _verify(address, port, value, 4)


func _verify(address: String, port: int, value: int, width: int) -> bool:
	# 0 is what a querier sends to mean "I have no cookie", and -1 is A2S's
	# equivalent sentinel. Neither is ever issued, so neither can be valid.
	if value <= 0:
		return false

	var presented := _encode(value, width)
	var now := _now()
	var current := _bucket(now)

	var matched := false
	for bucket in [current, current - 1]:
		# Both buckets are always checked, and the result is accumulated rather
		# than returned early, so the time taken does not reveal which bucket (if
		# either) matched.
		if DotHash.constant_time_equal(
			_cookie(address, port, int(bucket), width), presented
		):
			matched = true

	return matched


# --- Internals -------------------------------------------------------------

func _cookie(address: String, port: int, bucket: int, width: int) -> PackedByteArray:
	# The port is part of the binding, not just the address. A forger who can guess
	# an address still has to guess the source port the cookie was mailed to, and a
	# legitimate querier is using the same socket it will send the query from.
	var message := "%s|%d|%d|%d" % [
		DotBanManager.normalise_address(address), port, bucket, width
	]

	var raw := DotHash.hmac_sha256(_secret, message.to_utf8_buffer())
	var cookie := raw.slice(0, width)

	# Clear the top bit of the most significant byte (little-endian, so the last
	# one). Keeps the cookie positive in GDScript's signed 64-bit ints and in A2S's
	# int32, and guarantees it can never be 0xFFFFFFFF — the value A2S reserves for
	# "send me a challenge".
	cookie[width - 1] = cookie[width - 1] & 0x7F
	return cookie


static func _decode(cookie: PackedByteArray) -> int:
	if cookie.size() == 4:
		return cookie.decode_u32(0)
	return cookie.decode_u64(0)


static func _encode(value: int, width: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(width)
	if width == 4:
		out.encode_u32(0, value)
	else:
		out.encode_u64(0, value)
	return out


func _bucket(now: int) -> int:
	return int(float(now) / ttl_sec)


static func _now() -> int:
	return int(Time.get_unix_time_from_system())


func describe() -> Dictionary:
	return {
		"ttl_sec": ttl_sec,
		"window_sec": ttl_sec * 2.0,
		"stateful": false,
	}
