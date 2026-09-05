# Server queries

Two protocols, either or both, chosen by an operator:

| | **DQP** (dot query protocol) | **A2S** (the twenty-year-old one) |
| --- | --- | --- |
| Default | on | off |
| Transport | UDP, and WebSocket when enabled | UDP only |
| Body | JSON, gzip optional | packed bytes, positional |
| Extensible | add a field | break every parser |
| Challenge | always, address-bound | `A2S_INFO` since 2020 |
| Game state | a whole section | substrings in `keywords` |
| Conditional polling | yes (`if_rev`) | no |
| Reachable from a browser | yes | never |
| Existing tooling | none | twenty years of it |

That last row is the only reason A2S is here, and it is a good enough one. Every
server-list site, chat bot and uptime monitor speaks A2S and nothing else.

Both answer from the same `DotQuerySnapshot`, so they never disagree, and by default
both listen on **one UDP socket on the game port** — the only port a tracker will
try. They are told apart by the first four bytes: `FF FF FF FF` is A2S, `DQP1` is
this.

---

## Configuration

```gdscript
config.query_enabled = true          # DQP. On by default.
config.a2s_enabled = true            # A2S. Off by default.
config.query_port = 0                # 0 -> the A2S port, so one socket serves both
config.a2s_port = 0                  # 0 -> the game port
config.query_websocket = true        # DQP as JSON over WebSocket, for browsers
config.query_player_detail = "full"  # full | names | count | none
config.query_secret = ""             # set to sign responses
```

At runtime: `sv_query`, `sv_a2s`, `sv_query_players`. Turning either off stops it
answering without closing the socket, so it comes back without the port moving under
whatever was polling it. `query_status` shows both; `query_dump` prints the response
a querier would get.

**A UDP game transport (ENet) already holds the game port**, so the bind fails and
the log says exactly that. Set `query_port` to a free one — and know that most
trackers will not look there.

---

## DQP wire format

Every packet — request, response, fragment, error — starts with the same 26-byte
header. Little-endian throughout.

```
offset size  field
0      4     magic, ASCII "DQP1"
4      1     type
5      1     flags
6      4     uint32  transaction id     echoed in the reply
10     4     uint32  response id        shared by every fragment of one response
14     2     uint16  fragment count     1 when not fragmented
16     2     uint16  fragment index     0-based
18     8     uint64  challenge cookie
26     ...          payload
```

### Types

| Value | Name | Direction |
| --- | --- | --- |
| `0x01` | `QUERY` | → server |
| `0x02` | `CHALLENGE_REQUEST` | → server |
| `0x03` | `PING` | → server |
| `0x81` | `RESULT` | ← server |
| `0x82` | `CHALLENGE` | ← server |
| `0x83` | `ERROR` | ← server |
| `0x84` | `PONG` | ← server |

The high bit marks a response. A server that receives one **never answers it** —
that is how two servers become a reflection loop.

### Flags

| Bit | Name | Meaning |
| --- | --- | --- |
| `0x01` | `GZIP` | this packet's payload is gzip-compressed |
| `0x02` | `FRAGMENTED` | set on every fragment, including the first |
| `0x04` | `ACCEPT_GZIP` | request only: the sender can decompress a gzip reply |

`GZIP` and `ACCEPT_GZIP` are separate bits deliberately. Sharing one made the header
un-parseable without already knowing which direction the packet was travelling.

A **request** carrying `GZIP` is refused. Requests are small by construction, so a
compressed one is a broken client or a zip bomb.

### Limits

| | |
| --- | --- |
| Datagram | 1200 bytes, so it fits under IPv6's minimum MTU without IP fragmentation |
| Payload per datagram | 1174 bytes |
| Fragments per response | 16 (a body needing more is refused with an `ERROR`, not truncated) |
| Request | 1024 bytes |

---

## The exchange

```
client                                   server
  |  QUERY  challenge=0                     |
  |---------------------------------------->|
  |                     CHALLENGE  cookie=X |   26 bytes, smaller than the request
  |<----------------------------------------|
  |  QUERY  challenge=X  {"sections":[...]} |
  |---------------------------------------->|
  |                       RESULT  {...json} |
  |<----------------------------------------|
```

