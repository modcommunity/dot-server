# History

Stories worth keeping because the bug could come back. The live rule from each is in [../CLAUDE.md](../CLAUDE.md) or a topic doc.

## The protocol breaks

- **Adding an `@rpc` pair was a protocol break that announced itself badly.** `client_visibility` was added as a method pair; a client built before it met a server built after it with "The rpc node checksum failed" and then sat in `AUTHENTICATING` until timed out, which reads as a network problem. That forced `DotSignon`.
- **`_notice` locked every shipped client out two days before the envelope existed.** The notice pair moved the signon revision (`c5c1f679edb5` to `b202b914834e`), and every web and native shell had to be re-exported. Two days later the six-RPC `DotEnvelope` replaced every method pair, the last coordinated break: `DotSignon.PROTOCOL` went to 2, and every shell was re-exported once more. A client older than `DotSignon` itself has no check at all and times out in `AUTHENTICATING`.
- **A kick from outside an RPC handler never delivered its reason.** Found by dot-server-deploy's `smash_client`, whose game netcode refused a client from outside a handler. Fixed by `_close_peer`'s grace.

## Game switching had never run

Every game in every suite shipped inside its build, and `change_game` skips the whole client sync for such a game, so four hundred lines had never executed. `content_switch` published a real pack and switched three times; it found six bugs, all parse-clean:

- the server never fetched its own content, so a delivered game could not be loaded and the restore read like a typo'd scene name;
- every client was kicked for reporting the NEW content key, which during a sync is correct;
- `LOADING -> DOWNLOADING` was illegal, so a client that had joined a second earlier was never told and stayed in the game everybody had left;
- a stale `session.content_key` made a returning client look ready before it was told;
- the first client to finish downloading was told to load the old game;
- the download-progress subscription was made again on every change (a fresh lambda never matches `is_connected`), so after ten changes a client sent ten progress messages per tick.

And `swap_when_all_ready` was tested one line below an unconditional `return` on the same condition. `DotGameDescriptor.cvars` was the same bug one field along: documented, exported, read by every host, and referenced once in the repository, so a descriptor's `cvars:` set nothing and the previous game's rules ran under the new name.

The client-scene rule ([game-switching.md](game-switching.md#delivered-or-shipped-in-the-build)) was found by the first example in the family to connect a client to a server running a real game scene: a game shipped with its own client could not be joined at all.

## Things built and never connected

- **No argument completer had ever run.** Seven builtins set `DotConCommand.completer`; the only reader, `complete_argument`, had no callers, so `kick Bo` completed nothing. The other half was in dot-console, whose panel returned early on any space. Two halves of one feature, each correct, never introduced.
- **An addon's commands could not be typed on a dedicated server** until `add_source`: dot-log's `log tail` existed only on clients, which have no log worth tailing.
- **The audit log never opened** in any default configuration ([boot.md](boot.md#boot-order-is-fixed-and-load-bearing)). It warned on every boot, which read like an unfilled setting.

## Smaller ones worth recognising

- **`admin_add <uid> moderator` created an admin holding a flag called "moderator"**, because a group name was parsed as a flag and unknown flags only warn ([security.md](security.md#permissions)).
- **Chat was refused for an operator holding the flag**, because the chat check ran before the permission check ([console.md](console.md#console-design)).
- **A freshly booted server stayed `RUNNING` until somebody joined and left**, so its map clock ran out to an empty room and the wake that restarts it never came.
- **A game loaded while the server slept started at 5 Hz** and a delivered netcode refused to start ([boot.md](boot.md#a-game-loads-awake)), found by dot-server-deploy's real-host playground check.
- **The first heartbeat left two seconds after joining**, so every game's netcode clock ran its first seconds without the flight time; game-arena measured under half of the first three seconds of commands arriving in time.
- **The notice sanitiser stripped only what is below 32**, so the zero-width characters and overrides refused as chat were drawn on the HUD; then it matched eleven of dot-chat's twenty-nine invisible code points.
- **Every game change left the old game's RPC node under `Server` on both ends**, and the next load of the same game got `@Node@<n>` from the name collision: a client returning to a game had every request dropped ("Failed to get path from RPC: Server/@Node@2370"). Suites passed because the engine logs and drops; only stderr showed it. Freeing the node at once traded that for in-flight errors; retiring it (renamed now, freed later) fixed both ([game-switching.md](game-switching.md#what-a-game-parents-under-server-goes-with-the-game)). dot-server-deploy's vote suites now count these errors through a `Logger`.
- **`quit` typed on a terminal shut the server down cleanly and then the process died with SIGSEGV (exit 139).** The stdin reader was a GDScript loop on a thread, blocked in `read_string_from_stdin` when the tree went down; the engine cannot cancel that read, and a GDScript frame on a live thread at teardown crashed the exit. A file on stdin hid it (the read ends first). The reader thread now runs `OS.read_string_from_stdin.bind(BUFFER)` itself, one read per thread, and no read is started once the server is `STOPPED`. Measured on a pty with script(1), Godot 4.7.2: `quit` exits 0 with no warning, `wait 60; quit` (a read still blocked at exit) exits 0, ctrl-c is the engine's default SIGINT (130, no shutdown). The engine returns `""` for an empty line and for end of input alike, so end of input is 64 empty reads in a row; the old loop turned the console off the first time an operator pressed enter on an empty line. An open pipe nobody closes still hangs the exit with either reader, which is why `stdin_console_pipes` stays off.
