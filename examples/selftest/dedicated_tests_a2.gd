extends "res://examples/selftest/dedicated_tests_a.gd"

## dedicated_server selftest sections, part a2 (the scoreboard and targeting).

func _test_scoreboard_own_row() -> void:
	print("")
	_section("[scoreboard keeps the recipient's own row]")

	var made: Array[DotClientSession] = []
	for i in DotServer.SCOREBOARD_MAX_ROWS + 6:
		var s := _adopt(5000 + i, "198.51.100.1:%d" % i, "P%d" % i)
		s.state = DotClientSession.State.SPAWNED
		made.append(s)
	var last: DotClientSession = made[-1]
	var snap: Dictionary = server.scoreboard_snapshot(last)
	var ids: Array = snap.players.map(func(r: Dictionary) -> int: return int(r.id))
	_check("past the row cap the board stays within it (the byte budget trims further)", snap.players.size() <= DotServer.SCOREBOARD_MAX_ROWS)
	_check("the recipient last in session order still has their row", ids.has(last.userid))

	for s in made:
		server.release_session(s.peer_id)
	made.clear()

	# scoreboard_fields may overwrite "id"; the own row must still be matched by position.
	for i in 40:
		var s := _adopt(6000 + i, "198.51.100.2:%d" % i, "Q%d" % i)
		s.state = DotClientSession.State.SPAWNED
		s.score = 1000 + i
		made.append(s)
	var me: DotClientSession = made[0]
	me.score = -5
	server.scoreboard_fields = func(s: DotClientSession) -> Dictionary:
		return {"id": 0, "pad": "x".repeat(900)}
	snap = server.scoreboard_snapshot(me)
	var kept: Array = snap.players.filter(func(r: Dictionary) -> bool: return int(r.get("score", 0)) == -5)
	_check("a trimmed board drops rows", snap.players.size() < 40)
	_check("the lowest-scored recipient survives although every id was overwritten", kept.size() == 1)

	# An own row too big for the whole budget is cut to id, name and score, not dropped.
	server.scoreboard_fields = func(s: DotClientSession) -> Dictionary:
		return {"blob": "y".repeat(20000)} if s == me else {}
	snap = server.scoreboard_snapshot(me)
	kept = snap.players.filter(func(r: Dictionary) -> bool: return int(r.get("score", 0)) == -5)
	_check("an oversized own row is kept", kept.size() == 1)
	_check("and cut to its minimal fields", kept.size() == 1 and not kept[0].has("blob") and kept[0].name == me.display_name)

	server.scoreboard_fields = Callable()
	for s in made:
		server.release_session(s.peer_id)
	_done()


func _test_scoreboard_pages() -> void:
	print("")
	_section("[scoreboard pages: 128 players, none over the datagram]")

	var made: Array[DotClientSession] = []
	for i in 128:
		var s := _adopt(7000 + i, "198.51.100.3:%d" % i, "Pager%d" % i)
		s.state = DotClientSession.State.SPAWNED
		s.score = i
		made.append(s)
	server.scoreboard_fields = func(s: DotClientSession) -> Dictionary:
		return {"team": 2, "kills": s.score, "note": "n".repeat(60)}
	var me: DotClientSession = made[0]
	var pages := server.scoreboard_pages(me, 5)
	var worst := 0
	var rows := 0
	for p in pages:
		worst = maxi(worst, var_to_bytes(p).size())
		rows += (p["players"] as Array).size()
	_check("128 rows go out as several pages (%d)" % pages.size(), pages.size() > 1)
	_check("every page fits the 1392 B datagram, envelope included (worst %d)" % worst, worst + 64 <= 1392)
	_check("no row is lost across the pages (%d)" % rows, rows == 128)
	_check("pages carry the wire version and count", int(pages[0]["v"]) == 2 and int(pages[-1]["pages"]) == pages.size())

	var link := DotClientLink.new()
	var got: Array[Dictionary] = []
	link.scoreboard_received.connect(func(b: Dictionary) -> void: got.append(b))
	var order: Array = range(pages.size())
	order.reverse()
	order.erase(pages.size() - 1)
	order.append(pages.size() - 1)
	for i in order:
		link._on_scoreboard(1, pages[i])
	_check("the client rebuilds one board from out-of-order pages", got.size() == 1 and (got[0]["players"] as Array).size() == 128)
	_check("with the header from page 0", got.size() == 1 and got[0].has("server") and int(got[0]["you"]) == me.userid)

	var next := server.scoreboard_pages(me, 6)
	for i in next.size():
		if i != 1:
			link._on_scoreboard(1, next[i])
	_check("a lost page keeps its previous copy: the board still has all rows",
		got.size() == 2 and (got[1]["players"] as Array).size() == 128)

	_scoreboard_pages_reorder(me, made, link, pages, got)
	link.free()
	server.scoreboard_fields = Callable()
	for s in made:
		server.release_session(s.peer_id)
	_done()


