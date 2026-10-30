# Permissions, security and bans

## Permissions

**Flags, not roles**, because operators do not agree on what a "moderator" is. **Strings, not bits**, so a game adds `"give_weapon"` without coordinating with `DotAdminFlags`. Unknown flags are **reported, not refused**: they are legal for a game and also what a typo looks like.

- `slay` and `teleport` are `DotAdminFlags.SLAY` and `TELEPORT` because dot-moderation's live tools use them in every game, and a group file must name them without an "unknown flag" warning. **`slay` is handling a person** (slay, slap, freeze, respawn, rename) and is a moderator's; **`cheats` is changing the game** (noclip, god, health, speed, gravity, give); `teleport` is separate because it looks most like cheating from outside. Those commands are registered by dot-moderation onto this console, duck-typed.
- **Immunity is separate from flags**: "may kick" and "may be kicked" are different questions. Equal immunity cannot act on equal, because two equal admins kicking each other has no correct resolution.
- **Sources merge**: a player in a file entry and a site group gets the union of flags and the higher immunity. `DotAdminManager.add_source` validates the duck-typed contract at registration, so a mistyped source is a startup error.
- **A malformed `admins.json` or `bans.json` is loud and keeps the previous state.** Silently meaning "no admins" turns a typo into an unmoderated server.
- **A session keeps its group names** (`DotClientSession.groups`, from the file and any source returning `groups`). A flag says what somebody may do; a game also wants to know who somebody is (game-playground's per-role spawn limits read it).
- **`admin_add` resolves a group first and falls back to flags**, and refuses a single token matching neither, listing the known groups. It once passed every word as a flag, so `admin_add <uid> moderator` created an admin holding a flag that grants nothing, and `admin` (both a flag and a group in the template) meant something else entirely.

## Permissions for somebody who is not connected

- **`DotAdminManager.uid_permissions(uid)`** returns `{flags, immunity, groups}` from the admin file, merging the entry's flags with every group it names and taking the higher immunity (a group is a floor, an entry a promotion). `uid_has_permission` reads it rather than walking the entry again. It answers for the **local file only**, deliberately: a source such as dot-auth's needs an identity, which only a connection carries.
- **`DotServer.run_command_as_uid(uid, command, args, source)`** runs a console command as that person and returns the reply lines, with **the uid's own permissions, not RCON's `ROOT`**. A command relayed from a website, a chat bridge or a scheduled job can do exactly what that person could do in the server. It defaults to `Source.CHAT`, the least trusted path.

## Security decisions worth not undoing

- **`rcon_password` empty means the listener does not open.** No configuration produces an unauthenticated remote console.
- **RCON and server passwords compare in constant time**; early return leaks how many leading characters matched.
- **RCON checks `rcon_allowed_addresses` before the password** and locks out an address after `rcon_max_failures`; the allow-list is the control that survives a leak. Matching is on **normalised** addresses, so an IPv4 client reported mapped into IPv6 (`::ffff:192.168.1.5`) matches an entry written either way. A prefix entry must end in a dot (`192.16.` does not cover `192.168.1.1`); `DotServerConfig` warns about a prefix-shaped entry missing its dot.
- **`exec` refuses path traversal**: it is reachable over RCON.
- **An authenticated player cannot override their display name**; only guests may name themselves.
- **Chat is sanitised before anything else**: control characters, zero-width characters and bidirectional overrides stripped, whitespace collapsed, then truncated. `DotChatManager.is_refused` and `INVISIBLE` are a copy of dot-chat's `DotChatFilter` list (C1 controls and the twenty-nine invisible code points), a copy because dot-server names no addon; `dedicated_server` writes the list out rather than reading the constant, so a shrinking constant is seen. The sanitiser is linear and stops one character past its limit. `DotNotice` text gets the same cleaning.
- **`DotClientLink._resolve_scene` refuses absolute paths from the server** outside the content mount; otherwise a malicious server could make a client load any scene in its build.
- **The client `ensure`s content rather than `acquire`s it**, so a manifest that does not answer to the id and version the client was told is refused rather than mounted under the expected key.
- **Admin chat is filtered server-side.**
- **A client reporting the wrong content key is rejected**.

## Sharing a ban list across servers

`DotBanManager.store` is a `DotBanStore`; the default keeps a JSON file per server. A community with several servers subclasses it to point at a database or an HTTP service.

- **Loads may be slow; checks are not.** The loaded set is in memory and every connection is answered from it; a remote store is queried at startup and on writes, never on the join path.
- **A failed load keeps what is already in force.** An empty list would readmit everyone ever removed.
- **`_writable() == false`** is legitimate (a server enforcing a central list); `ban` reports it rather than appearing to work.
- **Writes are awaited before the in-memory set changes**, so `ban_uid`, `ban_address`, `ban_session` and `unban` are coroutines. `await bans.unban(x).ok` binds the await to the property: assign the result first.
- **Expiry sweeping is local only**; expired bans are refused on read regardless.

## Somebody else's ban list: `dot_ban_source`

Whatever registers under `dot_ban_source` (dot-moderation, in this family) answers `check_admission(uid: String, address: String) -> DotResult`. `DotServer.check_address_admission` asks with the address alone before a client says who it is; `check_identity_admission` asks again with both. Same shape as `dot_mute_source`.

- **A registration that cannot answer is reported once, loudly, then ignored.** Admitting everybody is wrong; refusing everybody would take the server down. Four call sites in the family have found a service that did not speak the method called, each with no error at all.
- **The seam is read-only.** `ban`, `banid` and `banip` write to `DotBanManager`; a deployment that wants dot-moderation to be the ban list issues bans through it and leaves `DotBanManager` empty. Two write targets is the two-lists problem.
- **`enforce_bans()`**: a ban against somebody already connected takes effect now, not on their next connect. `ban`, `banid` and `banip` call it, which is also how an address ban removes the others behind that address.
- A host that chains onto the seam must re-chain after a game change, because the loaded game's moderation re-registers it and `DotRegistry` is last-wins (dot-server-deploy's `TmcParty` does).

## Limiting connections from one address

`sv_max_connections_per_ip` (`DotServerConfig.max_connections_per_ip`, `DotAddressGuard`), 0 by default, live. It is neither a ban nor a rate limit: it stops one machine holding twelve slots of sixteen by connecting slowly.

- **It holds no count of its own**: it is told the addresses in use and counts them. A hand-kept counter drifts the first time a path forgets to decrement.
- **Loopback is never limited**, or it locks the operator and every headless test out.
- **An address the transport could not report (`"unknown"`) is never limited**, or every such client shares one bucket.
- **Live, not startup-only**: an operator turns it on while the problem is happening.

## Banning an account also bars guests from its address

`DotBanManager.ban_session` on a signed-in account also records a guests-only address ban (`gip:<address>`, `ban_guests_with_account`, default on; length capped by `guest_ban_max_sec`, default 7 days). Signed-in players behind the same address are not affected, and `unban` of the account lifts it. A ban placed through a `dot_ban_source` gets the same one: dot-server follows its `punished`/`revoked` signals and, for a connected account, calls `ban_guests_at` / `lift_guest_bans`. An account that is not connected when banned has no address to record.
