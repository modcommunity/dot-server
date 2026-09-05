class_name DotGuestIdentity
extends RefCounted

## A minimal identity for servers running without dot-auth.
##
## dot-server must work with dot-auth absent, and the rest of the server reads an
## identity through a small duck-typed surface — [code]uid[/code],
## [code]display_name[/code], [code]is_guest[/code], [method is_valid],
## [method label]. This provides exactly that surface so no other code has to branch
## on whether dot-auth is installed.
##
## [b]Why this is a real class and not a script generated at runtime.[/b] The first
## version built one with [code]GDScript.new()[/code] and
## [method GDScript.reload] on a source string. That is fragile in exported builds,
## impossible to type-check, and — because a server with dot-auth installed never
## reaches it — would only have failed in the one configuration nobody tests.
##
## Guests get a stable-per-device id so they can be muted or kicked for the session,
## and nothing that survives a reinstall. A ban on a guest means very little, which is
## why [member DotAuthConfig.allow_guests] warns when it is on.

var uid: String = ""
var provider: String = "guest"
var provider_id: String = ""
var display_name: String = "Guest"
var username: String = ""
var avatar_url: String = ""
var role: String = ""
var claims: Dictionary = {}
var authenticated_at: int = 0
var expires_at: int = 0

## Always true. The field exists because callers read it off any identity object.
var is_guest: bool = true


## Builds a guest identity from a client-supplied device id.
##
## The device id is hashed rather than stored: it is client-supplied and arbitrary,
## and a raw value would end up in ban lists and audit logs where a 200-character
## string is a nuisance and a fingerprint is not wanted.
static func from_device(device_id: String, name: String = "") -> DotGuestIdentity:
	var seed_value := device_id
	if seed_value.strip_edges() == "":
		# No device id at all. Random rather than a shared constant, which would make
		# every anonymous client the same person as far as mutes and kicks go.
		seed_value = DotHash.random_hex(8)

	var hashed := DotHash.sha256_text(seed_value).substr(0, 16)

	var identity := DotGuestIdentity.new()
	identity.provider_id = hashed
	identity.uid = "guest:%s" % hashed
	identity.display_name = name.strip_edges() if name.strip_edges() != "" \
		else "Guest-%s" % hashed.substr(0, 6)
	identity.authenticated_at = int(Time.get_unix_time_from_system())

	return identity


func is_valid() -> bool:
	return uid != ""


## Matches [code]DotAuthIdentity.label()[/code], which logs and the audit trail read.
func label() -> String:
	return "%s <%s>" % [display_name, uid]


func to_dict() -> Dictionary:
	return {
		"uid": uid,
		"provider": provider,
		"provider_id": provider_id,
		"display_name": display_name,
		"is_guest": true,
		"authenticated_at": authenticated_at,
	}


func _to_string() -> String:
	return "DotGuestIdentity(%s)" % label()
