@tool
extends "res://addons/dot_server/server/dot_server_runtime.gd"

## Sending to clients: kinds, notices, the scoreboard and replicated cvars of [DotServer].

## The kinds this server knows, and what each client it has heard from knows (see [DotEnvelope]).
## A game or module adds a kind here, never an [code]@rpc[/code]: a seventh RPC moves the signon
## revision and locks out every older client.
var envelope: DotEnvelope = _make_envelope()


## Built by [DotServer], which owns the handlers.
func _make_envelope() -> DotEnvelope:
	return DotEnvelope.new()


## Sends a kind to one client. False when not sent: no peer, or a client that does not know the
## kind, which is what an older client looks like. The only way dot-server reaches a client;
## see [DotEnvelope]. Implemented by [DotServer], which declares the RPCs it rides on.
func send_kind(
	_peer_id: int,
	_kind: StringName,
	_payload: Dictionary = {},
	_lane: DotEnvelope.Lane = DotEnvelope.Lane.CONTROL
) -> bool:
	return false


func _watch_replicated_cvars() -> void:
	if console == null:
		return
	if not console.cvar_changed.is_connected(_on_replicated_cvar_changed):
		console.cvar_changed.connect(_on_replicated_cvar_changed)
	if not console.cvar_registered.is_connected(_on_replicated_cvar_registered):
		console.cvar_registered.connect(_on_replicated_cvar_registered)


## Sends [param session] every replicated cvar. False when it was not sent (no peer, or a
## client that does not know the kind).
func _send_replicated_cvars(session: DotClientSession) -> bool:
	if console == null or session == null:
		return false
	return send_kind(session.peer_id, DotEnvelope.CVARS, {
		"values": console.replicated_values(),
		"full": true,
	})


func _on_replicated_cvar_changed(c: DotConVar, _old_value: String) -> void:
	_broadcast_replicated_cvar(c)


func _on_replicated_cvar_registered(c: DotConVar) -> void:
	_broadcast_replicated_cvar(c)


func _broadcast_replicated_cvar(c: DotConVar) -> void:
	if not DotConsole.is_replicated(c):
		return

	var payload := {"values": {c.name: c.get_string()}, "full": false}
	var sent := 0

	for session in sessions():
		if session.state != DotClientSession.State.LOADING and not session.is_playing():
			continue
		if send_kind(session.peer_id, DotEnvelope.CVARS, payload):
			sent += 1

	DotLog.debug(CHANNEL, "replicated cvar sent", {"cvar": c.name, "value": c.get_string(), "clients": sent})


## A client's scoreboard opened or closed. Open is answered at once, then every
## [member scoreboard_interval_sec] until it closes.
func _on_scoreboard_want(peer_id: int, payload: Dictionary) -> void:
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return
	# A client that reassembles pages says so; one that does not gets the single trimmed board.
	if payload.has("paged"):
		session.scoreboard_paged = DotEnvelope.flag(payload, "paged", false)
	# `once`: one board now, held state untouched, so a client's periodic block-list roster
	# request does not close a board the player holds open.
	if DotEnvelope.flag(payload, "once", false):
		_send_scoreboard(session)
		return
	session.wants_scoreboard = DotEnvelope.flag(payload, "open", false)
	if session.wants_scoreboard:
		_send_scoreboard(session)


func _send_scoreboards() -> void:
	# One seq per interval, so every viewer's pages come from one cached build.
	_scoreboard_seq += 1
	for session in playing_sessions():
		if session.wants_scoreboard and not session.local:
			_send_scoreboard(session, false)


## Numbers every scoreboard sent, so a client can tell an old one from a new one.
var _scoreboard_seq: int = 0


func _send_scoreboard(session: DotClientSession, bump: bool = true) -> void:
	# `seq`: unreliable over ENet is unordered, so the client drops a board older than the one it
	# holds.
	if bump:
		_scoreboard_seq += 1
	if session.scoreboard_paged:
		_send_scoreboard_pages(session)
		return
	var snap := scoreboard_snapshot(session)
	snap["seq"] = _scoreboard_seq
	var _sent := send_kind(session.peer_id, DotEnvelope.SCOREBOARD, snap, DotEnvelope.Lane.UNRELIABLE)


## Wire version of a paged board: `v`, `seq`, `page`, `pages`; page 0 also carries the header keys.
const SCOREBOARD_WIRE_VERSION := 2


