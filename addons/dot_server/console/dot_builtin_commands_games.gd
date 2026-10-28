extends "res://addons/dot_server/console/dot_builtin_commands_moderation.gd"

## Game, chat, vote and admin commands of [DotBuiltinCommands].


static func _register_games(server: DotServer, console: DotConsole) -> void:
	console.command(
		"changelevel",
		func(ctx: DotCmdContext) -> void:
			ctx.reply("Changing to %s…" % ctx.arg(0))
			var res := await server.games.change_game(
				ctx.arg(0), ctx.caller_label()
			)
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Now running %s." % ctx.arg(0)),
		"Switch to another game or map.",
		DotAdminFlags.CHANGEMAP
	).with_usage("<game_id>").with_args(1, 1).with_chat().with_completer(
		func(_partial: String, _index: int) -> PackedStringArray:
			return server.games.game_ids()
	)

	# `game` and `gamechange`, and deliberately NOT `map`.
	#
	# `map` was an alias here for as long as dot-server had no notion of a map -- other
	# servers call the thing that swaps what is running `map`, so operators typed both.
	# dot-map exists now, a map and a game are two completely different operations, and the
	# one an operator almost always means by `map` is the other one: changing a GAME
	# replaces the module, the netcode and the client's scene and puts everybody through
	# signon, while changing a MAP replaces the world and nothing else and happens every few
	# minutes. `DotMapCommands` owns the plain name; these are the aliases for this one.
	for alias in ["game", "gamechange"]:
		console.command(
			alias,
			func(ctx: DotCmdContext) -> void:
				ctx.reply("Changing to %s…" % ctx.arg(0))
				var res := await server.games.change_game(
					ctx.arg(0), ctx.caller_label()
				)
				if not res.ok:
					ctx.reply_error(res)
					return
				ctx.reply("Now running %s." % ctx.arg(0)),
			"Switch to another game. Alias for changelevel.",
			DotAdminFlags.CHANGEMAP
		).with_usage("<game_id>").with_args(1, 1).with_chat().with_completer(
			func(_partial: String, _index: int) -> PackedStringArray:
				return server.games.game_ids()
		)

	console.command(
		"nextgame",
		func(ctx: DotCmdContext) -> void:
			var res := await server.games.next_game(ctx.caller_label())
			if not res.ok:
				ctx.reply_error(res),
		"Advance the game rotation.",
		DotAdminFlags.CHANGEMAP
	).with_chat()

	console.command(
		"games",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(server.games.describe_lines()),
		"List available games."
	).with_chat()

	console.command(
		"cloud_status",
		func(ctx: DotCmdContext) -> void:
			var cloud := DotRegistry.get_service(&"dot_cloud_client")
			if cloud == null:
				ctx.reply("dot-cloud is not installed.")
				return
			if cloud.has_method("describe_lines"):
				var lines: Variant = cloud.call("describe_lines")
				if lines is PackedStringArray:
					ctx.reply_lines(lines),
		"Show content cache status."
	)


static func _register_chat(server: DotServer, console: DotConsole) -> void:
	console.command(
		"say",
		func(ctx: DotCmdContext) -> void:
			var text := ctx.rest(0)
			if text == "":
				return
			server.chat.broadcast_system(text)
			ctx.reply("Said: %s" % text),
		"Send a message to everyone.",
		DotAdminFlags.CHAT
	).with_usage("<text>").with_args(1)

	console.command(
		"asay",
		func(ctx: DotCmdContext) -> void:
			var text := ctx.rest(0)
			if text == "":
				return
			var from := ctx.session.display_name if ctx.session != null else "Console"
			server.chat.broadcast_admin(from, text),
		"Send a message to admins only.",
		DotAdminFlags.CHAT
	).with_usage("<text>").with_args(1).with_chat()

	console.command(
		"psay",
		func(ctx: DotCmdContext) -> void:
			var resolved := server.resolve_target(ctx, ctx.arg(0))
			if not resolved.ok:
				ctx.reply_error(resolved)
				return

			var session: DotClientSession = resolved.value
			var text := ctx.rest(1)
			server.chat.send_system_to(session, text)
			ctx.reply("Sent to %s." % session.display_name),
		"Send a private message to a player.",
		DotAdminFlags.CHAT
	).with_usage("<player> <text>").with_args(2).with_chat()


static func _register_votes(server: DotServer, console: DotConsole) -> void:
	console.command(
		"votemap",
		func(ctx: DotCmdContext) -> void:
			var resolved := server.games.resolve_game(ctx.arg(0))

			if not resolved.ok:
				ctx.reply("%s %s" % [resolved.error.message, resolved.error.detail])
				return

			var game_id := (resolved.value as DotGameDescriptor).game_id

			var res := server.votes.start(
				"changelevel",
				"Change to %s?" % game_id,
				ctx.session,
				func(_vote: Dictionary) -> void:
					# Queued rather than awaited: this runs inside the vote
					# manager's own signal handling, and a game change frees
					# nodes.
					console.enqueue("changelevel %s" % game_id),
				{"game_id": game_id}
			)

			if not res.ok:
				ctx.reply_error(res),
		"Start a vote to change the game.",
		DotAdminFlags.VOTE
	).with_usage("<game_id>").with_args(1, 1).with_chat()

	console.command(
		"yes",
		func(ctx: DotCmdContext) -> void:
			if ctx.session == null:
				ctx.reply("Only players can vote.")
				return
			var res := server.votes.cast_vote(ctx.session, true)
			ctx.reply(str(res.value_or(res.error.message if res.error else ""))),
		"Vote yes."
	).with_chat()

	console.command(
		"no",
		func(ctx: DotCmdContext) -> void:
			if ctx.session == null:
				ctx.reply("Only players can vote.")
				return
			var res := server.votes.cast_vote(ctx.session, false)
			ctx.reply(str(res.value_or(res.error.message if res.error else ""))),
		"Vote no."
	).with_chat()

	console.command(
		"vote_status",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(server.votes.describe_lines()),
		"Show the running vote."
	).with_chat()

	console.command(
		"vote_cancel",
		func(ctx: DotCmdContext) -> void:
			var res := server.votes.cancel("cancelled by %s" % ctx.caller_label())
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Vote cancelled."),
		"Cancel the running vote.",
		DotAdminFlags.VOTE
	)


