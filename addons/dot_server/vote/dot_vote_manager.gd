@tool
class_name DotVoteManager
extends Node

## Player votes: map changes, kicks, and anything a game defines.
##
## One vote at a time, with a deadline, a quorum and per-player cooldowns. The
## cooldowns matter more than they look: without them, one player can call a
## votekick against somebody every thirty seconds until it eventually passes, which
## is harassment the vote system enables rather than prevents.

const CHANNEL := "votes"
const SERVICE := &"dot_vote_manager"

signal vote_started(vote: Dictionary)
signal vote_ended(vote: Dictionary, passed: bool)

@export_group("Rules")

## Seconds a vote stays open.
@export_range(5.0, 300.0, 5.0) var duration_sec: float = 30.0

## Fraction of voters who must vote yes, of those who voted.
@export_range(0.1, 1.0, 0.05) var pass_threshold: float = 0.6

## Fraction of playing clients who must vote at all for the result to count.
##
## Without a quorum, a vote on a 30-player server passes 2–1 with 27 people
## ignoring it.
@export_range(0.0, 1.0, 0.05) var quorum: float = 0.4

## Seconds before the same player may start another vote.
@export_range(0.0, 3600.0, 10.0) var per_player_cooldown_sec: float = 180.0

## Seconds after any vote before another may start.
@export_range(0.0, 600.0, 5.0) var global_cooldown_sec: float = 30.0

## Minimum playing clients before votes are allowed.
##
## A vote among two people is not a vote.
@export_range(1, 64, 1) var min_players: int = 3

var server: DotServer = null

## The open vote, or empty.
var _vote: Dictionary = {}

## userid -> true / false
var _ballots: Dictionary = {}

## uid -> unix seconds of their last started vote.
var _last_started: Dictionary = {}

var _last_vote_ended_at: int = 0
var _timer: Timer = null


func setup(p_server: DotServer) -> void:
	server = p_server
	DotRegistry.register(SERVICE, self)

	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_finish)
	add_child(_timer)

	# A player who leaves mid-vote must not still count toward the quorum, or a
	# vote can become unpassable by attrition.
	server.client_disconnected.connect(_on_client_left)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


# --- Starting --------------------------------------------------------------

## Opens a vote.
##
## [param kind] is a short tag the caller branches on when it passes
## ([code]"changelevel"[/code], [code]"kick"[/code]). [param on_passed] runs only if
## it passes, and only once.
func start(
	kind: String,
	question: String,
	starter: DotClientSession,
	on_passed: Callable,
	payload: Dictionary = {}
) -> DotResult:
	if is_active():
		return DotResult.fail(
			DotError.CODE_STATE,
			"A vote is already running.",
			str(_vote.get("question", ""))
		)

	var playing := server.player_count()

	if playing < min_players:
		return DotResult.fail(
			DotError.CODE_STATE,
			"There are not enough players to hold a vote.",
			"%d playing, %d needed" % [playing, min_players]
		)

	var now := int(Time.get_unix_time_from_system())

	if global_cooldown_sec > 0.0 and _last_vote_ended_at > 0:
		var since := now - _last_vote_ended_at
		if since < int(global_cooldown_sec):
			return DotResult.fail(
				DotError.CODE_RATE_LIMITED,
				"Please wait %ds before starting another vote."
					% (int(global_cooldown_sec) - since)
			)

	if starter != null and per_player_cooldown_sec > 0.0:
		var key := starter.uid() if starter.uid() != "" else str(starter.userid)
		var last := int(_last_started.get(key, 0))
		if last > 0 and (now - last) < int(per_player_cooldown_sec):
			return DotResult.fail(
				DotError.CODE_RATE_LIMITED,
				"You can start another vote in %ds."
					% (int(per_player_cooldown_sec) - (now - last))
			)
		_last_started[key] = now

	_vote = {
		"kind": kind,
		"question": question,
		"payload": payload,
		"started_by": starter.display_name if starter != null else "console",
		"started_by_userid": starter.userid if starter != null else 0,
		"started_at": now,
		"ends_at": now + int(duration_sec),
		"eligible": playing,
		"on_passed": on_passed,
	}
	_ballots.clear()

	# The starter is assumed to vote yes. Making them vote separately means a vote
	# nobody else notices can fail with zero votes cast.
	if starter != null:
		_ballots[starter.userid] = true

	_timer.start(duration_sec)

	DotLog.info(
		CHANNEL,
		"vote started",
		{"kind": kind, "question": question, "by": _vote["started_by"]}
	)

	if server.events != null:
		server.events.notify("vote_started", {
			"kind": kind, "question": question,
		})

	if server.chat != null:
		server.chat.broadcast_system(
			"Vote: %s  —  type !yes or !no (%ds)" % [question, int(duration_sec)]
		)

	vote_started.emit(_vote)
	return DotResult.success(_vote)


# --- Voting ----------------------------------------------------------------