## The board as pages that each fit one datagram, so no lost fragment can drop the whole board.
## Pages are unreliable: the client keeps the last copy of a page that did not arrive.
func _send_scoreboard_pages(session: DotClientSession) -> void:
	var pages := scoreboard_pages(session, _scoreboard_seq)
	for page in pages:
		var _sent := send_kind(session.peer_id, DotEnvelope.SCOREBOARD, page, DotEnvelope.Lane.UNRELIABLE)


## [method scoreboard_snapshot] split into payloads of at most [code]sv_scoreboard_page_bytes[/code]
## (a single row bigger than that still gets a page of its own). Built once per [param seq] and
## shared by every viewer; only page 0's `you` differs.
func scoreboard_pages(for_session: DotClientSession, seq: int) -> Array[Dictionary]:
	var budget := clampi(console.get_int("sv_scoreboard_page_bytes", SCOREBOARD_PAGE_BYTES), 256, SCOREBOARD_PAGE_MAX)
	var count := playing_sessions().size()
	if count > SCOREBOARD_MAX_ROWS:
		return _build_scoreboard_pages(for_session, seq, budget)
	var key := [seq, budget, count]
	if _sb_cache_key != key:
		_sb_cache_key = key
		_sb_cache = _build_scoreboard_pages(null, seq, budget)
	var out: Array[Dictionary] = []
	for page in _sb_cache:
		out.append(page)
	if for_session != null and not out.is_empty():
		var first := out[0].duplicate()
		first["you"] = for_session.userid
		out[0] = first
	return out


var _sb_cache_key: Array = []
var _sb_cache: Array[Dictionary] = []
## Names this server run, so a client can tell a restarted server's seq 1 from a stale one.
var _sb_epoch: int = 0


func _build_scoreboard_pages(for_session: DotClientSession, seq: int, budget: int) -> Array[Dictionary]:
	if _sb_epoch == 0:
		_sb_epoch = maxi(1, randi())
	var snap := scoreboard_snapshot(for_session, false)
	var rows: Array = snap["players"]
	var head := snap.duplicate()
	head.erase("players")
	# Budget the SERIALIZED page: skeleton (keys, ints, and page 0's header) plus its rows. Page 0
	# may hold no rows when the header alone fills it; the client takes the header from page 0 either way.
	var skeleton := {"v": SCOREBOARD_WIRE_VERSION, "ep": _sb_epoch, "seq": seq, "page": 9999, "pages": 9999, "players": []}
	var rest := budget - var_to_bytes(skeleton).size()
	var room := rest - var_to_bytes(head).size()
	var chunks: Array = [[]]
	for row in rows:
		var n := var_to_bytes(row).size()
		var cur: Array = chunks[-1]
		if room - n < 0 and (not cur.is_empty() or chunks.size() == 1):
			chunks.append([])
			room = rest
			cur = chunks[-1]
		cur.append(row)
		room -= n
	var out: Array[Dictionary] = []
	for i in chunks.size():
		var page := {"v": SCOREBOARD_WIRE_VERSION, "ep": _sb_epoch, "seq": seq, "page": i, "pages": chunks.size(), "players": chunks[i]}
		if i == 0:
			page.merge(head)
		out.append(page)
	return out


## Where [method player_key]'s salt is kept. A server's own file: the salt is what stops a
## key meaning anything on another server, so it is never configured, logged or sent.
var player_key_salt_path: String = "user://cfg/player_key.salt"

var _player_key_salt: String = ""


## A player's key for a CLIENT's block list: stable for one account on this server, meaningless
## elsewhere. A digest salted with a per-server secret, not the uid (which would let anyone follow
## a person between servers). Empty without an identity (a bot): the client matches by name.
func player_key(session: DotClientSession) -> String:
	if session == null or session.local:
		return ""
	var uid := session.uid()
	if uid == "":
		return ""
	return DotHash.sha256_text("%s|%s" % [_key_salt(), uid]).substr(0, 20)


