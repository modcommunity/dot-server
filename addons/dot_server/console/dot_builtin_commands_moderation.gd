extends "res://addons/dot_server/console/dot_builtin_commands_info.gd"

## Moderation commands of [DotBuiltinCommands]: kick, ban, mute, gag.


static func _register_moderation(server: DotServer, console: DotConsole) -> void:
	console.command(
		"ban",
		func(ctx: DotCmdContext) -> void:
			var resolved := server.resolve_target(ctx, ctx.arg(0))
			if not resolved.ok:
				ctx.reply_error(resolved)
				return

			var session: DotClientSession = resolved.value

			var duration := DotBanManager.parse_duration(ctx.arg(1, "0"))
			if duration < 0:
				ctx.reply(
					"Could not read the duration '%s'. Use 30m, 2h, 7d, or 0 for permanent."
						% ctx.arg(1)
				)
				return

			var reason := ctx.rest(2)
			if reason == "":
				reason = "Banned by an admin"

			var name := session.display_name

			var banned := await server.bans.ban_session(
				session, reason, duration, ctx.caller_label()
			)
			if not banned.ok:
				ctx.reply_error(banned)
				return

			server.kick(session, "Banned: %s" % reason)

			# A guest has no account to ban, so ban_session falls back to their
			# address — which is a ban on everybody else there too, and leaving them
			# connected is the same "it did not work" the moderator sees on banip.
			var also := server.enforce_bans("Banned: %s" % reason)

			ctx.reply("Banned %s (%s): %s%s" % [
				name,
				DotBanManager.format_duration(duration),
				reason,
				"" if also == 0 else " (%d more at that address removed)" % also
			])

			if server.chat != null:
				server.chat.announce_action(
					"%s was banned: %s" % [name, reason]
				),
		"Ban a connected player.",
		DotAdminFlags.BAN
	).with_usage("<player> [duration] [reason]").with_args(1).with_chat().with_completer(
		_player_completer(server)
	)
	_register_moderation_banid(server, console)


static func _register_moderation_banid(server: DotServer, console: DotConsole) -> void:
	console.command(
		"banid",
		func(ctx: DotCmdContext) -> void:
			var duration := DotBanManager.parse_duration(ctx.arg(1, "0"))
			if duration < 0:
				ctx.reply("Could not read the duration '%s'." % ctx.arg(1))
				return

			var res := await server.bans.ban_uid(
				ctx.arg(0), ctx.rest(2), duration, ctx.caller_label()
			)
			if not res.ok:
				ctx.reply_error(res)
				return

			var removed := server.enforce_bans()

			ctx.reply("Banned account %s (%s).%s" % [
				ctx.arg(0),
				DotBanManager.format_duration(duration),
				"" if removed == 0 else " %d removed." % removed
			]),
		"Ban an account id, connected or not.",
		DotAdminFlags.BAN
	).with_usage("<uid> [duration] [reason]").with_args(1).with_chat()

	console.command(
		"banip",
		func(ctx: DotCmdContext) -> void:
			var duration := DotBanManager.parse_duration(ctx.arg(1, "0"))
			if duration < 0:
				ctx.reply("Could not read the duration '%s'." % ctx.arg(1))
				return

			# Takes a connected player as well as a bare address: an admin watching a troublemaker has the name,
			# and a `status` lookup first is a step during which they are still misbehaving.
			var resolved := _resolve_address(server, ctx, ctx.arg(0))
			if not resolved.ok:
				ctx.reply_error(resolved)
				return

			var host := str(resolved.value)
			var reason := ctx.rest(2)
			if reason == "":
				reason = "Banned by an admin"

			var res := await server.bans.ban_address(
				host, reason, duration, ctx.caller_label()
			)
			if not res.ok:
				ctx.reply_error(res)
				return

			# Everybody at the address, not just whoever was named: an address ban that
			# leaves the banned player in the game until they choose to leave looks
			# exactly like a ban that did not work.
			var removed := server.enforce_bans("Banned: %s" % reason)

			ctx.reply("Banned address %s (%s). %d removed." % [
				host, DotBanManager.format_duration(duration), removed
			])

			if server.chat != null and removed > 0:
				server.chat.announce_action("An address was banned: %s" % reason),
		"Ban an address, or a connected player's address. Affects everyone behind it.",
		DotAdminFlags.BAN
	).with_usage("<player|address> [duration] [reason]").with_args(1).with_chat()
	_register_moderation_unban(server, console)


static func _register_moderation_unban(server: DotServer, console: DotConsole) -> void:
	console.command(
		"unban",
		func(ctx: DotCmdContext) -> void:
			var res := await server.bans.unban(ctx.arg(0), ctx.caller_label())
			if not res.ok:
				ctx.reply_error(res)
				return
			ctx.reply("Lifted ban %s." % res.value),
		"Lift a ban.",
		DotAdminFlags.UNBAN
	).with_usage("<uid|address|key>").with_args(1, 1).with_chat()

	console.command(
		"banlist",
		func(ctx: DotCmdContext) -> void:
			if ctx.argc() > 0:
				var matches := server.bans.search(ctx.arg(0))
				var lines := PackedStringArray()
				for ban in matches:
					lines.append("%-32s %s" % [
						str(ban.get("target", "")), str(ban.get("reason", ""))
					])
				_reply_capped(ctx, lines)
				ctx.reply("%d match(es)." % matches.size())
				return

			_reply_capped(ctx, server.bans.describe_lines()),
		"List bans.",
		DotAdminFlags.BAN
	).with_usage("[search]").with_chat()

	console.command(
		"mute",
		func(ctx: DotCmdContext) -> void:
			_silence(server, ctx, true, true),
		"Stop a player speaking and typing.",
		DotAdminFlags.MUTE
	).with_usage("<player> [duration] [reason]").with_args(1).with_chat().with_completer(
		_player_completer(server)
	)
	_register_moderation_silence(server, console)


