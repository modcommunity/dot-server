@tool
extends "res://addons/dot_server/console/dot_console_exec.gd"

## Config files and the command line of [DotConsole].


## Executes a config file, searched through [member config_search_paths] unless the name is already a path.
## Missing files are no error when [param required] is false: a server that refuses to boot without an optional
## [code]autoexec.cfg[/code] is annoying to install.
func exec_config(
	name: String,
	ctx: DotCmdContext = null,
	required: bool = false
) -> DotResult:
	if _exec_depth >= max_exec_depth:
		return DotResult.fail(
			DotError.CODE_STATE,
			"Config files are nested too deeply.",
			"depth limit %d — a config probably execs itself" % max_exec_depth
		)

	var path := resolve_config_path(name)

	if path == "":
		if required:
			return DotResult.fail(
				DotError.CODE_IO,
				"Config file '%s' not found." % name,
				"searched: %s" % ", ".join(Array(config_search_paths))
			)
		DotLog.debug(CHANNEL, "no config file", {"name": name})
		return DotResult.success(0)

	var read := DotPaths.read_text(path)
	if not read.ok:
		return read.wrap("Could not read '%s'." % path)

	_exec_depth += 1

	var config_ctx := DotCmdContext.new()
	config_ctx.source = DotCmdContext.Source.CONFIG
	# A config file on disk is as trusted as the terminal — whoever wrote it
	# already had filesystem access to the server.
	config_ctx.permissions = PackedStringArray([DotAdminFlags.ROOT])
	config_ctx.immunity = DotAdminFlags.MAX_IMMUNITY
	config_ctx.address = path
	if ctx != null:
		config_ctx.reply_sink = ctx.reply_sink

	var lines := str(read.value).split("\n")
	var executed := 0

	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed == "" or trimmed.begins_with("//") or trimmed.begins_with("#"):
			continue
		execute(trimmed, config_ctx)
		executed += 1

	_exec_depth -= 1

	DotLog.info(
		CHANNEL, "executed config", {"file": path, "lines": executed}
	)

	return DotResult.success(executed)


## Finds a config file, adding [code].cfg[/code] if it has no extension.
func resolve_config_path(name: String) -> String:
	var filename := name
	if not filename.contains("."):
		filename += ".cfg"

	if filename.contains("://") or filename.begins_with("/"):
		return filename if FileAccess.file_exists(filename) else ""

	var safe := DotPaths.safe_relative(filename)
	if not safe.ok:
		# `exec` is reachable over RCON, so its argument is attacker-controlled on
		# a server whose password has leaked. A traversal here would read
		# arbitrary files and echo them as command errors.
		DotLog.warn(
			CHANNEL, "refused an unsafe config path", {"name": name}
		)
		return ""

	for dir in config_search_paths:
		var candidate := dir.path_join(str(safe.value))
		if FileAccess.file_exists(candidate):
			return candidate

	return ""


## Writes every [constant DotConVar.FLAG_ARCHIVE] cvar to a config file.
func write_config(name: String = "server_saved") -> DotResult:
	var lines := PackedStringArray()
	lines.append("// Written by dot-server. Edits are preserved until the next writeconfig.")
	lines.append("")

	for cvar_name in cvar_names():
		var c: DotConVar = _cvars[cvar_name]
		if not c.has_flag(DotConVar.FLAG_ARCHIVE):
			continue
		# A protected value must not be written into a file that gets copied
		# around, pasted into issues and committed by accident.
		if c.has_flag(DotConVar.FLAG_PROTECTED):
			lines.append("// %s omitted (protected)" % c.name)
			continue
		lines.append("%s \"%s\"" % [c.name, c.get_string()])

	for alias in _aliases:
		lines.append("alias %s \"%s\"" % [alias, _aliases[alias]])

	var filename := name
	if not filename.contains("."):
		filename += ".cfg"

	var target := config_search_paths[0].path_join(filename)
	var written := DotPaths.write_text(target, "\n".join(lines) + "\n")

	if written.ok:
		DotLog.info(CHANNEL, "config written", {"file": target})
		return DotResult.success(target)

	return written


## Runs [code]+command args[/code] arguments, the way a dedicated server does.
## [code]godot --headless -- +sv_maxplayers 24 +map dm_arena[/code]: a plus starts a command and its arguments run to the next plus,
## which makes a server scriptable from a systemd unit without a config file.
func execute_command_line(only_cvars: bool = false) -> int:
	var statements := command_line_statements()
	var ran := 0

	for statement in statements:
		# Two passes because of `FLAG_STARTUP_ONLY`: such cvars (tickrate, port, transport) are refused once the server runs,
		# and the command line is the most "startup" input there is. So the boot runs once before the listener with `only_cvars`,
		# and once after for everything else, since a `+map` or `+say` needs the server up.
		if only_cvars and find_cvar(_first_token(statement)) == null:
			continue

		DotLog.info(CHANNEL, "command line", {"cmd": statement})
		execute(statement)
		ran += 1

	return ran


## The `+command arg` statements on the command line, in order.
## Separate from running them so the boot can read the list twice without re-parsing argv, and a test can assert on it.
func command_line_statements() -> PackedStringArray:
	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())

	var statements := PackedStringArray()
	var current := ""

	for arg in args:
		if arg.begins_with("+"):
			if current != "":
				statements.append(current)
			current = arg.substr(1)
		elif current != "":
			# Re-quote anything containing spaces so tokenize() puts it back
			# together as one argument.
			current += " " + ("\"%s\"" % arg if arg.contains(" ") else arg)

	if current != "":
		statements.append(current)

	return statements