func _key_salt() -> String:
	if _player_key_salt != "":
		return _player_key_salt
	if FileAccess.file_exists(player_key_salt_path):
		var read := FileAccess.get_file_as_string(player_key_salt_path).strip_edges()
		if read.length() >= 16:
			_player_key_salt = read
			return _player_key_salt
	_player_key_salt = DotHash.random_hex(16)
	var _made := DirAccess.make_dir_recursive_absolute(player_key_salt_path.get_base_dir())
	var file := FileAccess.open(player_key_salt_path, FileAccess.WRITE)
	if file == null:
		# Kept for this process: keys stay stable until a restart, which only costs a
		# client's mutes falling back to matching by name.
		DotLog.warn(CHANNEL, "could not keep the player key salt; keys change on restart", {
			"path": player_key_salt_path, "error": error_string(FileAccess.get_open_error()),
		})
		return _player_key_salt
	file.store_string(_player_key_salt)
	file.close()
	return _player_key_salt


## What a held scoreboard shows: `server`, `you`, `players` (plus [member scoreboard_fields]
## columns) and whatever [member scoreboard_extra] returns. Sent unreliable, only to a client
## holding its board open; the server has numbers (everyone's ping, join time) a client does not.
func scoreboard_snapshot(for_session: DotClientSession = null, trim: bool = true) -> Dictionary:
	var players: Array = []
	var own_index := -1
	var own_min := {}
	# Past the cap the recipient still gets their own row: cap-1 others, then them.
	var skip_others := playing_sessions().size() > SCOREBOARD_MAX_ROWS
	var others_left := SCOREBOARD_MAX_ROWS - 1
	for session in playing_sessions():
		var is_own: bool = for_session != null and session == for_session
		if skip_others and not is_own:
			if others_left <= 0:
				continue
			others_left -= 1
		var row := {
			"id": session.userid,
			"name": session.display_name,
			"score": session.score,
			"ping": session.ping_ms,
			"seconds": session.connected_seconds(),
			"bot": session.local,
			"admin": session.is_admin(),
			# Who a client's personal block list (dot-chat's `sm`) keys a player by, and
			# which voice frames are theirs. See [method player_key].
			"key": player_key(session),
			"peer": session.peer_id,
		}
		if scoreboard_fields.is_valid():
			var more: Variant = scoreboard_fields.call(session)
			if more is Dictionary:
				row.merge(more as Dictionary, true)
		if is_own:
			# Tracked by position, since scoreboard_fields may overwrite "id".
			own_index = players.size()
			own_min = {"id": session.userid, "name": session.display_name, "score": session.score}
		players.append(row)
	if trim:
		players = _fit_scoreboard(players, own_index, own_min)

	var current := games.current() if games != null else null
	var out := {
		"server": {
			"name": config.hostname,
			"game": current.display_name if current != null else "",
			"map": games.reported_map() if games != null else "",
			"players": player_count(),
			"max": config.max_players,
			"tickrate": config.tickrate,
		},
		"you": for_session.userid if for_session != null else 0,
		"players": players,
	}
	if scoreboard_extra.is_valid():
		var extra: Variant = scoreboard_extra.call()
		if extra is Dictionary:
			for key in (extra as Dictionary):
				if not out.has(key):
					out[key] = (extra as Dictionary)[key]
	return out


## Unreliable ENet fragments anything over the MTU and one lost fragment drops the whole board, so
## a single-message send stays near [code]sv_scoreboard_max_bytes[/code]; paged clients never hit it.
const SCOREBOARD_MAX_BYTES := 16384

## Default bytes of one scoreboard page: under the 1392 B datagram, leaving room for the envelope.
const SCOREBOARD_PAGE_BYTES := 1100

## Hard ceiling of a page: the 1392 B datagram less the envelope.
const SCOREBOARD_PAGE_MAX := 1300


## Trims [param rows] to [constant SCOREBOARD_MAX_BYTES], lowest score first, keeping the
## recipient's own row at [param own_index] (cut to [param own_min] if it alone is too big).
func _fit_scoreboard(rows: Array, own_index: int, own_min: Dictionary) -> Array:
	var sizes: Array[int] = []
	var total := 0
	for row in rows:
		var n := var_to_bytes(row).size()
		sizes.append(n)
		total += n
	var max_bytes := maxi(1024, console.get_int("sv_scoreboard_max_bytes", SCOREBOARD_MAX_BYTES))
	if total <= max_bytes:
		return rows
	if own_index >= 0 and sizes[own_index] > max_bytes and not own_min.is_empty():
		rows = rows.duplicate()
		rows[own_index] = own_min
		sizes[own_index] = var_to_bytes(own_min).size()
	var order: Array = range(rows.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		if (a == own_index) != (b == own_index):
			return a == own_index
		return int(rows[a].get("score", 0)) > int(rows[b].get("score", 0)))
	var keep := {}
	var used := 0
	for i in order:
		if i != own_index and used + sizes[i] > max_bytes:
			continue
		keep[i] = true
		used += sizes[i]
	var out: Array = []
	for i in rows.size():
		if keep.has(i):
			out.append(rows[i])
	DotLog.debug(CHANNEL, "scoreboard trimmed to its byte budget", {
		"rows": rows.size(), "sent": out.size(), "bytes": total,
		"own_kept": own_index >= 0 and keep.has(own_index),
	})
	return out