static func _register_moderation_silence(server: DotServer, console: DotConsole) -> void:
	console.command(
		"gag",
		func(ctx: DotCmdContext) -> void:
			_silence(server, ctx, false, true),
		"Stop a player typing in chat.",
		DotAdminFlags.MUTE
	).with_usage("<player> [duration] [reason]").with_args(1).with_chat().with_completer(
		_player_completer(server)
	)

	console.command(
		"unmute",
		func(ctx: DotCmdContext) -> void:
			var resolved := server.resolve_target(ctx, ctx.arg(0))
			if not resolved.ok:
				ctx.reply_error(resolved)
				return

			var session: DotClientSession = resolved.value
			session.unsilence()
			ctx.reply("%s can speak again." % session.display_name)

			if server.audit != null:
				server.audit.record(
					"unmute", ctx.caller_label(), session.display_name, {}
				),
		"Let a muted player speak again.",
		DotAdminFlags.MUTE
	).with_usage("<player>").with_args(1, 1).with_chat()

	console.command(
		"audit",
		func(ctx: DotCmdContext) -> void:
			if server.audit == null:
				ctx.reply("No audit log is attached.")
				return

			if ctx.argc() > 0 and not ctx.arg(0).is_valid_int():
				for entry in server.audit.search(ctx.arg(0)):
					ctx.reply("%s  %-12s %-24s %s" % [
						str(entry.get("iso", "")),
						str(entry.get("action", "")),
						str(entry.get("actor", "")).substr(0, 24),
						str(entry.get("target", "")),
					])
				return

			ctx.reply_lines(server.audit.describe_lines(ctx.arg_int(0, 25))),
		"Show recent administrative actions.",
		DotAdminFlags.LOGS
	).with_usage("[count|search]")


## Turns a command argument into an address to ban: a bare address, an [code]ip:[/code] target, or any player the targeting rules resolve.
## Refuses when somebody at that address outranks the caller: an address ban removes everybody behind it,
## so checking only the named player lets a junior admin remove a senior one via their housemate.
static func _resolve_address(
	server: DotServer,
	ctx: DotCmdContext,
	target: String
) -> DotResult:
	var query := target.strip_edges()

	if query == "":
		return DotResult.fail(DotError.CODE_INVALID, "No address or player given.")

	var host := ""

	if query.to_lower().begins_with("ip:"):
		host = query.substr(3)
	else:
		var matches := server.find_sessions(query, ctx.session)

		if matches.is_empty():
			# Nobody by that name, so it is an address — including one nobody is
			# connected from, which is how a ban list is populated from a report.
			host = query
		else:
			host = matches[0].address
			for session in matches:
				if DotBanManager.normalise_address(session.address) \
					!= DotBanManager.normalise_address(host):
					var names := PackedStringArray()
					for other in matches:
						names.append("#%d %s" % [other.userid, other.display_name])
					return DotResult.fail(
						DotError.CODE_INVALID,
						"'%s' matches players at different addresses." % query,
						", ".join(Array(names))
					)

	host = DotBanManager.normalise_address(host)

	if host == "":
		return DotResult.fail(DotError.CODE_INVALID, "No address given.")

	for session in server.sessions_from(host):
		if not ctx.outranks(session.immunity):
			return DotResult.fail(
				DotError.CODE_FORBIDDEN,
				"%s is at that address and has equal or higher immunity than you."
					% session.display_name,
				"theirs %d, yours %d" % [session.immunity, ctx.immunity]
			)

	return DotResult.success(host)


## Sends a listing, cut short when it is going to a chat window.
## A ban list is hundreds of lines and chat answers one line per message, so an unbounded listing floods the admin,
## and the rate limiter does not run on server messages.
static func _reply_capped(
	ctx: DotCmdContext,
	lines: PackedStringArray,
	cap: int = 12
) -> void:
	if ctx.source != DotCmdContext.Source.CHAT or lines.size() <= cap:
		ctx.reply_lines(lines)
		return

	for i in range(cap):
		ctx.reply(lines[i])

	ctx.reply("… and %d more. Use the console or RCON for the whole list." % [
		lines.size() - cap
	])


static func _silence(
	server: DotServer,
	ctx: DotCmdContext,
	voice: bool,
	text: bool
) -> void:
	var resolved := server.resolve_target(ctx, ctx.arg(0))
	if not resolved.ok:
		ctx.reply_error(resolved)
		return

	var session: DotClientSession = resolved.value

	var duration := DotBanManager.parse_duration(ctx.arg(1, "0"))
	if duration < 0:
		ctx.reply("Could not read the duration '%s'." % ctx.arg(1))
		return

	session.silence(voice, text, duration)

	var what := "muted" if voice else "gagged"
	var window := DotBanManager.format_duration(duration)

	ctx.reply("%s %s (%s)." % [session.display_name, what, window])

	if server.chat != null:
		server.chat.send_system_to(
			session, "You have been %s (%s)." % [what, window]
		)
		server.chat.announce_action(
			"%s was %s." % [session.display_name, what]
		)

	if server.audit != null:
		server.audit.record(what, ctx.caller_label(), session.display_name, {
			"duration_sec": duration,
			"reason": ctx.rest(2),
		})
