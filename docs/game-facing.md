# What a server gives a game's clients: notices, the scoreboard, chat state, bots

Each is an envelope kind ([signon.md](signon.md#the-rpc-surface-is-frozen-dotenvelope)) or a module helper, so a client without it loses the feature and keeps the game.

## `DotNotice`: something for the HUD that is not chat

`DotServer.broadcast_notice(notice)` and `send_notice(session, notice)` put a line, a countdown and a sound on a playing client's HUD; `DotClientLink.notice_received` is where the client hears it. A `DotNotice` is a cue id (typically a dot-audio id), an optional line of text, an optional countdown the client runs itself, and an optional topic naming which HUD line it replaces, so "10… 9… 8…" is one line changing and a notice carrying a topic and nothing else takes that line down.

- **It exists because a server-level feature had no way to reach a player but chat.** A game's own wire reaches the game, but a vote for the next game outlives every game it changes to, and the host running it names no game's classes.
- **Generic on purpose**: a cue, seconds, text and a topic cover a restart warning, an announcement and a map vote a game did not wire itself, as well as the game vote.
- **The payload is a dictionary, and that is the protocol decision.** `DotNotice.from_wire` defaults, type-checks and bounds every field (a `Variant` compared against the wrong type is a runtime error in a client's handler) and ignores unknown fields. "No countdown" is -1, because a countdown of 0 draws a line that has already run out.
- **`data` carries structured content** (a drawn ballot) with no revision change. It is bounded whole: plain values only (no `Object`, no `Callable`), at most eight levels deep, at most 8 KiB encoded, or dropped entirely, because half a tree is a tree every reader must check. It is not sanitised the way `text` is (only the reader knows what is drawn); `DotNotice.sanitised_string` is the cleaning a drawn leaf gets. A notice carrying `data` is never a clear.
- **`text` goes through `DotChatManager.sanitise`**, the same cleaning as chat, because the same client draws it ([security.md](security.md#security-decisions-worth-not-undoing)). `DotNotice.to_wire` bounds every field again, because a host that builds a notice with `new()` skips `make()`. **BBCode is not escaped on the wire**: the shell draws a notice in a plain `Label`; `DotNotice.bbcode_text()` is the one-pass escape for a rich-text reader.
- **Playing sessions only**, the audience of `broadcast_message`, and the peer list is asked before sending (a session whose player just left is an engine error and a backtrace per notice). A host that wants a late joiner to see a line still true resends it from `client_spawned`. `notice_sent(notice, recipients)` fires even for zero recipients.
- **On the event lane**, reliable and ordered like chat, so a HUD line never queues behind a content sync.

## The scoreboard roster

`DotServer.scoreboard_snapshot(for_session)` is what a held scoreboard shows:

```
{
  "server":  {"name", "game", "map", "players", "max", "tickrate"},
  "you":     <the recipient's userid>,
  "players": [{"id", "name", "score", "ping", "seconds", "bot", "admin", ...}],
  ...whatever scoreboard_extra returns: "teams", "header", "rows"
}
```

- **The server's numbers, because only the server has them all.** A client knows its own ping and join time and nobody else's; every field here is one `DotClientSession` already keeps for `status`.
- **Sent only to a client holding its board open** (`DotClientLink.want_scoreboard()` sends `scoreboard.want`; the session's `wants_scoreboard`), once at once and then every `scoreboard_interval_sec` (0.5), **unreliable** because the next one supersedes it, numbered by `seq`. A full server does not pay for a table nobody is looking at. At most `SCOREBOARD_MAX_ROWS` (256) rows.
- **A game adds its columns per player through `scoreboard_fields`** (`func(session) -> Dictionary`, merged into the row) **and anything else through `scoreboard_extra`** (`func() -> Dictionary`, added beside the core keys, never over them). A game's own columns are its to name.
- The client's copy is `DotClientLink.scoreboard` and `scoreboard_received`; dot-menu's `DotMenuScoreboard` draws it.

## Telling a joining client what is carrying chat

`DotChatManager.greet(session)` sends `{kind: "state", relay: bool}` as a client starts playing, before the join announcement; `announce_state()` sends it to everybody when the answer changes.

- **Only the server knows whether a player's lines already reach a web page**, so only it can say whether a second chat box is needed. What the client does with it is the client's (games resolve it against a three-way player setting).
- **`relay_fn` is a callable and `watch_relay` is duck-typed** (`is_carrying() -> bool`), because dot-server must not name `DotChatRelay` from optional dot-chat. Unset means no.
- **It rides chat rather than the handshake**, because the relay may start with the game, after the challenge, and the answer must be re-sendable. The cost: a client listening on `chat_received` sees one payload that is not a line, so a suite counting chat lines must separate it by `kind`.

## How many bots: `DotBotQuota`

`modules/dot_bot_quota.gd`. `DotBotQuota.install(module, default_quota, default_mode = "fill")` registers `bot_quota`, `bot_quota_mode` and `bot_quota_empty` on a game's module, and `wanted(humans, slots)` answers how many bots there should be.

- Modes: **fill** (bots + people = quota; a joining person takes a bot's place and the bot returns when they leave; the default), **fixed**, **per_player**, **off**. Every mode leaves the people their seats (`slots - humans`), and `bot_quota_empty 0` empties a server nobody is on.
- **The policy is one rule an operator learns once; how a bot is made, named and removed stays the game's.** Before it, every game had its own count, cvar and meaning.
- The names are un-prefixed because one game module is loaded at a time and owns them; a game change re-registers them with that game's default, and a descriptor's `cvars:` overrides them.
- **The mode validator is a static method, not a lambda**: a lambda held by a long-lived console can outlive its script at teardown.
- `to_stats_report()`'s bot count still comes from a query provider (`_bot_count()`, duck-typed): dot-server cannot know which of a game's entities are bots.