A client that already holds a cookie skips the first two lines. Cookies last
`query_challenge_ttl_sec` (30s by default) and up to twice that, since the previous
time bucket is accepted too.

### Why the challenge exists

UDP source addresses are forged trivially, and a query is a small request producing a
large response — the exact shape of a DDoS amplifier. Send a 30-byte packet with a
victim's address in the source field and the server mails the victim a kilobyte.

The cookie is `HMAC(secret, address|port|bucket|width)`, **bound to the address and
port it was mailed to**. A forger never receives it, so it can never present one.
Nothing is stored: a challenge table is itself a memory-exhaustion target — ask for a
million challenges from a million forged addresses and the server holds them all.
This holds one 32-byte secret regardless. Same reasoning as a SYN cookie.

The secret is generated at boot and never persisted, so a restart invalidates every
outstanding cookie. That is correct — a restart invalidates everything else too.

`PING` is answered without a challenge, because `PONG` is smaller than the request
that asked for it. There is nothing to amplify.

---

## Request body

JSON, or empty. All fields optional.

```json
{
  "sections": ["info", "players", "rules", "game"],
  "if_rev": 41
}
```

- **`sections`** — what to return. Defaults to `["info"]`. Maximum 8. An unrecognised
  name is reported in `unknown` rather than dropped, so a client that misspells
  `players` does not conclude the server is empty.
- **`if_rev`** — the revision the client already holds. Matching it returns
  `{"rev":…, "unchanged":true}` and nothing else.

---

## Response body

```json
{
  "rev": 42,
  "etag": "9f2c…",
  "ts": 1756412345,
  "sections": { "info": {…}, "players": […], "rules": {…}, "game": {…} },
  "truncated": ["players"],
  "unknown": ["playerz"]
}
```

### `rev` — what makes polling nearly free

The revision changes **only when something meaningful did**. A tracker sends the
revision it holds and gets forty bytes back when nothing moved; a list of a thousand
servers refreshed every thirty seconds costs almost nothing on either end.

Uptime and per-player timers are excluded from the hash it is derived from. They
advance every second, and hashing them would make every rebuild a new revision — the
feature would never once save a byte.

### `info`

```json
{
  "protocol": 1,
  "name": "A dot server",       "server_id": "eu-1",
  "map": "dm_arena",            "game_id": "arena",
  "game": "Arena Deathmatch",   "folder": "dot",
  "version": "0.1.0",           "game_version": "1.4.0",
  "players": 12,                "bots": 4,
  "connecting": 2,
  "max_players": 32,            "reserved_slots": 2,
  "visibility": "public",       "server_type": "dedicated",
  "os": "linux",                "secure": false,
  "tags": ["eu", "casual"],
  "port": 27015,                "tickrate": 60,
  "uptime": 84213,              "state": "running",
  "transport": "websocket",     "web_clients": true,
  "content": true,
  "query": { "protocol": "DQP1", "version": 1, "port": 27015, "websocket_port": 27018 }
}
```

**`connecting` is the field A2S has no room for**, and it is the difference between
"empty server" and "server nobody can finish joining". Clients that are connected but
still authenticating, downloading or loading are counted here, not in `players`.

`name`, `max_players` and `visibility` are read through the console, so an operator
who typed `hostname "Something Else"` sees it in the listing immediately rather than
after a restart.

### `players`

Governed by `query_player_detail`:

| Setting | Fields |
| --- | --- |
| `full` | `name`, `score`, `duration`, `userid`, `ping`, `bot`, `state` |
| `names` | `name`, `score`, `duration` — what A2S gives |
| `count` | no list; the count is in `info` |
| `none` | section omitted entirely |

**No setting ever emits an account identifier.** dot-user's whole point is that an
operator cannot correlate their players across servers; publishing the uid to anyone
who sends a datagram would undo that from the other direction.

Capped at `query_max_players_listed` (128), and `truncated` says so — a tracker
showing 128 of 400 with no indication is worse than one showing none.

### `rules`