## Records a ballot. A player may change their vote until the deadline.
func cast_vote(session: DotClientSession, yes: bool) -> DotResult:
	if not is_active():
		return DotResult.fail(
			DotError.CODE_STATE, "There is no vote running."
		)

	if not session.is_playing():
		return DotResult.fail(
			DotError.CODE_STATE, "You must be in the game to vote."
		)

	var changed := _ballots.has(session.userid) and bool(_ballots[session.userid]) != yes
	_ballots[session.userid] = yes

	DotLog.debug(
		CHANNEL,
		"vote cast",
		{"user": session.label(), "yes": yes, "changed": changed}
	)

	# End as soon as the outcome cannot change: everyone eligible has voted. Waiting
	# out the timer at that point is pure delay.
	if _ballots.size() >= int(_vote.get("eligible", 0)):
		_finish()

	return DotResult.success(
		"Vote changed." if changed else "Vote recorded."
	)


func _on_client_left(session: DotClientSession, _reason: String) -> void:
	if not is_active():
		return

	_ballots.erase(session.userid)

	# Recomputed rather than decremented, so it stays right when several leave.
	_vote["eligible"] = maxi(1, server.player_count())

	if int(_vote.get("started_by_userid", 0)) == session.userid:
		# The starter leaving is usually a votekick target's accuser giving up, or
		# somebody trying to dodge the result. Either way the vote stands; only its
		# attribution changes.
		_vote["started_by"] = "%s (left)" % str(_vote.get("started_by", ""))


# --- Finishing -------------------------------------------------------------

func _finish() -> void:
	if not is_active():
		return

	_timer.stop()

	var yes := 0
	var no := 0
	for userid in _ballots:
		if bool(_ballots[userid]):
			yes += 1
		else:
			no += 1

	var cast_count := yes + no
	var eligible := maxi(1, int(_vote.get("eligible", 1)))
	var turnout := float(cast_count) / float(eligible)
	var share := float(yes) / float(maxi(1, cast_count))

	var met_quorum := turnout >= quorum
	var passed := met_quorum and share >= pass_threshold

	var vote := _vote.duplicate()
	var callback: Callable = _vote.get("on_passed", Callable())

	# Cleared before the callback runs: a callback that starts another vote — a map
	# vote chaining into the next — must not see this one as still open.
	_vote = {}
	_ballots.clear()
	_last_vote_ended_at = int(Time.get_unix_time_from_system())

	var summary := "%d yes, %d no" % [yes, no]
	if not met_quorum:
		summary += " (not enough votes)"

	DotLog.info(
		CHANNEL,
		"vote passed" if passed else "vote failed",
		{
			"kind": str(vote.get("kind", "")),
			"yes": yes,
			"no": no,
			"turnout": "%.0f%%" % (turnout * 100.0),
		}
	)

	if server.chat != null:
		server.chat.broadcast_system(
			"Vote %s: %s — %s" % [
				"passed" if passed else "failed",
				str(vote.get("question", "")),
				summary,
			]
		)

	if server.events != null:
		server.events.notify("vote_ended", {
			"kind": str(vote.get("kind", "")),
			"passed": passed,
			"yes": yes,
			"no": no,
		})

	vote_ended.emit(vote, passed)

	if passed and callback.is_valid():
		callback.call(vote)


## Ends the open vote early without running its callback.
func cancel(reason: String = "cancelled") -> DotResult:
	if not is_active():
		return DotResult.fail(
			DotError.CODE_STATE, "There is no vote running."
		)

	var question := str(_vote.get("question", ""))

	_timer.stop()
	_vote = {}
	_ballots.clear()
	_last_vote_ended_at = int(Time.get_unix_time_from_system())

	DotLog.info(CHANNEL, "vote cancelled", {"reason": reason})

	if server.chat != null:
		server.chat.broadcast_system("Vote cancelled: %s" % question)

	return DotResult.success(question)


## Ends the open vote now, honouring whatever has been cast.
func force_finish() -> DotResult:
	if not is_active():
		return DotResult.fail(
			DotError.CODE_STATE, "There is no vote running."
		)
	_finish()
	return DotResult.success(true)


# --- Queries ---------------------------------------------------------------

func is_active() -> bool:
	return not _vote.is_empty()


func current() -> Dictionary:
	return _vote


func seconds_remaining() -> int:
	if not is_active():
		return 0
	return maxi(0, int(_vote.get("ends_at", 0)) - int(Time.get_unix_time_from_system()))


func tally() -> Dictionary:
	var yes := 0
	var no := 0
	for userid in _ballots:
		if bool(_ballots[userid]):
			yes += 1
		else:
			no += 1
	return {"yes": yes, "no": no, "cast": yes + no}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if not is_active():
		out.append("no vote running")
		return out

	var t := tally()
	out.append("question  %s" % str(_vote.get("question", "")))
	out.append("kind      %s" % str(_vote.get("kind", "")))
	out.append("started   %s" % str(_vote.get("started_by", "")))
	out.append("tally     %d yes, %d no of %d eligible" % [
		int(t["yes"]), int(t["no"]), int(_vote.get("eligible", 0))
	])
	out.append("remaining %ds" % seconds_remaining())

	return out