static func _register_admin(server: DotServer, console: DotConsole) -> void:
	console.command(
		"admins",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(server.admins.describe_lines()),
		"Show admin entries and groups.",
		DotAdminFlags.ADMIN
	)

	console.command(
		"admin_flags",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(DotAdminFlags.describe_lines()),
		"List permission flags."
	)

	console.command(
		"admin_reload",
		func(ctx: DotCmdContext) -> void:
			var res := server.admins.load_admins()
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Reloaded %d admin entries." % res.value)

			# Re-resolve everyone who is already connected: a promotion that only
			# applies to future joins is a confusing half-measure.
			for session in server.sessions():
				server.admins.resolve(session),
		"Reload the admin file.",
		DotAdminFlags.ADMIN
	)
	_register_admin_add(server, console)


static func _register_admin_add(server: DotServer, console: DotConsole) -> void:
	console.command(
		"admin_add",
		func(ctx: DotCmdContext) -> void:
			# **A group name and a flag list are both legal here, and telling them apart
			# is the whole of this block.** The admin FILE has had groups since it was
			# written — the template ships `moderator`, `admin` and `owner` — and this
			# command passed an empty group array, so the one word an operator would
			# actually type was parsed as a flag instead.
			#
			# Nothing errored. `DotAdminFlags.parse` accepts any token and
			# `_warn_about_unknown_flags` only warns, deliberately, because a game
			# defines its own flags. So `admin_add <uid> moderator` created an admin
			# holding a flag called "moderator" that grants nothing, and the only trace
			# was a log line that reads like a typo nobody made.
			var token := ctx.arg(1)
			var groups := PackedStringArray()
			var flags := PackedStringArray()

			if server.admins.has_group(token):
				groups.append(token)
			else:
				flags = DotAdminFlags.parse(token)

				# Refuse a token that is neither a known group nor any known flag. A
				# game's own flags are legal and unknown, so this cannot refuse on
				# "unknown flag" alone — but a single word matching NOTHING is a
				# misspelled group far more often than it is a new flag, and silently
				# granting nothing is the outcome worth preventing.
				var recognised := false

				for flag in flags:
					if DotAdminFlags.ALL.has(str(flag)):
						recognised = true
						break

				if not recognised:
					var known := ", ".join(server.admins.group_names())
					ctx.reply(
						"'%s' is neither a group nor a known flag." % token
					)
					ctx.reply("Groups: %s" % (known if known != "" else "(none)"))
					ctx.reply("Flags:  use `admin_flags` for the list.")
					return

			var immunity := ctx.arg_int(2, 0)

			var res := server.admins.set_admin(
				ctx.arg(0), flags, immunity, groups, ctx.arg(3)
			)
			if not res.ok:
				ctx.reply_error(res)
				return

			var granted := (
				"group %s" % token if not groups.is_empty()
				else DotAdminFlags.format(flags)
			)

			ctx.reply("Admin set: %s -> %s (immunity %d)" % [
				ctx.arg(0), granted, immunity
			])

			if server.audit != null:
				server.audit.record(
					"admin_add", ctx.caller_label(), ctx.arg(0),
					{
						"flags": Array(flags),
						"groups": Array(groups),
						"immunity": immunity,
					}
				),
		"Grant permissions to an account id, by group or by flags.",
		DotAdminFlags.ADMIN
	).with_usage("<uid> <group|flags> [immunity] [name]").with_args(2)
	_register_admin_remove(server, console)


static func _register_admin_remove(server: DotServer, console: DotConsole) -> void:
	console.command(
		"admin_remove",
		func(ctx: DotCmdContext) -> void:
			var res := server.admins.remove_admin(ctx.arg(0))
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Removed admin entry for %s." % ctx.arg(0))

			if server.audit != null:
				server.audit.record(
					"admin_remove", ctx.caller_label(), ctx.arg(0), {}
				),
		"Revoke an account's permissions.",
		DotAdminFlags.ADMIN
	).with_usage("<uid>").with_args(1, 1)

	console.command(
		"whoami",
		func(ctx: DotCmdContext) -> void:
			ctx.reply("caller    %s" % ctx.caller_label())
			ctx.reply("via       %s" % ctx.source_name())
			ctx.reply("flags     %s" % DotAdminFlags.format(ctx.permissions))
			ctx.reply("immunity  %d" % ctx.immunity),
		"Show your own permissions."
	).with_chat()

	console.command(
		"rcon_status",
		func(ctx: DotCmdContext) -> void:
			if server.rcon == null:
				ctx.reply("RCON is disabled.")
				return
			ctx.reply_lines(server.rcon.describe_lines()),
		"Show RCON sessions.",
		DotAdminFlags.RCON
	)