Server variables, as `name → value`. A cvar appears when it carries `FLAG_NOTIFY` or
`FLAG_REPLICATED` (other servers publish a notify-flagged variable for the same
reason: a variable
that changes how the game plays is what somebody deciding whether to join wants), or
when it is named in `query_extra_rules`.

**`FLAG_PROTECTED` and `FLAG_HIDDEN` are refused regardless.** Naming a protected
cvar in `query_extra_rules` does not publish it. The flag exists precisely because
that value must never leave the server, and a config file is not a good enough reason
to make an exception.

### `game`

Whatever a `DotQueryProvider` contributes — see below. Empty when nothing does.

### `auth`

Present only when `query_secret` is set:

```json
"auth": { "ts": 1756412345, "nonce": "a3f…", "sig": "hmac-sha256 hex" }
```

Signed over `"{ts}.{nonce}.{json of the body without auth}"`. For a listing service
that must know the server really said this, rather than somebody forging a busy
server to climb a list. Same `ts` + `nonce` + signature shape the backbone's
integration requests use, so a site verifying both needs one implementation.

---

## Fragmentation

A payload over 1174 bytes is split. Every fragment carries the whole header, so a
receiver can reassemble without having seen the first one — which on UDP it
frequently has not.

To reassemble: group by `response_id`, collect `fragment_count` fragments, order by
`fragment_index`, concatenate the payloads, then gunzip if `GZIP` is set. Fragments
whose `response_id` differs belong to another response and must be discarded, not
blended — a querier on a busy socket receives interleaved responses, and stitching a
piece of one into the other produces a body that parses and is wrong.

A2S's multi-packet format differs between engine branches and again when compressed,
and is the single most common source of broken query clients. There was nothing to
gain from reproducing that.

---

## WebSocket

With `query_websocket` on, the same protocol is served as **plain JSON text frames**
on TCP — no binary header, no challenge.

```js
const ws = new WebSocket("ws://example.com:27018");
ws.onopen = () => ws.send(JSON.stringify({ sections: ["info", "players"] }));
ws.onmessage = e => console.log(JSON.parse(e.data));
```

Send the request body; receive the response body. Errors arrive as
`{"code": "...", "error": "..."}`.

**No challenge here, and that is not an oversight.** The cookie proves a UDP source
address is real. A WebSocket has completed a TCP handshake and an HTTP upgrade, so
the transport already proved it, and the response goes back down the same connection
where it cannot be aimed at anybody else.

This is what an in-browser server browser needs. A web page cannot open a UDP socket,
so it can never speak A2S at any price — and "click a link and play" needs a server
list for the link to come from.

Connections are capped, dropped after 30 seconds idle, and rate limited per address
like the UDP path.

---

## A minimal UDP client

```python
import json, socket, struct, gzip

MAGIC, HDR = b"DQP1", 26

def pack(type_, txn, challenge, body=None, accept_gzip=True):
    payload = json.dumps(body).encode() if body else b""
    flags = 0x04 if accept_gzip else 0
    return MAGIC + struct.pack("<BBIIHHQ", type_, flags, txn, 0, 1, 0, challenge) + payload

def unpack(dgram):
    assert dgram[:4] == MAGIC
    type_, flags, txn, rid, total, index, challenge = struct.unpack("<BBIIHHQ", dgram[4:HDR])
    return dict(type=type_, flags=flags, txn=txn, rid=rid,
                total=total, index=index, challenge=challenge, payload=dgram[HDR:])

def query(host, port, sections=("info", "players")):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3.0)
    s.connect((host, port))

    s.send(pack(0x02, 1, 0))                       # CHALLENGE_REQUEST
    cookie = unpack(s.recv(1500))["challenge"]

    s.send(pack(0x01, 2, cookie, {"sections": list(sections)}))

    first = unpack(s.recv(1500))
    if first["type"] == 0x83:                      # ERROR
        raise RuntimeError(json.loads(first["payload"]))

    chunks = {first["index"]: first["payload"]}
    while len(chunks) < first["total"]:
        f = unpack(s.recv(1500))
        if f["rid"] == first["rid"]:
            chunks[f["index"]] = f["payload"]

    body = b"".join(chunks[i] for i in range(first["total"]))
    if first["flags"] & 0x01:
        body = gzip.decompress(body)
    return json.loads(body)

print(query("127.0.0.1", 27015))
```

