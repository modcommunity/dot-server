# dot-server docs

The reasoning behind [../CLAUDE.md](../CLAUDE.md)'s rules.

| File | Subject |
| --- | --- |
| [boot.md](boot.md) | Boot order, startup-only cvars, the two command-line passes, hibernation, the live tick rate, loading awake |
| [signon.md](signon.md) | The join state machine, hidden browser tabs, `DotSignon`, the frozen RPC surface and `DotEnvelope` kinds, the addon set in the challenge, early heartbeats, the metered peer |
| [transports.md](transports.md) | WebSocket and ENet in one match, the shared UDP port, no bearer secret over ENet |
| [game-facing.md](game-facing.md) | `DotNotice`, the scoreboard roster, chat state, `DotBotQuota` |
| [console.md](console.md) | Console flags and contexts, chat commands, `map` vs games, `add_source`, completion, modules, naming a player |
| [security.md](security.md) | Permissions, offline permissions, security decisions, shared and external ban lists, the per-address limit |
| [game-switching.md](game-switching.md) | The change flow, delivered vs built-in games, pack lists, optional addons, the query hook |
| [testing.md](testing.md) | The four suites and what each covers |
| [history.md](history.md) | Bug stories worth keeping |
| [design-notes.md](design-notes.md) | The reasoning behind the envelope, the address guard, the event bus, modules and the bot quota, with usage examples |
| [api-levels.md](api-levels.md) | What each `DotServerApi` level added |
