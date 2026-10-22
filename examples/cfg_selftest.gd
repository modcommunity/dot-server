extends Node

## The yml layout of dot-server's group and permission files: new path, flat shim, operator layer.
##
## [codeblock]
## timeout 120 godot --headless --path . res://examples/cfg_selftest.tscn
## [/codeblock]

const FOLDER := "dot_server"
const LEGACY := "user://dot_server_cfg_selftest_legacy"

var _passed := 0
var _failed := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("dot-server cfg self-test")
	var addon_dir := "user://cfg/addons/" + FOLDER
	var server_dir := "user://cfg/server/addons/" + FOLDER
	_clean(addon_dir, server_dir)
	DotCfgLegacy.reset()

	_write(LEGACY.path_join("groups.yml"), "groups:\n  old:\n    immunity: 1\n")
	var res := DotAdminCfg.load_groups(LEGACY)
	_check(res.ok and (res.value as Dictionary).has("old"), "only the flat file: it is still read")
	_check(DotCfgLegacy.warned_count() == 1, "and warned once")
	DotAdminCfg.load_groups(LEGACY)
	_check(DotCfgLegacy.warned_count() == 1, "a second load does not warn again")

	_write(addon_dir.path_join("groups.yml"), "groups:\n  mod:\n    immunity: 50\n  admin:\n    immunity: 80\n")
	res = DotAdminCfg.load_groups(LEGACY)
	var groups: Dictionary = res.value
	_check(res.ok and groups.has("mod") and not groups.has("old"), "the new path wins whole over the flat file")

	_write(server_dir.path_join("groups.yml"), "groups:\n  mod:\n    immunity: 60\n")
	groups = DotAdminCfg.load_groups(LEGACY).value
	_check(int(groups["mod"]["immunity"]) == 60, "the operator's server layer wins")
	_check(groups.has("admin"), "and keeps the groups it does not mention")

	_write(addon_dir.path_join("permissions.yml"), "users:\n  steam_1:\n    groups: [mod]\n")
	var users: Dictionary = DotAdminCfg.load_users(LEGACY).value
	_check(users.has("steam_1"), "permissions.yml is read from the same folder")

	_write(server_dir.path_join("permissions.yml"), "users: [broken\n")
	_check(not DotAdminCfg.load_users(LEGACY).ok, "a bad file fails and names itself")

	_clean(addon_dir, server_dir)
	DotCfgLegacy.reset()
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _clean(addon_dir: String, server_dir: String) -> void:
	DotPaths.remove_tree(addon_dir)
	DotPaths.remove_tree(server_dir)
	DotPaths.remove_tree(LEGACY)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("   ok   ", what)
	else:
		_failed += 1
		print("  FAIL  ", what)
