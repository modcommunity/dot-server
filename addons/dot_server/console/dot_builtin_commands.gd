class_name DotBuiltinCommands
extends "res://addons/dot_server/console/dot_builtin_commands_games.gd"

## Registers the standard console commands, named after the established ones (status, kickid, changelevel, exec) so operators need no lookup.
## Deliberately a static class beside [DotServer]: the whole command surface and each permission reads as one list.


# No `const CHANNEL`. Each command replies to whoever typed it, and the things an operator
# wants in a log (a kick, a ban, a map change) are logged by the server and the ban
# manager these commands call, where every other path to them is logged as well.

# Query commands are registered by dot-server-query when it attaches (see DotServer.attach_query_host).


static func register_all(server: DotServer, console: DotConsole) -> void:
	_register_help(server, console)
	_register_status(server, console)
	_register_players(server, console)
	_register_moderation(server, console)
	_register_games(server, console)
	_register_chat(server, console)
	_register_votes(server, console)
	_register_admin(server, console)
	_register_modules(server, console)
	_register_config(server, console)
	_register_lifecycle(server, console)


static func _register_modules(server: DotServer, console: DotConsole) -> void:
	console.command(
		"modules",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(server.modules.describe_lines()),
		"List loaded modules."
	)

	console.command(
		"module_load",
		func(ctx: DotCmdContext) -> void:
			var res: DotResult = await server.modules.load_module(ctx.arg(0))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Loaded %s." % (res.value as DotModule)._module_name()),
		"Load a module from a script path.",
		DotAdminFlags.MODULES
	).with_usage("<path>").with_args(1, 1)

	console.command(
		"module_unload",
		func(ctx: DotCmdContext) -> void:
			var res := server.modules.unload_module(ctx.arg(0))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Unloaded %s." % ctx.arg(0)),
		"Unload a module.",
		DotAdminFlags.MODULES
	).with_usage("<name>").with_args(1, 1)

	console.command(
		"module_reload",
		func(ctx: DotCmdContext) -> void:
			var res: DotResult = await server.modules.reload_module(ctx.arg(0))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Reloaded %s." % ctx.arg(0)),
		"Reload a module from disk.",
		DotAdminFlags.MODULES
	).with_usage("<name>").with_args(1, 1)

	console.command(
		"events",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(server.events.describe_lines()),
		"List game events and their hook counts."
	)


static func _register_config(server: DotServer, console: DotConsole) -> void:
	console.command(
		"exec",
		func(ctx: DotCmdContext) -> void:
			var res := console.exec_config(ctx.arg(0), ctx, true)
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Executed %s (%d lines)." % [ctx.arg(0), res.value]),
		"Execute a config file.",
		DotAdminFlags.CONFIG
	).with_usage("<file>").with_args(1, 1)

	console.command(
		"writeconfig",
		func(ctx: DotCmdContext) -> void:
			var res := console.write_config(ctx.arg(0, "server_saved"))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Wrote %s." % res.value),
		"Save archived variables to a config file.",
		DotAdminFlags.CONFIG
	).with_usage("[name]")

	console.command(
		"config_dump",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(server.config.describe_lines(true)),
		"Show the boot configuration.",
		DotAdminFlags.CONFIG
	)
	_register_config_log(server, console)


static func _register_config_log(server: DotServer, console: DotConsole) -> void:
	console.command(
		"reset",
		func(ctx: DotCmdContext) -> void:
			var cvar := console.find_cvar(ctx.arg(0))
			if cvar == null:
				ctx.reply("Unknown variable '%s'." % ctx.arg(0))
				return
			cvar.reset()
			ctx.reply("%s reset to %s." % [cvar.name, cvar.display_value()]),
		"Reset a variable to its default.",
		DotAdminFlags.CVAR
	).with_usage("<cvar>").with_args(1, 1)

	console.command(
		"log_level",
		func(ctx: DotCmdContext) -> void:
			if ctx.argc() == 0:
				ctx.reply("Log level is %s." % DotLog.level_name(DotLog.get_level()))
				return

			if ctx.argc() == 1:
				var level := DotLog.parse_level(ctx.arg(0))
				if level < 0:
					ctx.reply(
						"Unknown level '%s'. Use: %s"
							% [ctx.arg(0), ", ".join(DotLog.LEVEL_NAMES)]
					)
					return
				DotLog.set_level(level)
				ctx.reply("Log level set to %s." % DotLog.level_name(level))
				return

			# Two arguments sets a channel level, which is what you want when one
			# subsystem is misbehaving and the rest is fine.
			var channel_level := DotLog.parse_level(ctx.arg(1))
			if channel_level < 0:
				ctx.reply("Unknown level '%s'." % ctx.arg(1))
				return
			DotLog.set_channel_level(ctx.arg(0), channel_level)
			ctx.reply("Log level for '%s' set to %s." % [
				ctx.arg(0), DotLog.level_name(channel_level)
			]),
		"Get or set the log level, globally or per channel.",
		DotAdminFlags.CONFIG
	).with_usage("[channel] <level>")


static func _register_lifecycle(server: DotServer, console: DotConsole) -> void:
	console.command(
		"quit",
		func(ctx: DotCmdContext) -> void:
			var reason := ctx.rest(0)
			if reason == "":
				reason = "Server shutting down"
			ctx.reply("Shutting down: %s" % reason)
			server.shutdown(reason)
			# Deferred so the reply reaches an RCON client before the socket
			# closes.
			server.get_tree().quit.call_deferred(),
		"Shut the server down.",
		DotAdminFlags.ROOT
	# The one builtin that refuses chat outright, and the reason is the operation rather
	# than the asker: `quit` ends the session for everybody in it, it cannot be undone from
	# where it was typed, and a chat box is a place where a stray relayed line or a
	# half-finished message lands. ROOT already holds it; this is about the blast radius of
	# a typo in the one input that has no confirmation step.
	).with_usage("[reason]").with_rcon(true).no_chat()

	console.command(
		"say_shutdown",
		func(ctx: DotCmdContext) -> void:
			var seconds := ctx.arg_int(0, 30)
			server.chat.broadcast_system(
				"Server restarting in %d seconds." % seconds
			)
			ctx.reply("Announced a restart in %ds." % seconds)
			# `wait` is measured in frames, so the delay is expressed in ticks.
			console.enqueue(
				"wait %d; quit Scheduled restart"
					% (seconds * Engine.physics_ticks_per_second)
			),
		"Announce and schedule a shutdown.",
		DotAdminFlags.ROOT
	).with_usage("[seconds]")