## A client announcing that its page went into, or came back from, the background. Reliable,
## because a lost announcement costs the player their slot. The requested grace is clamped to
## [code]sv_background_grace[/code]; 0 asks for the maximum.
func _on_visibility(peer_id: int, payload: Dictionary) -> void:
	var session: DotClientSession = _sessions.get(peer_id)
	if session == null:
		return

	session.touch()
	set_session_background(
		session,
		not DotEnvelope.flag(payload, "visible", true),
		DotEnvelope.number(payload, "grace", 0.0)
	)


## Records that a session has gone into, or come back from, the background.
## Split from the RPC so the clamp is reachable without a peer. A server whose maximum is 0
## grants nothing and leaves the session unflagged, so `status` shows no `B` for it.
func set_session_background(
	session: DotClientSession,
	backgrounded: bool,
	requested_grace_sec: float = 0.0
) -> void:
	if session == null:
		return

	var cap := (
		_cv_background_grace.get_float() if _cv_background_grace != null else 0.0
	)

	if not backgrounded or cap <= 0.0:
		session.backgrounded = false
		session.background_grace_sec = 0.0
		return

	session.backgrounded = true
	session.background_grace_sec = (
		clampf(requested_grace_sec, 0.0, cap) if requested_grace_sec > 0.0 else cap
	)


## How long this session may say nothing before it is dropped: `sv_timeout`, or longer after a
## granted background announcement ([method set_session_background]).
func silence_budget(session: DotClientSession) -> float:
	var budget := _cv_timeout.get_float() if _cv_timeout != null else 0.0
	if session != null and session.backgrounded:
		budget = maxf(budget, session.background_grace_sec)
	return budget




## Sends a system message to every playing client.
func broadcast_message(text: String) -> void:
	if chat != null:
		chat.broadcast_system(text)


## Puts a [DotNotice] on every playing client's HUD. Returns how many it reached.
## Playing clients only, like [method broadcast_message]; a host resends a still-true line from
## [signal client_spawned] for late joiners.
func broadcast_notice(notice: DotNotice) -> int:
	if notice == null or notice.is_empty():
		return 0

	var payload := notice.to_wire()
	var sent := 0

	for session in playing_sessions():
		if _put_notice(session, payload):
			sent += 1

	DotLog.debug(CHANNEL, "notice", {
		"cue": String(notice.cue),
		"topic": String(notice.topic),
		"seconds": notice.seconds,
		"text": notice.text,
		"recipients": sent,
	})

	notice_sent.emit(notice, sent)
	return sent


## Puts a [DotNotice] on one client's HUD. False when it could not be sent.
func send_notice(session: DotClientSession, notice: DotNotice) -> bool:
	if notice == null or notice.is_empty() or session == null or not session.is_playing():
		return false

	var ok := _put_notice(session, notice.to_wire())

	if ok:
		notice_sent.emit(notice, 1)

	return ok


## Sends the payload if the peer list still has this session, and says whether it did. The peer
## list is asked, not the session state: an rpc_id to a departed peer prints an engine error
## each time. An adopted session has no peer.
func _put_notice(session: DotClientSession, payload: Dictionary) -> bool:
	if session == null or session.local or not session.is_active():
		return false

	if multiplayer == null or multiplayer.multiplayer_peer == null:
		return false

	if session.peer_id <= 0 or not Array(multiplayer.get_peers()).has(session.peer_id):
		return false

	# False for a client that does not know notices -- an older one. Not an error: it
	# keeps its game and loses the HUD line.
	return send_kind(session.peer_id, DotEnvelope.NOTICE, payload, DotEnvelope.Lane.EVENT)


## Sends a message to clients holding a permission flag; decided server-side (admin chat).
func broadcast_to_permission(flag: String, text: String) -> void:
	if chat == null:
		return
	for session in playing_sessions():
		if session.has_permission(flag):
			chat.send_system_to(session, text)
