extends RefCounted

## Help, status and player commands of [DotBuiltinCommands].


static func _register_help(server: DotServer, console: DotConsole) -> void:
	console.command(
		"help",
		func(ctx: DotCmdContext) -> void:
			if ctx.argc() == 0:
				ctx.reply("Commands (use 'help <name>' for detail):")
				for name in console.command_names():
					var cmd := console.find_command(name)
					if not cmd.hidden:
						ctx.reply("  " + cmd.describe_line())
				ctx.reply("")
				ctx.reply("'cvarlist' lists variables. 'find <text>' searches both.")
				return

			var query := ctx.arg(0)

			var cmd := console.find_command(query)
			if cmd != null:
				ctx.reply_lines(cmd.describe_help())
				return

			var cvar := console.find_cvar(query)
			if cvar != null:
				ctx.reply_lines(cvar.describe_help())
				return

			ctx.reply("Nothing called '%s'." % query)
			var near := console.suggest(query)
			if not near.is_empty():
				ctx.reply("Did you mean: %s" % ", ".join(Array(near))),
		"List commands, or explain one."
	).with_usage("[name]").with_chat()

	console.command(
		"find",
		func(ctx: DotCmdContext) -> void:
			var needle := ctx.arg(0).to_lower()
			var found := 0

			for name in console.command_names():
				var cmd := console.find_command(name)
				if cmd.hidden:
					continue
				if name.contains(needle) or cmd.description.to_lower().contains(needle):
					ctx.reply("  " + cmd.describe_line())
					found += 1

			for name in console.cvar_names():
				var cvar := console.find_cvar(name)
				if cvar.has_flag(DotConVar.FLAG_HIDDEN):
					continue
				if name.contains(needle) or cvar.description.to_lower().contains(needle):
					ctx.reply("  " + cvar.describe_line())
					found += 1

			ctx.reply("%d match(es)." % found),
		"Search commands and variables."
	).with_usage("<text>").with_args(1, 1)
	_register_help_listing(server, console)


static func _register_help_listing(server: DotServer, console: DotConsole) -> void:
	console.command(
		"cvarlist",
		func(ctx: DotCmdContext) -> void:
			var filter := ctx.arg(0).to_lower()
			var shown := 0

			for name in console.cvar_names():
				var cvar := console.find_cvar(name)
				if cvar.has_flag(DotConVar.FLAG_HIDDEN):
					continue
				if filter != "" and not name.contains(filter):
					continue
				ctx.reply(cvar.describe_line())
				shown += 1

			ctx.reply("%d variable(s)." % shown),
		"List console variables."
	).with_usage("[filter]")

	console.command(
		"echo",
		func(ctx: DotCmdContext) -> void:
			ctx.reply(ctx.rest(0)),
		"Print text."
	).with_usage("<text>")

	console.command(
		"alias",
		func(ctx: DotCmdContext) -> void:
			if ctx.argc() == 0:
				for name in console.aliases():
					ctx.reply("%-20s %s" % [name, console.aliases()[name]])
				return

			if ctx.argc() == 1:
				console.remove_alias(ctx.arg(0))
				ctx.reply("Alias '%s' removed." % ctx.arg(0))
				return

			console.set_alias(ctx.arg(0), ctx.rest(1))
			ctx.reply("Alias '%s' set." % ctx.arg(0)),
		"Define a command alias.",
		DotAdminFlags.CONFIG
	).with_usage("[name] [commands]")


static func _register_status(server: DotServer, console: DotConsole) -> void:
	console.command(
		"status",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(server.status_lines()),
		"Show server and player status."
	)

	# [b]An operator cannot read an RPC checksum, and this is the question they will
	# actually be asked.[/b] "Players on the old build cannot join" is answered by
	# comparing this line with what the client prints, and there is no other way to get
	# it out of a running server without a packet capture. See [DotSignon].
	console.command(
		"signon",
		func(ctx: DotCmdContext) -> void:
			var d := DotSignon.describe([DotServer])
			ctx.reply("revision   %s" % str(d.get("revision", "")))
			ctx.reply("protocol   %d" % int(d.get("protocol", 0)))
			ctx.reply("methods    %d" % int(d.get("rpc_methods", 0)))
			# The names, because a revision that differs says only THAT it differs, and
			# the next question is always which method moved.
			for name in d.get("names", []):
				ctx.reply("           %s" % str(name))
			# And the kinds, which are what actually changes between builds now: which
			# this server knows, which a client must know, and what it has dropped.
			var env := server.envelope.describe()
			ctx.reply("kinds      %d (%d required), %d not sent, %d dropped" % [
				int(env["kinds"]), int(env["required"]),
				int(env["skipped_sends"]), int(env["dropped_arrivals"]),
			])
			ctx.reply_lines(server.envelope.describe_lines()),
		"Show the signon revision and the kinds a client has to match."
	)
	_register_status_services(server, console)


