@tool
class_name DotConsole
extends "res://addons/dot_server/console/dot_console_cfg.gd"

## The command and variable registry, and the one place every command is executed.
## Every path in (terminal, RCON, chat, config files, modules) arrives with a [DotCmdContext], so one permission check covers all.
## A child of [DotServer], registered as [code]dot_console[/code] in [DotRegistry].


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	DotRegistry.register(SERVICE, self)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


## Completions for what is in the input box, as whole command lines.
##
## [b]Whole lines, not tokens, and that is the contract the callers already have.[/b]
## dot-console's panel replaces the input box with the candidate it picked, so a candidate
## that was only the argument would delete the command word with it. For a one-word partial
## a name IS the whole line, which is why this reads as a name list until an argument is
## being completed.
##
## [b]Once there is a space, the command's own completer answers.[/b] It used to be that
## nothing did: [member DotConCommand.completer] was set by seven builtins -- `kick`,
## `ban`, `mute`, `gag`, `unban`, and both game commands -- read only by
## [method complete_argument], and [method complete_argument] had no callers anywhere in
## this family. Every one of those completers was correct, reachable and never once run,
## which is why tab on `kick ` offered nothing on a server that knew exactly who was
## connected. The name list still comes back for a bare word, so nothing that completed
## before completes differently.
func complete(partial: String, limit: int = 24) -> PackedStringArray:
	# Leading whitespace is never meaningful and a trailing space always is, so only the
	# left is stripped. `strip_edges()` here would turn "kick " -- completing the first
	# argument -- into "kick", which completes the command that is already typed.
	var line := partial.lstrip(" \t")

	if line.contains(" "):
		return _complete_arguments(line, limit)

	var prefix := line.to_lower()
	var out := PackedStringArray()

	for name in command_names():
		var cmd: DotConCommand = _commands[name]
		if cmd.hidden:
			continue
		if name.begins_with(prefix):
			out.append(name)

	for name in cvar_names():
		var c: DotConVar = _cvars[name]
		if c.has_flag(DotConVar.FLAG_HIDDEN):
			continue
		if name.begins_with(prefix):
			out.append(name)

	for alias in _aliases:
		if str(alias).begins_with(prefix):
			out.append(str(alias))

	out.sort()
	if out.size() > limit:
		out = out.slice(0, limit)

	return out


## Argument completions for a partial line, put back together as whole lines.
##
## The trailing space matters and is the whole of the parsing here: `kick ` is completing
## argument 0 with an empty prefix, and `kick Bo` is completing argument 0 with the prefix
## `Bo`. Getting that backwards offers the second player's name while the first is being
## typed, which reads as the completer being broken rather than off by one.
func _complete_arguments(partial: String, limit: int) -> PackedStringArray:
	var tokens := tokenize(partial)

	if tokens.is_empty():
		return PackedStringArray()

	var name := tokens[0].to_lower()
	var cmd := find_command(name)

	if cmd == null:
		var expanded: Variant = _aliases.get(name)
		if expanded != null:
			# An alias completes as whatever it expands to. Without this, completion is
			# the one place an alias is not the command it stands for.
			var alias_tokens := tokenize(str(expanded))
			if not alias_tokens.is_empty():
				cmd = find_command(alias_tokens[0].to_lower())

	if cmd == null or not cmd.completer.is_valid():
		return PackedStringArray()

	var completing_new := partial.ends_with(" ") or partial.ends_with("\t")
	var index := tokens.size() - 1 if completing_new else tokens.size() - 2
	var prefix := "" if completing_new else tokens[tokens.size() - 1]

	if index < 0:
		return PackedStringArray()

	var raw: Variant = cmd.completer.call(prefix, index)
	var candidates := PackedStringArray()

	if raw is PackedStringArray:
		candidates = raw
	elif raw is Array:
		for item in (raw as Array):
			candidates.append(str(item))
	else:
		return PackedStringArray()

	# The arguments already settled, so a candidate can be put back as a whole line. The
	# same slice either way: `index` is the position being completed, so everything before
	# it is settled whether or not the prefix is an empty token.
	var head := " ".join(Array(tokens.slice(0, index + 1)))
	var out := PackedStringArray()

	for candidate in candidates:
		var text := str(candidate)

		if text == "":
			continue

		# A source that already answered with a whole line -- dot-log's does -- is left
		# alone. Prefixing it again would offer `log log tail`.
		out.append(text if text.to_lower().begins_with(name + " ") else head + " " + text)

		if out.size() >= limit:
			break

	return out


## Completions for one argument, as bare tokens, via the command's own completer.
##
## [method complete] is what a console calls; this is the piece under it, kept public
## because a game with its own input box may want the tokens rather than the lines.
func complete_argument(
	command_name: String,
	partial: String,
	arg_index: int
) -> PackedStringArray:
	var cmd := find_command(command_name)
	if cmd == null or not cmd.completer.is_valid():
		return PackedStringArray()

	var result: Variant = cmd.completer.call(partial, arg_index)
	if result is PackedStringArray:
		return result
	if result is Array:
		var out := PackedStringArray()
		for item in (result as Array):
			out.append(str(item))
		return out

	return PackedStringArray()


func describe() -> Dictionary:
	return {
		"cvars": _cvars.size(),
		"commands": _commands.size(),
		"aliases": _aliases.size(),
		"buffered": _buffer.size(),
	}
