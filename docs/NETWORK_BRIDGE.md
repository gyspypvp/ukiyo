# Network Bridge

How Clash Kick keeps sub-100 ms parry timing fair across clients without rubber-banding.
All remotes are declared in one place, [`src/shared/Net.luau`](../src/shared/Net.luau), which gives both sides the same typed `Remotes` table.

## Design rules

1. **Clients send intent, never results.** The client sends "I pressed Block at *t*", never "I parried". Every outcome is computed on the server.
2. **The combat hot path is fire-and-forget.** Launch, parry and ability use `RemoteEvent`. Nothing in a rally ever yields on a `RemoteFunction`, and the server **never** calls `InvokeClient`, because a malicious client could leave that call hanging forever.
3. **One clock.** Every timestamp on the wire is `workspace:GetServerTimeNow()`. Roblox keeps that clock synchronized between server and clients, so a client-side ETA and a server-side verdict refer to the same instant.
4. **Pick the channel by how the data behaves:**
   - *must arrive, once* (a kick started, a parry verdict) → `RemoteEvent` (reliable, ordered)
   - *replaced by the next packet anyway* (the live impact ETA) → `UnreliableRemoteEvent`
   - *persistent state* (who holds the Surge, who is stunned, round phase) → **Attributes**. They replicate automatically and are already correct for players who join mid-round.
5. **Validate everything.** Every client→server remote is rate-limited (token bucket) and its arguments go through `Guard` (type, NaN/inf, range) before use.

## Remote catalogue

### Client → Server: combat intent (`RemoteEvent`)

| Remote | Arguments | Rate limit | Server checks |
|---|---|---|---|
| `RequestLaunch` | `targetUserId: number, cameraCFrame: CFrame` | 4/s | holds Surge · not flying/stunned/targeted · 0.25 s cooldown · target alive, in range, allowed by the GameMode · camera within `CameraMaxZoomDistance + 12` of the body · target inside a 75° cone of that camera (the same dot product the client used) |
| `RequestParry` | `kickId: number, pressServerTime: number, lockUserId: number?` | 6/s | whiff cooldown · a kick is actually incoming · stamp clamped to measured latency · timing window · distance window · integrity heuristics (see below) |
| `RequestAbility` | — | 2/s | currently flying · equipped style · uses left this round · once per kick |
| `PingReply` | `nonce: number` | 3/s | nonce must match an outstanding random nonce |

### Server → Client

| Remote | Type | Audience | Payload | Purpose |
|---|---|---|---|---|
| `Ping` | RemoteEvent | each player, 1 Hz | `nonce` | RTT probe (see *Latency measurement*) |
| `KickStarted` | RemoteEvent | all | `KickStartedPayload` (kickId, attacker, target, rally, speed, startedAt, **eta**, perfect) | target shows the red warning; everyone draws trails |
| `KickUpdated` | **UnreliableRemoteEvent** | all, ≤ 20 Hz | `kickId, eta, sentAt` | keeps the warning ring locked to the server's live ETA. `eta = -1` while frozen (Lag Switch) |
| `KickResolved` | RemoteEvent | all | `KickResolvedPayload` (outcome `Parried`/`Hit`/`Cancelled`, perfect, direction, position, **rally, speed, damage, health, lethal**) | ends the warning; spark FX and damage numbers; the victim's hit card (who hit you, how much, why) |
| `ParryFeedback` | RemoteEvent | the presser only | `result, kickId, lockUntil` | "PERFECT!" / "TOO EARLY"; authoritative whiff-cooldown time |
| `Effect` | RemoteEvent | all | `EffectPayload` | Leg Style visuals (invisibility, decoys, glitch) |
| `RoundEvent` | RemoteEvent | all | `RoundEventPayload` (incl. `cause`: Kick / Void / Died / Left) | winner banner, KO feed, "knocked off by" card |

### Client → Server: lobby (`RemoteFunction`, request/response)

Used only in the lobby. These are never on the combat path, all are rate-limited (4/s), and all return plain data.

| Remote | Signature |
|---|---|
| `GetProfile` | `() -> ProfileSnapshot?` |
| `PurchaseUpgrade` | `(statId) -> (ok, message)` |
| `SpinCrate` | `() -> (ok, styleIdOrError, duplicate)` |
| `EquipLegStyle` | `(styleId) -> (ok, message)` |
| `PlaceBet` | `(targetUserId, amount) -> (ok, message)` |

### Attributes (persistent replicated state)

