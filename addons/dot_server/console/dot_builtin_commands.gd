class_name DotBuiltinCommands
extends RefCounted

## Registers the standard console commands.
##
## Deliberately a separate static class rather than methods on [DotServer]: the
## command surface is the part an operator interacts with, and keeping it in one
## readable list makes it obvious what a server exposes and what permission each
## thing needs.
##
## Names follow the established ones where an equivalent exists ([code]status[/code],
## [code]kickid[/code], [code]changelevel[/code], [code]exec[/code],
## [code]cvarlist[/code]), because operators already know them and a gratuitously
## different name is a lookup every time.

const CHANNEL := "console"


static func register_all(server: DotServer, console: DotConsole) -> void:
	_register_help(server, console)
	_register_status(server, console)
	_register_players(server, console)
	_register_moderation(server, console)
	_register_games(server, console)
	_register_query(server, console)
	_register_chat(server, console)
	_register_votes(server, console)
	_register_admin(server, console)
	_register_modules(server, console)
	_register_config(server, console)
	_register_lifecycle(server, console)


# --- Help and introspection ----------------------------------------------

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


# --- Status ---------------------------------------------------------------

static func _register_status(server: DotServer, console: DotConsole) -> void:
	console.command(
		"status",
		func(ctx: DotCmdContext) -> void:
			ctx.reply_lines(server.status_lines()),
		"Show server and player status."
	)

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


# --- Query -----------------------------------------------------------------

static func _register_query(server: DotServer, console: DotConsole) -> void:
	console.command(
		"query_status",
		func(ctx: DotCmdContext) -> void:
			if server.query_source == null:
				ctx.reply("No query listener: sv_query and sv_a2s are both off.")
				return

			ctx.reply("[dot query]")
			if server.query != null:
				ctx.reply_lines(server.query.describe_lines())
			else:
				ctx.reply("  not listening")

			ctx.reply("")
			ctx.reply("[a2s]")
			if server.a2s != null:
				ctx.reply_lines(server.a2s.describe_lines())
			else:
				ctx.reply("  disabled")

			ctx.reply("")
			ctx.reply("[snapshot]")
			ctx.reply_lines(server.query_source.describe_lines()),
		"Show the query listeners and the snapshot they serve."
	)

	console.command(
		"query_dump",
		func(ctx: DotCmdContext) -> void:
			if server.query_source == null:
				ctx.reply("No query source.")
				return

			# Forced, so an operator checking what a provider contributes sees the
			# current answer rather than one cached up to a second ago — which is
			# exactly the difference they are looking at.
			var snap := server.query_source.snapshot(true)
			ctx.reply(JSON.stringify(snap.to_full_dict(), "  ")),
		"Print the full query response, as a querier would receive it.",
		DotAdminFlags.GENERIC
	)


# --- Players -------------------------------------------------------------

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


# --- Moderation ---------------------------------------------------------

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

			# Takes a connected player as well as a bare address, because an admin
			# watching somebody misbehave has their name in front of them and not their
			# address — and looking one up in `status` first is a step during which they
			# are still misbehaving.
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


## Turns a command argument into an address to ban.
##
## Accepts a bare address, an [code]ip:[/code] target, or any player the targeting rules
## resolve — and refuses when somebody at that address outranks the caller.
##
## [b]That last check is the one worth keeping.[/b] An address ban removes everybody
## behind it, so checking only the player who was named lets a junior admin remove a
## senior one by naming their housemate. Immunity is about who may be acted on, and an
## address ban acts on all of them.
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
##
## A ban list is hundreds of lines and a chat command answers one line per message, so
## an unbounded listing from chat is the server flooding its own admin — and the rate
## limiter that exists to stop a player doing that does not run on server messages.
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


# --- Games ---------------------------------------------------------------

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

	# Other servers call it `map`; operators type both.
	console.command(
		"map",
		func(ctx: DotCmdContext) -> void:
			var res := await server.games.change_game(
				ctx.arg(0), ctx.caller_label()
			)
			if not res.ok:
				ctx.reply_error(res),
		"Alias for changelevel.",
		DotAdminFlags.CHANGEMAP
	).with_usage("<game_id>").with_args(1, 1)

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


# --- Chat ---------------------------------------------------------------

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


# --- Votes -------------------------------------------------------------

static func _register_votes(server: DotServer, console: DotConsole) -> void:
	console.command(
		"votemap",
		func(ctx: DotCmdContext) -> void:
			var game_id := ctx.arg(0)

			if server.games.find_game(game_id) == null:
				ctx.reply("No game with id '%s'." % game_id)
				return

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


# --- Admin -------------------------------------------------------------

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

	console.command(
		"admin_add",
		func(ctx: DotCmdContext) -> void:
			var flags := DotAdminFlags.parse(ctx.arg(1))
			var immunity := ctx.arg_int(2, 0)

			var res := server.admins.set_admin(
				ctx.arg(0), flags, immunity, PackedStringArray(), ctx.arg(3)
			)
			if not res.ok:
				ctx.reply_error(res)
				return

			ctx.reply("Admin set: %s -> %s (immunity %d)" % [
				ctx.arg(0), DotAdminFlags.format(flags), immunity
			])

			if server.audit != null:
				server.audit.record(
					"admin_add", ctx.caller_label(), ctx.arg(0),
					{"flags": Array(flags), "immunity": immunity}
				),
		"Grant permissions to an account id.",
		DotAdminFlags.ADMIN
	).with_usage("<uid> <flags> [immunity] [name]").with_args(2)

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


# --- Modules ----------------------------------------------------------

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
			var res := server.modules.load_module(ctx.arg(0))
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
			var res := server.modules.reload_module(ctx.arg(0))
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


# --- Config -----------------------------------------------------------

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


# --- Lifecycle --------------------------------------------------------

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
	).with_usage("[reason]").with_rcon(true)

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


# --- Helpers ---------------------------------------------------------

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
