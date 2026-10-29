# Design notes

Reasoning that used to sit in code comments, kept here so the code carries one line each.

## The envelope

Godot refuses every RPC between two nodes unless both declare the same set of `@rpc` method names (it checksums them), so each feature added as an RPC pair was a protocol break: adding `_notice` moved the signon revision and stopped every shipped client from joining. The RPCs are therefore six fixed names (one per lane in each direction) carrying a KIND and a Dictionary, and a new feature is a new kind. Each end advertises what it knows (the challenge carries the server's advert, the credentials the client's). A kind the peer does not know is not sent to it; a kind that arrives with no handler is dropped with a DEBUG line; a kind either end marks REQUIRED that the other lacks refuses the join, with `explain`'s sentence, from the server. Payload fields are only ever added: a reader defaults and type-checks every field it takes, and a change that cannot be an addition is a new kind with a new name.

## The checksum failure

An RPC set mismatch reads as `ERROR: The rpc node checksum failed. Make sure to have the same methods on both nodes. Node path: /root/Server`, and the server then reports "timed out during join". Neither end says "version". `signon_revision` exists to catch it on the commit that adds a method to one side.

## DotAddressGuard

It is neither a ban ("may this person be here at all") nor the connect rate limiter ("how fast may they try"); neither stops one machine slowly holding twelve slots on a sixteen-slot server. It is pure by design: it is told the addresses in use rather than holding a count, because a hand-kept counter drifts the first time a path forgets to decrement it (a rejected peer, a kick, a transport closing without a signal) and the server then refuses everybody from an address nobody is connected from.

```gdscript
var guard := DotAddressGuard.new()
guard.limit = 2
guard.check("203.0.113.9", server.addresses_in_use())   # ok, or a refusal to show
```

## DotEventBus

Pre-hooks can cancel and post-hooks observe. Hooks run in registration order and a cancel stops the remaining pre-hooks.

```gdscript
events.hook_pre("player_chat", func(e: DotEvent) -> void:
    if e.get_string("text").contains("badword"):
        e.cancel("filtered"))

var e := events.fire("player_chat", {"userid": 3, "text": msg})
if e.cancelled:
    return
```

## DotModule

A module that registers a console command and is then unloaded would leave a handler on a freed object, so every helper records what it registered for `DotModuleHost` to undo.

```gdscript
extends DotModule

func _module_name() -> String: return "welcome"

func _module_load() -> DotResult:
    add_command("welcome", _cmd_welcome, "Greet a player", DotAdminFlags.CHAT)
    hook_post("client_spawn", _on_spawn)
    return DotResult.success(null)

func _on_spawn(e: DotEvent) -> void:
    server.broadcast_message("Welcome, %s!" % e.get_string("name"))
```

## DotBotQuota

One rule for every game instead of one per game, so an operator learns one set of cvars and a person joining takes a bot's place everywhere. The module that installs the cvars owns them, so a game change re-registers them with that game's defaults.

- `bot_quota N`: the number the mode works from (the game picks the default).
- `bot_quota_mode`: `fill` (bots + people = N; a person who joins replaces a bot, default), `fixed` (N bots whoever is playing), `per_player` (N bots per person), `off`.
- `bot_quota_empty 1|0`: keep bots on a server nobody is playing on (default 1, so a server seen in a browser is a game in progress).

Every mode leaves room for people (`slots - humans`).

```gdscript
_quota = DotBotQuota.install(self, 4)          # in _module_load
var want := _quota.wanted(humans, max_players)  # on the roster tick
# add bots while fewer than want, remove (newest first) while more
```