| On | Attribute | Meaning |
|---|---|---|
| `Player` | `CK_InArena` | live combatant this round |
| `Player` | `CK_Surged` | holds the Surge (may launch); drives the aura |
| `Player` | `CK_Flying` | currently a missile |
| `Player` | `CK_Stunned` | frozen mid-air after being parried, or tumbling after a hit |
| `Player` | `CK_Health`, `CK_MaxHealth` | HP while in the arena (drives HUD + overhead health bars); removed when out of the arena |
| `Player` | `CK_Flagged` | integrity heuristic tripped (for moderation tooling) |
| `ReplicatedStorage.ClashKickState` | `Phase`, `PhaseEndsAt`, `Mode`, `AliveCount`, `RoundId` | round state machine; `PhaseEndsAt` is server time |

## How a parry stays fair at high speed

```
 server time ─────────────────────────────────────────────────────────────▶
   kick launched                      contact             verdict
   (KickStarted, eta)                 (impactAt)          (resolveAt)
        │                                 │◀── clash hold ──▶│
        ▼                                 ▼                  ▼
 ───────●═════════ flight ════════════════●══════════════════●──────
                         ◀─── window ────▶
                       (BaseWindow + upgrade)
                                ▲
             defender presses F │ stamp = GetServerTimeNow()
                                │
                                └──── travels up (one-way latency) ──▶ arrives
```

1. **The warning is driven by the clock.** The defender sees the *attacker's model* about 100 ms late (one-way latency plus interpolation). The ring, though, is drawn from `eta - GetServerTimeNow()`, the server's own prediction on the shared clock, so the cue closes at the moment the server will judge. Each `KickUpdated` carries `sentAt`, so out-of-order unreliable packets are dropped.
2. **Lag compensation is bounded.** The press stamp is clamped:
   `pressedAt = clamp(stamp, receivedAt − maxRewind, receivedAt)`, where
   `maxRewind = clamp(rtt + jitter + 0.02, 0, 0.25 s)`. An honest stamp passes unchanged. A forged one ("I pressed 1 s ago") is pulled back to the edge of what this player's measured latency allows.
3. **The verdict waits instead of positions rewinding.** When the kicker reaches contact, the server enters a short **clash hold** of `0.05 s + maxRewind(defender)` before it confirms the hit. A Block that was pressed in time but is still in transit lands inside that hold. Nothing is ever rewound or snapped back, so nobody rubber-bands. The kicker visibly "clashes" against the defender for a beat, and that becomes part of the game feel.
4. **The check is timing *and* distance.** `tti = impactTime − pressedAt`, where `impactTime` is the real contact time once known and otherwise the freshest prediction. Then:
   `tti > window` → Early · `tti < −0.03` → Late · `tti ≤ 0.10` → **Perfect** · else Parry.
   As an independent check, the gap the server *recorded* at `pressedAt` must be reachable within the window:
   `gap ≤ ImpactRadius + (kickSpeed + runCap) × (window + maxRewind) + slack`.
5. **Ownership is stable.** The kicker's physics is server-owned for the whole flight and stun. Ownership changes exactly twice per kick (take on launch, return on landing), so the per-packet ownership flapping that causes jitter never happens.
6. **Outcomes are never predicted.** The client plays its block swing instantly (that is just feedback), but it never assumes the parry *succeeded*. There is nothing to roll back.

## Latency measurement

`LatencyService` sends `Ping(nonce)` every second with a **random** nonce and times the reply with `os.clock()`.

- A client cannot reply before receiving the nonce, so it **can't make its RTT look lower** than reality.
- It *can* delay replies to look laggier and fish for a bigger rewind. That is bounded three ways:
  1. RTT is the **median** of the last 9 samples, so isolated spikes are ignored;
  2. the engine's `Player:GetNetworkPing()` is used as a loose upper bound;
  3. the hard cap `Config.Latency.MaxCompensation = 0.25 s`.

## Anti auto-parry

An auto-parry script sees exactly what the client sees, so it can always press "in time"; no network design can make that information secret. The server therefore makes it **costly to guess** and **visible when it isn't human**:

- **Whiff cooldown** (0.45 s): any Block that parries nothing locks you out. Spam and naive macros fail.
- **No pre-pressing**: a press stamped before the kick existed is a whiff, even if it arrives afterwards.
- **Integrity heuristics** (rolling window of 12 parries):
  - *metronome:* ≥ 90 % Perfect **and** a timing spread under 12 ms;
  - *inhuman reactions:* ≥ 4 parries of **unpredictable** kicks (opening kicks or redirects, not the inevitable ricochet back at you) faster than 100 ms after the kick became visible.
  - A trip sets `CK_Flagged`, logs, and fires `CombatService.Flagged`. Kicking is behind `Config.Integrity.KickOnFlag` until the thresholds are tuned on real data.

## Bandwidth

Per active kick: one `KickStarted` (~100 B), at most 20 `KickUpdated`/s (3 numbers, ~30 B each, sent only on drift), and one `KickResolved`. A full 15-player lobby in a fast rally costs about 1 KB/s per client in combat traffic, well inside Roblox's ~50 KB/s budget.