static func _register_status_services(server: DotServer, console: DotConsole) -> void:
	console.command(
		"stats",
		func(ctx: DotCmdContext) -> void:
			ctx.reply("uptime     %s" % DotBanManager.format_duration(
				server.uptime_seconds()
			))
			ctx.reply("state      %s" % server.state_name().to_lower())
			ctx.reply("players    %d" % server.player_count())
			ctx.reply("fps        %d" % Engine.get_frames_per_second())
			ctx.reply("tickrate   %d" % Engine.physics_ticks_per_second)
			if server.has_method("pending_tickrate") and server.pending_tickrate() > 0:
				ctx.reply("tickrate   %d at the next map change" % server.pending_tickrate())
			ctx.reply("memory     %s" % DotPaths.format_bytes(
				OS.get_static_memory_usage()
			))
			ctx.reply("objects    %d" % Performance.get_monitor(
				Performance.OBJECT_COUNT
			))
			ctx.reply("nodes      %d" % Performance.get_monitor(
				Performance.OBJECT_NODE_COUNT
			))

			if server.events != null:
				ctx.reply("events     %d fired" % server.events.total_fired()),
		"Show performance counters."
	)

	console.command(
		"platform",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(DotPlatform.describe_lines()),
		"Show what this build can do."
	)

	console.command(
		"services",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(DotRegistry.describe_lines()),
		"List registered services."
	)


static func _register_players(server: DotServer, console: DotConsole) -> void:
	console.command(
		"users",
		func(ctx: DotCmdContext) -> void:
			var sessions := server.sessions()
			if sessions.is_empty():
				ctx.reply("Nobody is connected.")
				return

			for session in sessions:
				var d := session.describe()
				ctx.reply("#%-4d %-20s %-32s %s" % [
					int(d["userid"]),
					str(d["name"]).substr(0, 20),
					str(d["uid"]),
					str(d["state"]).to_lower(),
				])
			ctx.reply("%d connected." % sessions.size()),
		"List connected players with their account ids."
	)

	console.command(
		"kick",
		func(ctx: DotCmdContext) -> void:
			var resolved := server.resolve_target(ctx, ctx.arg(0))
			if not resolved.ok:
				ctx.reply_error(resolved)
				return

			var session: DotClientSession = resolved.value
			var reason := ctx.rest(1)
			if reason == "":
				reason = "Kicked by an admin"

			var name := session.display_name
			server.kick(session, reason)

			ctx.reply("Kicked %s: %s" % [name, reason])

			if server.chat != null:
				server.chat.announce_action("%s was kicked: %s" % [name, reason])

			if server.audit != null:
				server.audit.record(
					"kick", ctx.caller_label(), name, {"reason": reason}
				),
		"Remove a player.",
		DotAdminFlags.KICK
	).with_usage("<player> [reason]").with_args(1).with_chat().with_completer(
		_player_completer(server)
	)
	_register_players_kick(server, console)


static func _register_players_kick(server: DotServer, console: DotConsole) -> void:
	console.command(
		"kickid",
		func(ctx: DotCmdContext) -> void:
			var session := server.session_by_userid(ctx.arg_int(0, -1))
			if session == null:
				ctx.reply("No player with userid %s." % ctx.arg(0))
				return

			if not ctx.outranks(session.immunity):
				ctx.reply(
					"%s has equal or higher immunity than you."
						% session.display_name
				)
				return

			var reason := ctx.rest(1)
			if reason == "":
				reason = "Kicked by an admin"

			var name := session.display_name
			server.kick(session, reason)
			ctx.reply("Kicked %s: %s" % [name, reason])

			if server.audit != null:
				server.audit.record(
					"kick", ctx.caller_label(), name, {"reason": reason}
				),
		"Remove a player by userid.",
		DotAdminFlags.KICK
	).with_usage("<userid> [reason]").with_args(1).with_chat()

	console.command(
		"whois",
		func(ctx: DotCmdContext) -> void:
			var matches := server.find_sessions(ctx.arg(0), ctx.session)

			if matches.is_empty():
				ctx.reply("No player matching '%s'." % ctx.arg(0))
				return

			# Every identifier a later command can be typed against, in one place.
			# Without it an admin has the name a player shows and no way to reach the
			# account id an appeal or a ticket will name them by.
			for session in matches:
				ctx.reply("#%-4d %s" % [session.userid, session.display_name])
				ctx.reply("  account  %s" % (
					session.uid() if session.uid() != "" else "(guest)"
				))
				if session.username() != "":
					ctx.reply("  username %s" % session.username())
				ctx.reply("  address  %s (%d connected from it)" % [
					session.address, server.sessions_from(session.address).size()
				])
				ctx.reply("  state    %s, %s, immunity %d" % [
					session.state_name().to_lower(),
					"admin" if session.is_admin() else "player",
					session.immunity,
				])
			ctx.reply("%d match(es)." % matches.size()),
		"Show a player's ids, address and status.",
		DotAdminFlags.KICK
	).with_usage("<player>").with_args(1, 1).with_chat().with_completer(
		_player_completer(server)
	)


## Completer that lists connected player names.
static func _player_completer(server: DotServer) -> Callable:
	return func(partial: String, index: int) -> PackedStringArray:
		if index != 0:
			return PackedStringArray()

		var out := PackedStringArray()
		var prefix := partial.to_lower()

		for session in server.sessions():
			if prefix == "" or session.display_name.to_lower().begins_with(prefix):
				# Quoted, because player names contain spaces and an unquoted
				# completion would tokenize into two arguments.
				out.append(
					"\"%s\"" % session.display_name if session.display_name.contains(" ")
					else session.display_name
				)

		return out
