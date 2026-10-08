# Architecture

## Roblox Explorer layout

The repo is a [Rojo](https://rojo.space) project (`default.project.json`). This is what it builds in Studio:

```
ReplicatedStorage
├── Shared                               (Folder · src/shared)
│   ├── Config            ModuleScript   every tuning number (frozen)
│   ├── CombatMath        ModuleScript   pure math: speed compounding, parry verdict, lag comp, ricochet gap
│   ├── Targeting         ModuleScript   camera dot-product lock-on (client picks, server re-checks)
│   ├── Net               ModuleScript   NETWORK BRIDGE: declares/creates every remote, attribute names
│   ├── Types             ModuleScript   network payload types
│   ├── AbilityData       ModuleScript   Leg Styles (rarity, drop weights, params)
│   ├── UpgradeData       ModuleScript   coin upgrades (WalkSpeed, JumpPower, ParryWindow)
│   └── Signal            ModuleScript   tiny typed, deferred event
├── ClashKickRemotes                     (Folder, created at runtime by Net.server())
└── ClashKickState                       (Folder, created at runtime; round-state attributes)

ServerScriptService
└── Server                               (Folder · src/server)
    ├── Main              Script         entry point: init order + mode registration
    ├── ServerTypes       ModuleScript   GameMode / RoundContext / CombatRules contracts
    ├── Services
    │   ├── CombatService     ModuleScript   SERVER COMBAT MODULE: physics, parry validation, speed
    │   ├── RoundManager      ModuleScript   phase state machine, delegates rules to the GameMode
    │   ├── LatencyService    ModuleScript   nonce-ping RTT (lag-compensation budget)
    │   ├── AbilityService    ModuleScript   Leg Style behaviours (server truth)
    │   ├── PlayerDataService ModuleScript   coins, upgrades, styles, crates, DataStore
    │   └── BettingService    ModuleScript   spectator bets on the round winner
    ├── GameModes
    │   ├── SurgeMode         ModuleScript   Free-For-All Rally (live)
    │   └── JuggernautMode    ModuleScript   Tagger vs. Lobby (draft, not in rotation)
    └── Util
        ├── Guard             ModuleScript   validators for untrusted remote args
        └── RateLimiter       ModuleScript   per-player token buckets

StarterPlayer
└── StarterPlayerScripts
    └── Client                           (Folder · src/client)
        ├── CombatController  LocalScript    CLIENT COMBAT CONTROLLER: lock-on, input, remotes, warning UI
        ├── CombatFX          ModuleScript   cosmetic effects (aura, sparks, decoys, invis)
        └── RoundController   LocalScript    phase HUD, Final Duel FOV + music, winner banner
```

Only two kinds of top-level code run: one server `Script` (`Main`) and two client `LocalScript`s. Everything else is a ModuleScript with an explicit `init`, so the start-up order is visible in one file.

## Who owns what

| Concern | Owner | Notes |
|---|---|---|
| *When* things happen (phases, timers, teleports, payouts) | `RoundManager` | mode-agnostic |
| *What the rules are* (Surge assignment, targeting, what a KO means, win condition) | the active `GameMode` | swappable |
| Kick physics, contact, parry validation, speed | `CombatService` | asks the mode via `CombatRules` |
| Latency budget | `LatencyService` | consumed by `CombatService` |
| Ability behaviour | `AbilityService` | gets a narrow `FlightControl` handle, never the raw flight |
| Economy | `PlayerDataService`, `BettingService` | all mutations server-side |
| Input, lock-on, warning UI | `CombatController` | sends intent only |
| Cosmetics | `CombatFX`, `RoundController` | never affect gameplay |

## How modularity works

```
 RoundManager ──CombatRules{canTarget}──▶ CombatService
      ▲   │                                    │
      │   │  RoundContext                      │ Signals (deferred):
      │   ▼  {getAlive, isAlive, eliminate,    │  Defeated(victim, attacker?, cause)
      │   GameMode   combat = CombatApi}       │  Parried(defender, attacker, perfect, rally)
      │   (Surge |          │                  │  Launched, Flagged
      │    Juggernaut)      └─grantSurge/──────▶ CombatService
      └─────────── forwards Defeated/Parried ◀──┘
```

- **CombatService never decides who wins or who gets eliminated.** When a kick lands it fires `Defeated(victim, attacker, "Kick")` and stops there. The mode decides what that means: Surge eliminates, a future Juggernaut could spend a life instead.
- **Targeting is a rule, not a hard-code.** Before any launch, redirect or auto-target, CombatService asks `rules.canTarget(attacker, target)`. Surge allows anyone; Juggernaut lets runners hit only the tagger.
- **Surge ownership is an API.** Modes call `grantSurge` / `clearSurge` / `getSurgeHolders`. Surge re-infects a random survivor after each KO; Juggernaut always returns it to the tagger. Neither needs to know anything about flights.
- **Signals are deferred.** Handlers run after CombatService finishes its current update, so a mode calling `eliminate()` → `unregisterCombatant()` can never re-enter half-updated combat state.

### Adding the Juggernaut mode (or any mode)

1. Implement `ServerTypes.GameMode` in `src/server/GameModes/<Name>Mode.luau` (`JuggernautMode.luau` is a complete draft).
2. Register it in `Main.server.luau`: `RoundManager.registerMode(require(GameModes.<Name>Mode))`.
3. Add its name to `Config.Round.ModeRotation`.

No changes to CombatService, RoundManager, the client or the network layer.

## Lifecycle of one round

```
Waiting ─▶ Intermission (15 s) ─▶ Spawning ─▶ Active ─▶ FinalDuel ─▶ MatchEnd ─▶ Intermission …
              lobby: upgrade,      teleport +   mode.     2 alive:     payout, bets,
              spin crates, bet     register     onTick    FOV + music  back to lobby
```

- **Spawning:** up to 15 eligible players are shuffled onto arena spawns, then `CombatService.registerCombatant` gives each a LinearVelocity rig (disabled) and the `CK_Characters` collision group.
- **Active:** `mode:onRoundStart` grants the first Surge. The RoundManager ticks `mode:getResult` / `isFinalPhase` / `onTick` every 0.1 s.
- **KO:** CombatService fires `Defeated` → the mode calls `ctx.eliminate` → combatant unregistered, killer paid, client flings itself (cosmetic) → teleported to the lobby after 1.25 s to spectate and bet.
- **MatchEnd:** winner payout, participation coins, bets settled (refunded if there's no single winner), survivors return to the lobby.
- A crash inside a round is caught (`xpcall`), combat is reset, and the loop continues.

## Anti-exploit summary

| Exploit | Defence |
|---|---|
| Speed-hack / teleport **during a kick or stun** | the server takes network ownership of the character (`SetNetworkOwner(nil)`); the client's local physics is ignored |
| Claiming hits | there is no hit remote; contact is server math on server positions |
| Speed-hack / teleport while walking | horizontal speed check every 0.5 s against `WalkSpeed`; rubber-band to the last good position |
| Faking velocity to bend the ETA or ricochet gap | client-reported velocity is clamped to what the humanoid can legitimately do before it feeds any math |
| Auto-parry / forged timestamps | stamp clamped to measured RTT; timing **and** distance checks; whiff cooldown; no pre-press; metronome / inhuman-reaction heuristics |
| Faking low ping | random-nonce pings can only make RTT look worse; median plus engine cross-check plus a 0.25 s cap bound "worse" |
| Launching without the Surge / at anyone | server re-checks holder, cooldowns, range, mode rules, camera plausibility |
| Remote spam / malformed args | token-bucket rate limits on every remote; `Guard` validates type, NaN/inf and range |
| Economy tampering | coins, upgrades, crates and bets are server-side; receipts are idempotent |
| Falling out of the map to dodge | below `KillY` counts as a KO |

## Map setup

Tag parts with CollectionService tags (Studio's Tag Editor works):

- `CK_ArenaSpawn`: BaseParts in the arena (one per player is ideal; they are reused if there are fewer)
- `CK_LobbySpawn`: BaseParts in the lobby

Optional: a `SoundService/ClashKickMusic` folder with `Lobby`, `Battle`, `Duel` Sounds (set a `Volume` number attribute to override the default 0.5).
