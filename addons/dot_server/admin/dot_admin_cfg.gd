class_name DotAdminCfg
extends RefCounted

## Reads `groups.yml` and `permissions.yml` from `cfg/addons/dot_server/`, the operator's `cfg/server/dot_server/` over it.
## A flat `legacy_dir/<file>` is still read (one WARN) while no new copy exists, until [constant DotCfgLegacy.REMOVE_AFTER].

const CFG_ADDON := "dot-server"
const GROUPS_FILE := "groups.yml"
const USERS_FILE := "permissions.yml"


## Value: group name -> body, from the `groups:` map. A later layer replaces a group whole.
static func load_groups(legacy_dir: String = "res://cfg") -> DotResult:
	return _load(GROUPS_FILE, "groups", legacy_dir)


## Value: identifier -> body, from the `users:` map. A later layer replaces a user whole.
static func load_users(legacy_dir: String = "res://cfg") -> DotResult:
	return _load(USERS_FILE, "users", legacy_dir)


static func _load(file_name: String, section: String, legacy_dir: String) -> DotResult:
	var out := {}
	var res := DotAddonConfig.apply_file(
		CFG_ADDON, file_name, legacy_dir,
		func(values: Dictionary, path: String) -> PackedStringArray:
			var rows: Variant = values.get(section, {})
			if rows is Dictionary:
				for key in (rows as Dictionary):
					out[key] = (rows as Dictionary)[key]
			elif rows != null:
				DotLog.warn("admin_cfg", "'%s' in %s is not a mapping" % [section, path])
			return PackedStringArray([path])
	)
	if not res.ok:
		return res
	return DotResult.success(out)
