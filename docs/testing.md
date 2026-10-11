# Testing

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/dedicated_server.tscn
godot --headless --path . res://examples/signon_revision.tscn
godot --headless --path . res://examples/content_switch.tscn

# Run it as an actual server instead of self-testing:
godot --headless --path . res://examples/dedicated_server.tscn -- --serve
```

Each suite exits non-zero on any failure and counts its sections and total, so a section a script error aborted is seen.

| Suite | Covers |
| --- | --- |
| `dedicated_server` | console parsing (quoting, semicolons, aliases, suggestions), every cvar flag, permissions and immunity, chat-source gating, config execution and traversal refusal, the command buffer and `wait`, ban durations and expiry, admin flag parsing, event cancel/rewrite, module load and clean unload, the audit trail, the sanitiser against the old definition, hibernation, `sv_tickrate` held to a boundary, `[bot quota]` on a real module, and the ban-source seam against a real dot-moderation (link `addons/dot_moderation`; the section says so loudly when it is missing) |
| `signon_revision` | the surface is exactly the six envelope RPCs, the revision is derived, a real join carries it and both adverts, a `DotNotice` (with `data`) crosses a real socket whole, a mismatch is refused in words, two builds that know different kinds play together or are refused in words when one lacks a required kind, the addon list rides the challenge, nothing bearer-secret arrives over UDP, the round trip is known within a second, and the scoreboard row matches the session's measured ping |
| `content_switch` | a real client, a real socket and a game that is actually DELIVERED: publish a signed pack, `changelevel` into it, back out and in again; the server hibernated first and awake for the load |

- **`content_switch` is the one that reaches the content path.** It needs two `MultiplayerAPI` instances, a socket and dot-cloud, which is why it is separate from the self-test.
- **The query protocols are tested in dot-server-query's own suite**, including the hook in both directions (a host attaching before the server booted and after).
- **The example sets `startup_config = ""`** on purpose: the addon ships a default `server.cfg` that the search path finds, which would make the test assert against whatever that file contains.
- **A one-process server-and-client test turns hibernation off** ([boot.md](boot.md#a-game-loads-awake)).
- **Arm every check**: put the bug back and see it fail. For the envelope, a seventh `@rpc`, an `adopt` that never refuses and a `should_send` that never filters each fail `signon_revision`.
- **A change here is not done until the games agree**: dot-server-deploy's `*_client` suites and the games' `headless_net` suites found most of this addon's bugs, through a second process, a real socket or a delivered game.