---

## Contributing game state

A2S has four fixed questions. Any game that does not fit them — a round number,
per-team scores, the next map, a lobby's ready count, how much of a match is left —
has historically smuggled it into the keywords string as `r3,t1:8,t2:5` and hoped.

```gdscript
class ArenaQuery extends DotQueryProvider:
    var match_state: DotMatchState

    func _provider_name() -> String:
        return "arena"

    func _contribute(snapshot: DotQuerySnapshot) -> void:
        snapshot.info["bots"] = match_state.bot_count()
        snapshot.contribute_game({
            "phase": match_state.phase_name(),
            "round": match_state.round_number,
            "scores": match_state.team_scores(),
            "time_left": match_state.seconds_remaining(),
        })

var provider := ArenaQuery.new()
provider.match_state = state
DotRegistry.get_service(&"dot_query_source").add_provider(provider)
```

Any object with `_contribute(snapshot)` works, so a game can use a `Node` it already
has. Registration is validated when it happens, so a mistyped provider is a startup
error rather than a section that silently never appears.

**The bot count is the important one.** Nothing in dot-server can know it — a bot is
a game concept and the server never sees one connect — so it reaches A2S's bot byte,
DQP's `info.bots` and the backbone stats report only through a provider.

**A provider runs on the query path, which anyone with the address can reach.** Keep
it cheap, and keep it free of anything a player should not see. It is called at most
once per rebuild interval (1s), not once per query, so a flood costs one call.

From a module, register through `add_query_provider()` — a provider left behind by an
unloaded module is called on the next query with `self` pointing at a freed object.

---

## A2S support

Requests: `A2S_INFO` (`0x54`), `A2S_PLAYER` (`0x55`), `A2S_RULES` (`0x56`),
`A2S_SERVERQUERY_GETCHALLENGE` (`0x57`), `A2A_PING` (`0x69`).

All four query types are challenged, `A2S_INFO` included — the protocol added that
in 2020
after years of reflection attacks, and modern query libraries handle it. One old
enough not to is old enough to be a reflection risk.

Notes on the encoding:

- Counts are bytes. A 4096-slot server genuinely cannot be described by A2S, so the
  values are **clamped**, not wrapped: `4096 & 0xFF` is 0, which reads as an empty
  server.
- Strings are truncated on bytes and then repaired, because a hostname cut mid-UTF-8
  sequence makes a validating client drop the entire response — a server that
  vanishes from listings only once somebody renames it.
- `keywords` (EDF `0x20`) carries the server tags plus `dqp:<port>`, so a tracker
  that understands it can upgrade to the protocol that will actually tell it
  something.
- Multi-packet responses use the protocol's `FE FF FF FF` format, capped at 8 packets.
  The reassembled payload is the complete single-packet response, leading
  `FF FF FF FF` included.
- `steamid`, `spectator` and `gameid` extra-data fields are not sent. There is no
  platform identity behind this and inventing one would be a lie a client acts on.

**A2S publishes player names, scores and connection times to anyone who asks, and
always has.** `query_player_detail` governs it here too: `count` or `none` produces
an empty `A2S_PLAYER` list. The server logs this once at boot, because an operator
who turned A2S on to be listed may not have meant to publish a roster.

---

## Cost and abuse

| Control | What it stops |
| --- | --- |
| Address-bound challenge | reflection and amplification against a third party |
| `query_rate_per_second` / `_burst`, per address | one source making the server work |
| `query_cache_sec` (1s) | a flood costing a session-table walk per packet |
| 16-fragment ceiling, refused not truncated | a small request producing 400 kB |
| 1024-byte request cap | buffering attacker-controlled data |
| Requests never fragment | holding attacker-controlled reassembly state |
| WebSocket connection cap and idle drop | holding file descriptors |

The snapshot cache is a security control, not an optimisation. Gathering one walks
every session and every cvar; doing that per packet is the cheapest denial of service
there is, and unlike a flood of game traffic it does not even need a connection.
