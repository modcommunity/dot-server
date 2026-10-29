class_name DotBotQuota
extends RefCounted
## How many bots a game should be running, from how many people are playing.
## One rule for every game (cvars bot_quota, bot_quota_mode, bot_quota_empty); the game still owns how a bot is made.
## Every mode leaves room for people (`slots - humans`). Modes and usage: docs/design-notes.md.

enum Mode { OFF, FILL, FIXED, PER_PLAYER }

const MODE_NAMES := {
	"off": Mode.OFF, "fill": Mode.FILL, "fixed": Mode.FIXED, "per_player": Mode.PER_PLAYER,
}

var quota_cvar: DotConVar = null
var mode_cvar: DotConVar = null
var empty_cvar: DotConVar = null


## Registers the three cvars on [param module] and returns the policy reading them.
## [param default_quota] is the game's own number; [param default_mode] is `fill` unless the game has a reason.
static func install(module: DotModule, default_quota: int, default_mode: String = "fill") -> DotBotQuota:
	var q := DotBotQuota.new()

	q.quota_cvar = module.add_cvar(
		"bot_quota", str(maxi(default_quota, 0)),
		"How many bots, read by bot_quota_mode: fill tops people up to this many players; fixed runs this many bots; per_player runs this many per person.",
		DotConVar.FLAG_NOTIFY
	)
	if q.quota_cvar != null:
		q.quota_cvar.with_range(0, 64)

	q.mode_cvar = module.add_cvar(
		"bot_quota_mode", default_mode if MODE_NAMES.has(default_mode) else "fill",
		"fill (people replace bots), fixed, per_player or off.",
		DotConVar.FLAG_NOTIFY
	)
	if q.mode_cvar != null:
		# A static method, not a lambda: a lambda's script can be gone before the console
		# that holds it at engine teardown, which aborts the process at exit.
		q.mode_cvar.with_validator(DotBotQuota._valid_mode)

	q.empty_cvar = module.add_cvar(
		"bot_quota_empty", "1",
		"1 keeps bots playing on a server nobody is on; 0 removes them until somebody joins."
	)

	return q


static func _valid_mode(value: String) -> DotResult:
	if MODE_NAMES.has(value.strip_edges().to_lower()):
		return DotResult.success(value)
	return DotResult.fail(DotError.CODE_INVALID, "bot_quota_mode is fill, fixed, per_player or off.")


func mode() -> Mode:
	if mode_cvar == null:
		return Mode.FILL
	return MODE_NAMES.get(mode_cvar.get_string().strip_edges().to_lower(), Mode.FILL)


func quota() -> int:
	return maxi(quota_cvar.get_int(), 0) if quota_cvar != null else 0


## How many bots there should be with [param humans] people playing. [param slots] caps the
## total; negative means no cap.
func wanted(humans: int, slots: int = -1) -> int:
	return compute(mode(), quota(), humans, slots, empty_cvar == null or empty_cvar.get_bool())


## The rule itself, with no cvars, so a suite can hold every case.
static func compute(m: Mode, n: int, humans: int, slots: int = -1, keep_when_empty: bool = true) -> int:
	humans = maxi(humans, 0)

	if humans == 0 and not keep_when_empty:
		return 0

	var want := 0

	match m:
		Mode.OFF:
			want = 0
		Mode.FILL:
			want = n - humans
		Mode.FIXED:
			want = n
		Mode.PER_PLAYER:
			want = n * humans

	if slots >= 0:
		want = mini(want, slots - humans)

	return maxi(want, 0)


func describe() -> Dictionary:
	return {
		"mode": mode_cvar.get_string() if mode_cvar != null else "fill",
		"quota": quota(),
		"keep_when_empty": empty_cvar == null or empty_cvar.get_bool(),
	}