func _scoreboard_pages_reorder(me: DotClientSession, made: Array[DotClientSession], link: DotClientLink, pages: Array, got: Array[Dictionary]) -> void:
	# Rows that differ between seqs, delivered last page first, must never mix.
	for s in made:
		s.score = 5000 + s.score
	var newer := server.scoreboard_pages(me, 8)
	got.clear()
	for i in range(newer.size() - 1, -1, -1):
		link._on_scoreboard(1, newer[i])
	var last: Dictionary = got[-1] if not got.is_empty() else {}
	var all_new := not last.is_empty() and (last["players"] as Array).size() == 128
	for row in (last.get("players", []) as Array):
		all_new = all_new and int(row["score"]) >= 5000
	_check("reversed pages of a newer seq end as one board of only that seq", all_new and not last.has("partial"))
	_check("the early board (last page first) is marked partial", got.size() > 1 and got[0].has("partial"))

	for s in made:
		s.score -= 5000
	var newest := server.scoreboard_pages(me, 9)
	got.clear()
	for i in range(1, newest.size()):
		link._on_scoreboard(1, newest[i])
	var kept_rows := (got[-1]["players"] as Array).size() if not got.is_empty() else -1
	_check("page 0 lost: the older copy of it fills in, marked partial (%d rows)" % kept_rows,
		kept_rows == 128 and got[-1].has("partial"))
	link._sb_pages[0]["t"] = Time.get_ticks_msec() - 60000
	got.clear()
	link._on_scoreboard(1, server.scoreboard_pages(me, 10)[-1])
	var stale_rows := (got[-1]["players"] as Array).size() if not got.is_empty() else -1
	_check("a kept page older than the ttl is dropped (%d rows)" % stale_rows, stale_rows > 0 and stale_rows < 128)

	var other := made[1]
	var viewer := server.scoreboard_pages(other, 9)
	_check("pages are built once per seq and shared; only `you` differs",
		viewer.size() == newest.size() and int(viewer[0]["you"]) == other.userid and int(newest[0]["you"]) == me.userid
		and viewer[-1] == newest[-1])

	var old_epoch: int = server._sb_epoch
	server._sb_epoch = old_epoch + 1
	got.clear()
	for p in server._build_scoreboard_pages(null, 1, 1100):
		link._on_scoreboard(1, p)
	_check("a seq reset under a new epoch is accepted", not got.is_empty() and int(got[-1]["seq"]) == 1)
	link._reset_scoreboard_state()
	_check("disconnect clears the held board and pages", link.scoreboard.is_empty() and link._sb_pages.is_empty())
	server._sb_epoch = old_epoch

	server.console.execute("sv_scoreboard_page_bytes 60000")
	var huge_worst := 0
	for p in server.scoreboard_pages(me, 12):
		huge_worst = maxi(huge_worst, var_to_bytes(p).size())
	_check("a page size over the datagram is clamped (worst %d)" % huge_worst, huge_worst + 64 <= 1392)

	server.console.execute("sv_scoreboard_page_bytes 600")
	var small := server.scoreboard_pages(me, 7)
	_check("sv_scoreboard_page_bytes tunes the page size (%d then %d pages)" % [pages.size(), small.size()], small.size() > pages.size())
	server.console.execute("sv_scoreboard_page_bytes 1100")



func _test_targeting() -> void:
	print("")
	_section("[targeting a player]")

	var alpha := _adopt(911, "203.0.113.30:1", "Alpha")
	var alphabet := _adopt(912, "203.0.113.31:1", "Alphabet")
	var bob := _adopt(913, "203.0.113.30:2", "Bob")

	_named(alpha, "backbone:alpha", "alpha_the_first")
	_named(alphabet, "backbone:alphabet", "letters")
	_named(bob, "backbone:bob", "bobby")

	# The exact forms must beat the substring one, or a player whose whole name is
	# another player's prefix cannot be named at all.
	var by_name := server.find_sessions("Alpha")
	_check("an exact name wins outright", by_name.size() == 1 and by_name[0] == alpha)
	_check("case does not matter", server.find_sessions("alpha").size() == 1)
	_check("a substring matches several", server.find_sessions("alph").size() == 2)

	var by_username := server.find_sessions("alpha_the_first")
	_check(
		"a username resolves",
		by_username.size() == 1 and by_username[0] == alpha
	)
	var by_uid := server.find_sessions("backbone:bob")
	_check("an account id resolves", by_uid.size() == 1 and by_uid[0] == bob)
	_check("a userid resolves", server.find_sessions("912")[0] == alphabet)
	_check("a #userid resolves", server.find_sessions("#913")[0] == bob)

	# An address is a household. Returning one of the people at it without saying so is
	# how the wrong player gets removed.
	var by_address := server.find_sessions("ip:203.0.113.30")
	_check("an address matches everybody behind it", by_address.size() == 2)

	_check("@me is the caller", server.find_sessions("@me", bob)[0] == bob)
	_check("@me with no caller matches nobody", server.find_sessions("@me").is_empty())
	_check("nothing matches nothing", server.find_sessions("nobody-here").is_empty())

	# Immunity is checked on the way through resolve_target, from chat as well as here.
	var ctx := DotCmdContext.new()
	ctx.permissions = PackedStringArray([DotAdminFlags.KICK])
	ctx.immunity = 10
	alphabet.immunity = 50

	_check(
		"a target with higher immunity is refused",
		not server.resolve_target(ctx, "Alphabet").ok
	)
	_check("an ambiguous target is refused", not server.resolve_target(ctx, "alph").ok)
	_check("a clear target resolves", server.resolve_target(ctx, "Bob").ok)

	# whois is what makes the rest usable: it is where an admin reads the account id an
	# appeal will name.
	var whois := _run("whois Bob")
	_check("whois shows the account", whois.contains("backbone:bob"))
	_check("whois shows the username", whois.contains("bobby"))
	_check("whois shows the address", whois.contains("203.0.113.30"))

	server.release_session(alpha.peer_id)
	server.release_session(alphabet.peer_id)
	server.release_session(bob.peer_id)
	_done()

## A session the server did not get from a socket. Userid and peer id are the same number
## here so checks read clearly; on a real server they are unrelated.
