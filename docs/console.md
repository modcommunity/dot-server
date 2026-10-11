# The console, commands and modules

## Console design

**Values are strings.** Every path a cvar value arrives through is textual (a `.cfg`, an RCON packet, a chat command, argv) and every path out is too: one representation, one place parsing can fail.

**Flags make a console safe to expose.** All enforced in `DotConVar.set_value`, gated by a caller-supplied context rather than global state, because a cvar set from a config file at boot legitimately bypasses checks that one set over RCON must not:

| Flag | Effect |
| --- | --- |
| `FLAG_CHEAT` | Refused unless `sv_cheats` is on. Trusted callers (console, config) bypass, which is how `sv_cheats` itself gets set. |
| `FLAG_PROTECTED` | Never printed. Redacted in `cvarlist`, `writeconfig` and **the log**, the more commonly pasted artefact. |
| `FLAG_STARTUP_ONLY` | Refused once the listener is open ([boot.md](boot.md)). |
| `FLAG_ARCHIVE` | What `writeconfig` persists. |
| `FLAG_NEEDS_PERMISSION` | Requires the `cvar` flag (or `cheats` for cheat cvars). |

Out-of-range values are **clamped with a log line**, not refused: `sv_maxplayers 9999` gets the maximum.

**Every path into the server goes through `DotConsole.execute` with a `DotCmdContext`** saying who is calling (local terminal, RCON, chat, config file, module), so one permission check covers all of them. Commands opt out of RCON (`rcon_allowed`) and state a `chat_policy` (`DEFAULT`, `ALLOWED`, `REFUSED`).

**Chat reaches every command by default, and `permission` is what refuses anybody.** `sv_chat_commands` (config `chat_commands_open`) ships on: a line typed with one of `chat_command_prefixes` (`!` or `/`) runs whatever the speaker's flags allow, exactly as RCON does; 0 restores the old rule where only `with_chat()` commands were typable. The old default ran the chat check before the permission check and never looked at who was asking, so an operator holding `changemap` was told `/map` could not be run from chat. The boundary is the flag. `.no_chat()` is for when the answer is about the operation, not the asker; `quit` is the only builtin that says it.

## `map` belongs to dot-map

`changelevel`, `game` and `gamechange` switch the **game**; there is no `map` command here. Changing a game replaces the module, the netcode and the client's scene and puts everybody through signon; changing a map replaces the world and nothing else. dot-map's `DotMapCommands` registers `map`, `maps` and `mapinfo` on any host with `add_command` or `command`; a deployment without dot-map has no `map`, which is honest. `game` is the alias that means what `map` once meant here, `with_chat()` and completed from the game list.

## An addon's commands on a dedicated server: `add_source`

`DotConsole.add_source(source, permission, chat)` registers every name a **duck-typed** command object claims, each as a real `DotConCommand`; `remove_source` takes them back.

```gdscript
server.console.add_source(DotLogCommands.new(router), DotAdminFlags.GENERIC)
```

- The shape is `names()` and `execute(line)` required, `help_for(name)` and `complete(partial, limit)` when present: the shape dot-console's `DotConsoleBridge` already duck-types, so an addon implements it once and reaches a client console and a server console without naming either. The alternative, a hard dependency on dot-server to name `DotConCommand`, makes an addon like dot-log unusable without a server.
- **It is not a second dispatch path**: a name registered this way gets the permission check, RCON and chat gates, audit line, `cmdlist`, `help`, aliases, `find` and completion. A name somebody already has is warned and skipped, never overwritten.
- **The whole line is handed over, command word included**: every such source parses its own first word.

## Argument completion

`DotConsole.complete()` delegates once the partial contains a space: it tokenizes, finds the command (following an alias), asks its `completer` for the position being completed, and returns a **whole line**, because callers (dot-console's panel) replace the input with the candidate. `kick ` is argument 0 with an empty prefix; `kick Bo` is argument 0 with prefix `Bo`. Off by one, it offers the second argument's candidates while the first is typed. Until this, `complete_argument` had no callers and no argument completer had ever run.

## Modules

`DotModule`'s `add_command` / `add_cvar` / `hook_pre` / `hook_post` helpers exist because **a module that registers a command and is unloaded leaves a handler pointing at a freed object, and the console calls it.** Every helper records what it registered so `_cleanup_registrations()` can undo it. Register through them, not directly. `unload_module` also calls `events.unhook_all(module)` as a backstop, and `reload_module` calls `GDScript.reload()` because the engine caches scripts by path.

`DotGameDescriptor.cvars` are applied when a game loads, in two passes: dot-server does not load a module for a game, so a host that ties a module to a game registers that module's cvars on `game_loaded`, after the descriptor's first pass. `_apply_descriptor_cvars` treats an unregistered name as deferred (reported once as a count), and `reapply_descriptor_cvars()` is the second pass a host makes once its module is up, where an unknown name is wrong. A registered cvar refusing its value is a warning on both passes.

## Naming a player

`find_sessions` is what every admin command resolves through, in this order:

```
#12              userid, the id `kickid` takes
12               userid
@me              the caller, when a session is asking
ip:203.0.113.9   everybody at that address (several matches on purpose)
Player One       display name, exact (case-insensitive)
playerone        username from their account
backbone:abc123  account id
play             display name, substring: the only ambiguous form
```

- **Every exact form is matched before the substring one**, so a player whose name is another's prefix is reachable.
- **`ip:` returns everybody behind the address** (a household). `resolve_target` refuses the ambiguity, and `banip`, which acts on all of them by design, checks immunity against every session there; otherwise a junior admin removes a senior one by naming their housemate.
- `whois` exists because appeals name a player by username or account id, and `status` shows neither.

## Moderation from chat

`ban`, `banid`, `banip`, `unban`, `banlist`, `kick`, `kickid`, `mute`, `gag`, `unmute` and `whois` are `with_chat()`, so they stay typable with `sv_chat_commands 0`. They run through `DotConsole.execute` with the speaker's context, so the flag, immunity check and audit entry are RCON's. Replies go to the speaker alone, and a listing from chat is **capped** (`_reply_capped`): the chat rate limiter does not run on the server's own messages. `users` is not chat-allowed: it has no flag and prints every account id.
