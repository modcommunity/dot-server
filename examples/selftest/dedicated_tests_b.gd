extends "res://examples/selftest/dedicated_tests_a.gd"

## dedicated_server selftest sections, part b.

## `DotChatManager.sanitise` against the definition it replaced, as written before it was
## made linear: filter, collapse, strip, cut. Empty when every case agrees.
func _sanitise_mismatch() -> String:
	var alphabet := ["a", "b", " ", "\n", "\t", "\u007F", "\u200B", "\u202E", "\u0001", "é",
		"\u0085", "\u200E", "\u00AD", "\u2060"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var cases: Array[String] = ["", " ", "  a  ", "a \u200B b", "\u200B", "ab cd", "ab  ", " \n\t "]
	for n in 400:
		var one := PackedStringArray()
		for k in rng.randi_range(0, 12):
			one.append(alphabet[rng.randi_range(0, alphabet.size() - 1)])
		cases.append("".join(one))
	for raw in cases:
		for limit in [0, 1, 2, 3, 5, 160]:
			var got := DotChatManager.sanitise(raw, limit)
			var want := _sanitise_reference(raw, limit)
			if got != want:
				return "%s at %d: got %s, want %s" % [raw.c_escape(), limit, got.c_escape(), want.c_escape()]
	return ""

func _sanitise_reference(raw: String, max_length: int) -> String:
	var out := ""
	for i in range(raw.length()):
		var code := raw.unicode_at(i)
		if code == 9 or code == 10 or code == 13:
			out += " "
			continue
		if code < 32 or code == 127 or (code >= 0x80 and code <= 0x9F):
			continue
		if code in [0x00AD, 0x061C, 0x180E, 0xFEFF]:
			continue
		if (code >= 0x200B and code <= 0x200F) or (code >= 0x202A and code <= 0x202E):
			continue
		if (code >= 0x2060 and code <= 0x2064) or (code >= 0x2066 and code <= 0x206F):
			continue
		out += raw[i]
	while out.contains("  "):
		out = out.replace("  ", " ")
	out = out.strip_edges()
	if max_length > 0 and out.length() > max_length:
		out = out.substr(0, max_length)
	return out

func _test_chat_state() -> void:
	print("")
	_section("[chat state]")
	var chat := server.chat

	_check("a server nobody told carries chat nowhere else", not chat.is_relayed())
	_check(
		"and says so in a payload a client can tell from a line",
		str(chat.chat_state().get("kind", "")) == "state"
	)
	_check("with relay false", not bool(chat.chat_state().get("relay", true)))

	# The point of the seam: dot-server never names a relay, it asks.
	chat.relay_fn = func() -> bool: return true
	_check("a server with a relay says so", chat.is_relayed())
	_check("and the payload carries it", bool(chat.chat_state().get("relay", false)))

	# A seam that answers with something that is not a bool must read as "no" rather
	# than as truthy: a host wiring this to a method that returns a DotResult would
	# otherwise tell every client the conversation is carried when it is not.
	chat.relay_fn = func() -> Variant: return "yes"
	_check("a non-boolean answer is no", not chat.is_relayed())

	# `watch_relay` is the one line a game writes, and it is duck-typed because
	# dot-server cannot name DotChatRelay.
	#
	# [b]Held in a variable, and that is not style.[/b] A [Callable] stores an object id
	# and does NOT keep a [RefCounted] alive, so `watch_relay(FakeRelay.new())` binds to
	# something that is freed on the next line and the seam reads as "no relay" for ever.
	# The real one is a [Node] the game keeps in the tree, which is why this is a trap the
	# test walked into and the product did not.
	var fake := FakeRelay.new()
	chat.watch_relay(fake)
	_check("watch_relay takes anything with is_carrying", chat.is_relayed())

	var plain := RefCounted.new()
	chat.watch_relay(plain)
	_check("and an object without one carries nothing", not chat.is_relayed())

	chat.watch_relay(null)
	_check("and clearing it goes back to no", not chat.is_relayed())
	_done()

func _test_events() -> void:
	print("")
	_section("[events]")
	var events := server.events

	var fired := [0]
	events.hook_post("example_event", func(_e: DotEvent) -> void: fired[0] += 1)
	events.fire("example_event", {})
	_check("post hook ran", fired[0] == 1)

	# A pre-hook that cancels must stop the event and skip post hooks.
	var post_ran := [false]
	events.hook_pre("cancel_me", func(e: DotEvent) -> void: e.cancel("nope"))
	events.hook_post("cancel_me", func(_e: DotEvent) -> void: post_ran[0] = true)

	var event := events.fire("cancel_me", {})
	_check("pre hook cancelled", event.cancelled and event.cancel_reason == "nope")
	_check("post hook skipped after cancel", not post_ran[0])

	# A pre-hook rewriting data is how a chat filter works without rejecting.
	events.hook_pre("rewrite_me", func(e: DotEvent) -> void:
		e.set_value("text", "clean"))
	var rewritten := events.fire("rewrite_me", {"text": "dirty"})
	_check("pre hook rewrote data", rewritten.get_string("text") == "clean")

	# Typed accessors must coerce rather than crash on unexpected types.
	var typed := events.fire("typed", {"n": "42", "f": 1, "b": "yes"})
	_check("get_int coerces a string", typed.get_int("n") == 42)
	_check("get_float coerces an int", is_equal_approx(typed.get_float("f"), 1.0))
	_check("get_bool coerces 'yes'", typed.get_bool("b"))
	_check("missing key returns default", typed.get_int("absent", 7) == 7)
	_done()

## The identity used when dot-auth is absent.
##
## Only reached in that configuration, which is exactly why it needs a test — a
## server with dot-auth installed never touches it, so a break here would surface
## only for the people running the simplest setup.
func _test_guest_identity() -> void:
	print("")
	_section("[guest identity]")

	var guest := DotGuestIdentity.from_device("device-abc", "Ada")

	_check("valid", guest.is_valid())
	_check("uid namespaced", guest.uid.begins_with("guest:"))
	_check("marked as guest", guest.is_guest)
	_check("requested name used", guest.display_name == "Ada")
	_check("label includes the uid", guest.label().contains(guest.uid))

	# The device id is hashed, not stored: it is client-supplied and arbitrary.
	_check("device id not stored raw", not guest.uid.contains("device-abc"))

	# Stable, so a mute or kick lasts across a reconnect within the session.
	var again := DotGuestIdentity.from_device("device-abc")
	_check("same device gives the same uid", again.uid == guest.uid)

	var other := DotGuestIdentity.from_device("device-xyz")
	_check("different device gives a different uid", other.uid != guest.uid)

	# No device id at all must not make every anonymous client the same person.
	var anon_a := DotGuestIdentity.from_device("")
	var anon_b := DotGuestIdentity.from_device("")
	_check("missing device id yields distinct ids", anon_a.uid != anon_b.uid)
	_check("generated name when none given", anon_a.display_name.begins_with("Guest-"))

	# The session reads identity through this surface, so it must satisfy it.
	var session := DotClientSession.new(99, 99)
	session.identity = guest
	_check("session accepts it", session.is_authenticated())
	_check("session reads the uid", session.uid() == guest.uid)
	_check("session sees it is not an account", not session.is_account())

	# A guest must never receive admin permissions.
	server.admins.resolve(session)
	_check("guest gets no permissions", session.permissions.is_empty())
	_done()

func _test_bot_quota() -> void:
	print("")
	_section("[bot quota]")

	var F := DotBotQuota.Mode.FILL
	# fill: people take bots' places, and a bot comes back when they leave.
	_check("fill: nobody here, the quota is bots", DotBotQuota.compute(F, 4, 0) == 4)
	_check("fill: a person replaces a bot", DotBotQuota.compute(F, 4, 1) == 3)
	_check("fill: a full quota of people, no bots", DotBotQuota.compute(F, 4, 4) == 0)
	_check("fill: more people than the quota, still none", DotBotQuota.compute(F, 4, 9) == 0)
	_check("fixed: the quota whoever is here", DotBotQuota.compute(DotBotQuota.Mode.FIXED, 3, 5) == 3)
	_check("per_player: per person", DotBotQuota.compute(DotBotQuota.Mode.PER_PLAYER, 2, 3) == 6)
	_check("off: none", DotBotQuota.compute(DotBotQuota.Mode.OFF, 8, 0) == 0)
	_check("a bot never takes a person's seat", DotBotQuota.compute(DotBotQuota.Mode.FIXED, 10, 6, 8) == 2)
	_check("a full server has no bots", DotBotQuota.compute(F, 16, 8, 8) == 0)
	_check("empty and told not to keep them: none", DotBotQuota.compute(F, 4, 0, -1, false) == 0)
	_check("but a person brings them back", DotBotQuota.compute(F, 4, 1, -1, false) == 3)

	var source := """
extends DotModule

var quota: DotBotQuota

func _module_name() -> String: return "quota_probe"

func _module_load() -> DotResult:
	quota = DotBotQuota.install(self, 5)
	return DotResult.success(null)
"""
	DotPaths.write_text("user://example/modules/quota_probe.gd", source)
	var loaded: DotResult = await server.modules.load_module("user://example/modules/quota_probe.gd")
	_check("a module installs the quota", loaded.ok)

	if not loaded.ok:
		return

	var module: Object = server.modules.get_module("quota_probe")
	var q: DotBotQuota = module.get("quota") if module != null else null
	_check("and holds it", q != null)

	if q == null:
		return

	_check("default mode is fill", q.mode() == DotBotQuota.Mode.FILL)
	_check("the game's default quota", q.wanted(0) == 5 and q.wanted(2) == 3)
	_run("bot_quota_mode fixed")
	_check("the mode is a cvar", q.wanted(2) == 5)
	_run("bot_quota_mode nonsense")
	_check("a mode that is not one is refused", q.mode() == DotBotQuota.Mode.FIXED)
	_run("bot_quota_mode fill")
	_run("bot_quota_empty 0")
	_check("bot_quota_empty 0 empties an empty server", q.wanted(0) == 0 and q.wanted(1) == 4)

	server.modules.unload_module("quota_probe")
	_check("its cvars go with the module", server.console.find_cvar("bot_quota") == null)
	_done()

func _test_modules() -> void:
	print("")
	_section("[modules]")

	var module_source := """
extends DotModule

func _module_name() -> String: return "example"
func _module_version() -> String: return "1.2.3"
func _module_description() -> String: return "A test module."

func _module_load() -> DotResult:
	add_command("example_hello", _hello, "Say hello", "")
	add_cvar("example_mod_cvar", "7", "A module variable.")
	hook_post("client_spawn", _on_spawn)
	return DotResult.success(null)

func _hello(ctx: DotCmdContext) -> void:
	ctx.reply("hello from the module")

func _on_spawn(_e: DotEvent) -> void:
	pass
"""

	DotPaths.write_text("user://example/modules/example.gd", module_source)

	var loaded: DotResult = await server.modules.load_module(
		"user://example/modules/example.gd"
	)
	_check("module loaded", loaded.ok)

	if loaded.ok:
		_check("module command registered", server.console.find_command("example_hello") != null)
		_check("module cvar registered", server.console.find_cvar("example_mod_cvar") != null)
		_check("module command runs", _run("example_hello").contains("hello from the module"))
		_check("modules listed", _run("modules").contains("example"))

		var hooks_before := server.events.hook_count("client_spawn")

		var unloaded := server.modules.unload_module("example")
		_check("module unloaded", unloaded.ok)

		# The reason the registration helpers exist: an unloaded module must leave
		# nothing behind that can be called into.
		_check(
			"module command removed",
			server.console.find_command("example_hello") == null
		)
		_check(
			"module cvar removed",
			server.console.find_cvar("example_mod_cvar") == null
		)
		_check(
			"module hooks removed",
			server.events.hook_count("client_spawn") < hooks_before
		)

	# A script that is not a DotModule must be refused rather than half-loaded.
	DotPaths.write_text(
		"user://example/bad_module.gd",
		"extends Node\nfunc _ready() -> void: pass\n"
	)
	_check(
		"non-module script refused",
		not (await server.modules.load_module("user://example/bad_module.gd")).ok
	)

	# And one that does not compile -- a module whose base class is an addon that was
	# never linked -- must come back as a failed result, not abort the coroutine and hand
	# every awaiting caller null.
	#
	# [b]The script is put in the resource cache uncompiled rather than parsed from disk[/b],
	# because parsing it prints `SCRIPT ERROR: Parse Error`, and dot-ci fails any suite
	# whose output carries one -- the rule that catches a test aborted by a real script
	# error cannot tell it from one provoked on purpose. load_module's plain load() takes
	# the cached script, which is exactly what a failed parse leaves: a GDScript whose
	# can_instantiate() is false. Still armed: with the guard removed, .new() on it is the
	# same aborting script error the guard was written for.
	DotPaths.write_text(
		"user://example/unlinked_module.gd",
		"extends DotNoSuchModuleBase\n"
	)
	var uncompiled := GDScript.new()
	uncompiled.source_code = "extends DotNoSuchModuleBase\n"
	uncompiled.take_over_path("user://example/unlinked_module.gd")
	var unlinked: Variant = await server.modules.load_module(
		"user://example/unlinked_module.gd"
	)
	_check(
		"uncompilable module refused with a result",
		unlinked is DotResult and not (unlinked as DotResult).ok
	)
	_done()

func _test_audit() -> void:
	print("")
	_section("[audit]")
	var audit := server.audit

	audit.record("test_action", "tester", "target", {"detail": "value"})

	var recent := audit.recent(10)
	_check("action recorded", recent.size() > 0)
	_check(
		"recorded action found",
		audit.search("test_action").size() > 0
	)

	# Permissioned commands go into the audit trail; unpermissioned ones do not, or
	# `status` would bury every real action.
	var before := audit.recent(200).size()
	_run("status")
	_check("public command not audited", audit.recent(200).size() == before)

	var console := server.console
	console.execute("admin_reload", _client_context(
		PackedStringArray([DotAdminFlags.ROOT])
	))
	_check("permissioned command audited", audit.recent(200).size() > before)

	_check("audit command runs", _run("audit 5").length() > 0)
	_done()

# --- Query -----------------------------------------------------------------
#
# The query tests are NOT here any more. Both protocols live in dot-server-query,
# and its own suite drives them the same way this one used to: handle_datagram()
# takes a datagram and returns the datagrams to send back, so the whole of DQP and
# A2S is exercised without binding a socket. Running them here would have needed
# this project to link an optional addon in order to test a server without it.

# --- Helpers ---------------------------------------------------------------

## A context that looks like a client, for permission tests.
## The whole chat-command path, end to end, which had no executed coverage at all.
##
## Everything else about chat commands is asserted against a hand-built context with
## `Source.CHAT` on it. That skips the part a player actually uses: the prefix, the
## manager's parse, the dispatch into the console. The bug that started this — an operator
## typing `/map surf_beginner` and being told the command cannot be run from chat — lived
## precisely in the gap between those two, and no assertion in this suite could see it.
func _test_chat_commands() -> void:
	print("")
	_section("[chat commands]")

	var chat := server.chat
	var console := server.console

	# A session the manager will accept: SPAWNED, with a peer id no transport knows. The
	# replies really are sent — this is the whole path, not a stubbed one — and the
	# multiplayer layer drops them, which is what it does for a player who left mid-command.
	var session := DotClientSession.new()
	session.userid = 9001
	session.peer_id = 424242
	session.display_name = "operator"
	session.address = "203.0.113.9"
	session.state = DotClientSession.State.SPAWNED
	session.immunity = 50
	session.permissions = PackedStringArray([DotAdminFlags.RCON])

	var ran: Array[String] = []
	var on_run := func(c: DotCmdContext) -> void: ran.append(c.command)
	console.command_executed.connect(on_run)

	# `/` and `!`, both of dot-server's default prefixes, on a command that never marked
	# itself `with_chat()`. This is the line the screenshot was of.
	chat.handle_message(session, "/rcon_status")
	_check("a `/` line runs an unmarked command", ran.has("rcon_status"))
	ran.clear()
	chat.handle_message(session, "!rcon_status")
	_check("and so does a `!` line", ran.has("rcon_status"))
	ran.clear()

	# Without the flag it stops at the permission check. The refusal is the same one RCON
	# gets, from the same line of the same function.
	session.permissions = PackedStringArray()
	var denied := chat.handle_message(session, "/rcon_status")
	_check(
		"the flag is what refuses, not the prefix",
		not denied.ok and denied.code() == DotError.CODE_FORBIDDEN and ran.is_empty()
	)

	# A command that refuses chat outright stays refused for somebody holding ROOT.
	session.permissions = PackedStringArray([DotAdminFlags.ROOT])
	var quit_res := chat.handle_message(session, "/quit")
	_check(
		"and `no_chat()` refuses even root, because it is about the operation",
		not quit_res.ok and ran.is_empty()
	)

	# An ordinary sentence that happens to start with a slash must not be eaten silently
	# and must not become a command either.
	var typo := chat.handle_message(session, "/what is this")
	_check("an unknown `/` line is refused rather than spoken", not typo.ok)
	_check("and nothing ran", ran.is_empty())

	console.command_executed.disconnect(on_run)
	_done()

## Long output has to survive being split into several packets.
##
## The splitter is the only part of the protocol that rewrites the payload, and no
## in-process test can see it: [method DotConsole.execute] hands back the text
## whole. Both bounds matter — a client must be able to reassemble the exact text,
## and no single packet may exceed what the protocol allows.
func _test_rcon_long_responses(peer: StreamPeerTCP) -> void:
	# A command whose output is long, but built from short lines.
	server.console.register_command(DotConCommand.new(
		"selftest_long",
		func(ctx: DotCmdContext) -> void:
			for i in 400:
				ctx.reply("line %03d: %s" % [i, "x".repeat(20)]),
		"Long output, for the response splitter."
	))
	# A command whose output is one very long line of multi-byte text. Characters
	# are not bytes, and the packet limit is in bytes.
	server.console.register_command(DotConCommand.new(
		"selftest_wide",
		func(ctx: DotCmdContext) -> void:
			ctx.reply("é".repeat(2400)),
		"One long multi-byte line, for the response splitter."
	))

	var expected_long := _run("selftest_long")
	peer.put_data(_rcon_encode(51, RCON_TYPE_EXECCOMMAND, "selftest_long"))
	var long_packets := await _rcon_read(peer, 4, 240)

	_check("long output is split into several packets", long_packets.size() >= 2)

	var joined := ""
	var oversized := 0
	for packet in long_packets:
		if int(packet["size"]) > 4096:
			oversized += 1
		joined += str(packet["body"])
	_check(
		"a split response reassembles to the same text",
		joined.strip_edges() == expected_long.strip_edges()
	)
	_check("no split packet exceeds the protocol limit", oversized == 0)

	var expected_wide := _run("selftest_wide")
	peer.put_data(_rcon_encode(61, RCON_TYPE_EXECCOMMAND, "selftest_wide"))
	var wide_packets := await _rcon_read(peer, 2, 240)

	var wide_joined := ""
	var wide_oversized := 0
	for packet in wide_packets:
		if int(packet["type"]) == -1 or int(packet["size"]) > 4096:
			wide_oversized += 1
			continue
		wide_joined += str(packet["body"])
	_check(
		"a multi-byte response stays within the packet limit",
		wide_oversized == 0
	)
	_check(
		"a multi-byte response reassembles to the same text",
		wide_joined.strip_edges() == expected_wide.strip_edges()
	)
