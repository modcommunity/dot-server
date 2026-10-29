class_name DotGuestIdentity
extends RefCounted

## A minimal identity for servers without dot-auth, with the duck-typed surface the server reads
## ([code]uid[/code], [code]display_name[/code], [code]is_guest[/code], [method is_valid], [method label]).
## A real class, not a runtime-built script (fragile in exports). Guest ids are per device, so a guest ban means little.

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
## The id is hashed, not stored: it is arbitrary client input that should not reach ban lists and audit logs raw.
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
