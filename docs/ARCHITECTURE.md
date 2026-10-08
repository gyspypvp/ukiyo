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
    │   ├── SurgeMode         ModuleScript   Free-For-All Rally: everyone kicks, everyone blocks (live)
    │   └── JuggernautMode    ModuleScript   Tagger vs. Lobby (draft, not in rotation)
    └── Util
        ├── Guard             ModuleScript   validators for untrusted remote args
        └── RateLimiter       ModuleScript   per-player token buckets

StarterPlayer
└── StarterPlayerScripts
    └── Client                           (Folder · src/client)
        ├── CombatController  LocalScript    CLIENT COMBAT CONTROLLER: lock-on, input, remotes, warning UI
        ├── CombatFX          ModuleScript   cosmetic effects (aura, sparks, decoys, invis, damage numbers)
        ├── HitFeedback       ModuleScript   health bars, hit card (who hit you + why), kill-cam
        └── RoundController   LocalScript    phase HUD, Final Duel FOV + music, winner banner
```

Only two kinds of top-level code run: one server `Script` (`Main`) and two client `LocalScript`s. Everything else is a ModuleScript with an explicit `init`, so the start-up order is visible in one file.

## Who owns what

| Concern | Owner | Notes |
|---|---|---|
| *When* things happen (phases, timers, teleports, payouts) | `RoundManager` | mode-agnostic |
| *What the rules are* (who may kick, who may be kicked, what a KO means, win condition) | the active `GameMode` | swappable |
| Kick physics, contact, parry validation, speed | `CombatService` | asks the mode via `CombatRules` |
| Latency budget | `LatencyService` | consumed by `CombatService` |
| Ability behaviour | `AbilityService` | gets a narrow `FlightControl` handle, never the raw flight |
| Economy | `PlayerDataService`, `BettingService` | all mutations server-side |
| Input, lock-on, warning UI | `CombatController` | sends intent only |
| Cosmetics and hit feedback | `CombatFX`, `HitFeedback`, `RoundController` | never affect gameplay |

## How modularity works

```
 RoundManager ──CombatRules{canLaunch, canTarget}──▶ CombatService
      ▲   │                                               │
      │   │  RoundContext                                 │ Signals (deferred):
      │   ▼  {getAlive, isAlive, eliminate}               │  Defeated(victim, attacker?, cause)
      │   GameMode (Surge | Juggernaut)                   │  Damaged(victim, attacker, damage, hp)
      │     canLaunch / canTarget / onDefeated /          │  Parried(defender, attacker, perfect, rally)
      │     onDamaged / getResult / isFinalPhase          │  Launched, Flagged
      └──────────── forwards Defeated / Damaged / Parried ◀┘
```

- **CombatService never decides who wins or who gets eliminated.** When a kick lands it applies speed-scaled damage. It fires `Damaged(victim, attacker, damage, hp)` if the victim survives, or `Defeated(victim, attacker, "Kick")` at 0 HP, and stops there. The mode decides what each means: Surge eliminates at 0 HP; a future Juggernaut could give the tagger extra HP.
- **Who may kick, and whom, are rules, not hard-codes.** Before any launch CombatService asks `rules.canLaunch(player)`, and before any launch or redirect `rules.canTarget(attacker, target)`. Surge lets every survivor kick anyone; Juggernaut lets only the tagger start kicks and lets runners hit only the tagger. The RoundManager also blocks kicking during the spawn countdown.
- **Combat mechanics stay in CombatService.** Cooldowns, one kick in the air per player, several kicks per target, Block-while-flying and head-on clashes are the same in every mode; modes never touch flights.
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
- **Active:** kicking unlocks (`canLaunch` is false during Spawning). `mode:onRoundStart` runs, then the RoundManager ticks `mode:getResult` / `isFinalPhase` / `onTick` every 0.1 s.
- **Hit survived:** damage applied, victim knocked out of the air if mid-kick, tumbles for 0.7 s (server-owned physics), attacker paid `CoinsPerHit`, mode `onDamaged`.
- **KO (0 HP, knocked off, died, left):** CombatService fires `Defeated` → the mode calls `ctx.eliminate(victim, killer, cause)` → combatant unregistered, killer paid, client flings itself (cosmetic), kill-cam on the killer → teleported to the lobby after 1.25 s to spectate and bet.
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
| Kick spam / kicking at anyone | server re-checks mode `canLaunch`, one-kick-in-the-air, stun, kick cooldown, range, mode `canTarget`, camera plausibility |
| Remote spam / malformed args | token-bucket rate limits on every remote; `Guard` validates type, NaN/inf and range |
| Economy tampering | coins, upgrades, crates and bets are server-side; receipts are idempotent |
| Falling out of the map to dodge | below `KillY` counts as a KO |

## Map setup

`dev.project.json` builds a throwaway test map (lobby + arena + tagged pads) for quick playtests. For a real map, tag parts with CollectionService tags (Studio's Tag Editor works):

- `CK_ArenaSpawn`: BaseParts in the arena (one per player is ideal; they are reused if there are fewer)
- `CK_LobbySpawn`: BaseParts in the lobby

Optional: a `SoundService/ClashKickMusic` folder with `Lobby`, `Battle`, `Duel` Sounds (set a `Volume` number attribute to override the default 0.5).
