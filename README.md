This is the **dedicated server** asset for TMC's **Dot** collection. It is the piece a server owner actually runs, and it is shaped after twenty years of dedicated-server practice rather than invented from scratch.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## A Console-Driven Dedicated Server
A dedicated server framework for Godot 4. Console variables and
commands, RCON, server queries, admin permissions with immunity, bans and mutes,
votes, hot-loadable modules, and switching games while players stay connected.

Part of the `dot-*` family alongside [dot-core](../dot-core),
[dot-auth](../dot-auth) and [dot-cloud](../dot-cloud).

## Install

Copy `addons/dot_core/` and `addons/dot_server/` into your project and enable both in
*Project → Project Settings → Plugins*. Requires Godot 4.4+.

## Run a server

```gdscript
var server := DotServer.new()
server.config = DotServerConfig.new()
server.config.hostname = "My Server"
server.config.port = 27015
server.config.rcon_password = "something-long"
add_child(server)
```

Or headless, the way a dedicated server is normally run:

```bash
godot --headless --path . res://server.tscn -- \
    --sv-port 27015 --sv-hostname "My Server" +sv_maxplayers 24 +changelevel dm_arena
```

`--sv-*` sets configuration; `+command` runs a console command. `DOT_SERVER_*`
environment variables work too, which is what a systemd unit or a container wants.

## Connect a client

```gdscript
var link := DotClientLink.new()
add_child(link)
link.player_name = "Ada"
link.phase_changed.connect(func(_p, text): status.text = text)
link.spawned.connect(func(): ui.show_game())

await link.connect_to_server("wss://play.example.com/game")
```

The client downloads whatever content the current game needs (via dot-cloud), loads
the scene the server names, and reports ready — the join flow is handled for you.

## What it gives you

**A real console.** `DotConVar`s with the flag semantics operators know —
`FLAG_CHEAT` gated behind `sv_cheats`, `FLAG_PROTECTED` never printed anywhere
including the log, `FLAG_STARTUP_ONLY` locked once listening, `FLAG_ARCHIVE`
persisted by `writeconfig`. Config file execution with search paths, a command
buffer supporting `wait`, aliases, tab completion, and "did you mean" on typos.

**RCON that existing tools work with.** The classic RCON wire protocol, so
operators keep their clients and panels. Constant-time password comparison,
per-address lockout, an optional allow-list, and a WebSocket variant so a browser
admin panel can talk to it.

**Server queries, both kinds.** A2S, so the twenty years of trackers, chat bots
and uptime monitors that speak nothing else can list your server — off by default,
and on the game port when you turn it on. And the dot query protocol: JSON sections
you ask for by name, a revision that makes polling nearly free, a place for your game
to publish its own state, and a WebSocket variant so a browser-based server list can
reach it, which A2S can never do. Both are challenged against the source address, so
neither can be used to attack somebody else. See
[the wire spec](addons/dot_server/query/PROTOCOL.md).

**Permissions that fit real communities.** String flags rather than fixed roles,
because nobody agrees what a "moderator" is. Numeric immunity so admins cannot kick
each other in a loop. Admins from a JSON file, from dot-auth's site groups, or from
your own source — all merged.

**Moderation with a paper trail.** Bans by account and by address, with durations
(`30m`, `2h`, `7d`), mutes and gags, and an append-only JSONL audit log flushed per
entry so a crash cannot lose the action somebody is asking about.

**Moderation from inside the game.** `/ban`, `/kick`, `/banip`, `/unban`, `/mute`,
`/gag`, `/banlist` and `/whois` all run from chat with the speaker's own permissions —
same commands, same flags, same audit trail as the console and RCON, because a
moderator who has to alt-tab to a terminal moderates less. Name a player however you
have them: `#12`, their name, part of their name, their username, their account id,
`ip:203.0.113.9` for everybody at an address, or `@me`.

**A limit on how many clients one address may hold.** `sv_max_connections_per_ip`,
off by default. Neither a ban nor a connect rate limiter covers this: connections that
arrive slowly, from nobody banned, still let one machine take every slot on a small
server. Loopback is never limited, so it cannot lock you out of your own server.

**Games that swap under live players.** Announce, wait for everyone to download the
new content, swap, re-spawn. A failed change restores the previous game rather than
leaving the server empty.

**Server plugins.** Subclass `DotModule`, register commands and event hooks through
its helpers, and `module_unload` cleanly undoes all of it. Events have cancellable
pre-hooks, so a plugin can actually stop a map change or filter a message.

## Optional, discovered at runtime

Neither is imported; dot-server works without both.

- **[dot-auth](../dot-auth)** → real player identity, so bans mean something and site
  groups can grant server permissions. Without it, everyone is a guest.
- **[dot-cloud](../dot-cloud)** → downloadable game content. Without it, games ship
  inside the build.
- **[dot-moderation](../dot-moderation)** → bans, mutes and gags as durable records in
  a store shared between your servers. Registered as `dot_ban_source`, its bans are
  enforced here at connect. Without it, `DotBanManager`'s own list is the ban list.

## Try it

```bash
godot --headless --path . res://examples/dedicated_server.tscn
```

303 checks covering console parsing, every cvar flag, permission and immunity
enforcement, config execution, the command buffer, ban durations and expiry, event
cancellation, module load/unload, the guest path used when dot-auth is absent, and
both query protocols end to end — challenges, fragmentation, compression, conditional
polling and every A2S response read back field by field — plus the per-address
connection limit, every way of naming a player, and a real dot-moderation ban list
refusing a connection through the registry seam.
Add `-- --serve` to run it as an actual server instead.

## Licence

MIT — see [LICENSE](LICENSE).
