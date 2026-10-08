# Clash Kick

A high-speed, reaction-based Roblox PvP arena game. It plays like Blade Ball, except **there is no ball: the players are the projectiles.** Anyone can lock onto an opponent at any moment and become a feet-first homing missile, so many kicks can be in the air at once. The target must Block right before impact to ricochet back faster. Each parry in a back-and-forth adds 10% to the speed. A kick that isn't parried deals damage that scales with that speed: an opening kick chips 25 of your 100 HP, while a 10-parry rally one-shots.

This repo holds the foundational, strictly typed Luau codebase for the **Surge (Free-For-All Rally)** mode. It is built so that an asymmetric **Juggernaut (Tagger vs. Lobby)** mode is one extra file.

## Where the requested pieces are

| # | Deliverable | Location |
|---|---|---|
| 1 | Architecture setup / Explorer layout | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`default.project.json`](default.project.json) |
| 2 | Client Combat Controller (LocalScript) | [`src/client/CombatController.client.luau`](src/client/CombatController.client.luau) + lock-on math in [`src/shared/Targeting.luau`](src/shared/Targeting.luau) |
| 3 | Server Combat Module (ModuleScript) | [`src/server/Services/CombatService.luau`](src/server/Services/CombatService.luau) + pure math in [`src/shared/CombatMath.luau`](src/shared/CombatMath.luau) |
| 4 | Network Bridge | [`docs/NETWORK_BRIDGE.md`](docs/NETWORK_BRIDGE.md) + [`src/shared/Net.luau`](src/shared/Net.luau) |

Also included: the modular `RoundManager` + `GameMode` contract, `SurgeMode`, a draft `JuggernautMode`, latency measurement, the Leg Style abilities, coin upgrades, crates, betting, and client FX.

## Quick start

Install [Rojo](https://rojo.space) 7.4+ on the computer that runs Roblox Studio (the project uses `.luau` files). `rojo serve` must run on that same machine, because the Studio plugin connects to `localhost:34872`.

### Option A: open a ready-to-play test place

```bash
rojo build dev.project.json -o ClashKick.rbxl
```

Open `ClashKick.rbxl` in Studio, then Test → *Clients and Servers* → 2+ players → Start.

`dev.project.json` is the game plus a minimal test map: a lobby with a SpawnLocation and an open-edged arena 220 studs away with 10 tagged spawn pads. Falling off the arena is a KO.

### Option B: live-sync into your own place

1. `rojo plugin install` (once) installs the matching Studio plugin.
2. In the repo folder: `rojo serve`
3. In Studio, open your place → Plugins → Rojo → **Connect**. Code edits now sync live.
4. Tag BaseParts with CollectionService tags (Studio's Tag Editor works):
   - `CK_ArenaSpawn` on the arena spawn pads
   - `CK_LobbySpawn` on the lobby spawn pads

`rojo serve dev.project.json` also works; it syncs the test map into an empty Baseplate.

Optional: `SoundService/ClashKickMusic` with `Lobby`, `Battle`, `Duel` Sounds. Set `Config.Monetization.CrateKeyProductId` to your Developer Product id.

## Controls

| Action | PC | Gamepad | Mobile |
|---|---|---|---|
| Kick (any time; 1.25 s cooldown after landing) | Left click | R2 | **KICK** button |
| Block / parry | **F** | L1 | **BLOCK** button |
| Ability (Leg Style, mid-flight) | **Q** | Y | **ABILITY** button |
| Redirect | aim your camera so the red dot is on someone else, then Block | | |

## GDD → implementation

| Mechanic | Where | How |
|---|---|---|
| Everyone kicks, everyone blocks | `CombatService`, `SurgeMode.canLaunch` | any survivor may kick at any moment (one kick in the air at a time, `Config.Kick.Cooldown` after it ends); several kicks may chase one player and Block answers the one closest to landing; you can Block mid-flight (the ricochet replaces your kick) |
| Head-on clash | `CombatService.resolveHeadOn` | two players who kick each other meet in the middle and bounce apart, briefly stunned, with no damage |
| Camera dot-product lock-on | `Targeting.findBest` | `cos θ = camera.LookVector · unit(target − camera)` must be ≥ cos 28°; best score = alignment − distance·w + sticky bonus; line-of-sight raycast; red BillboardGui dot on the target |
| Homing feet-first kick | `CombatService.startFlight` / `stepFlight` | server takes network ownership; world-space `LinearVelocity` (∞ force) re-aimed every Heartbeat with a turn-rate-limited slerp; `AlignOrientation` = `lookAt(dir) · Angles(π/2,0,0)` puts the feet forward |
| Red warning indicator | `CombatController.updateWarning` | ring closes on the **server's ETA** on the synced clock, not on the lagged model |
| Parry + stun + ricochet | `onParryRequest` → `resolveParry` | attacker blasted back to the ricochet gap and frozen mid-air 0.5 s (LinearVelocity → 0); defender instantly launched at them |
| Redirect | `resolveRedirect` | the defender's lock-on at press time, if valid and allowed by the mode |
| +10% per parry | `CombatMath.kickSpeed` | `base · min(1.1^rally, 5) · bonus`, capped at 420 studs/s |
| HP that scales with speed | `CombatMath.hitDamage`, `CombatService.resolveHit` | 100 HP per round; damage = `round(25 · (speed/75)^1.5)`: opening kick 25, 5-parry rally 51, 10-parry rally 104. A survived hit tumbles you away (and knocks you out of the air if you were mid-kick); 0 HP or falling off the arena eliminates you (a fall within 5 s of a hit is credited to the attacker) |
| "Who hit me, and why?" | `HitFeedback`, `CombatFX`, `RoundController` | hit card (attacker avatar + name, damage, rally and speed), floating damage numbers, red pulse on your attacker, HUD + overhead health bars, kill-cam on your eliminator, kill feed that says how each player went out |
| Perfect parry | `CombatMath.parryVerdict` | time-to-impact ≤ 0.10 s → red aura + one-shot 1.2× counter-dash |
| Distance manipulation | `closingSpeed` + `ricochetGap` | backpedalling slows the incoming ETA **and** widens the ricochet gap (26 → up to 40 studs: a longer counter-dash that buys time); stepping in shrinks it to as little as 12 studs and spikes the opponent |
| Parry validation | `onParryRequest` | latency-clamped stamp, timing window, distance window, whiff cooldown, integrity heuristics (see the network doc) |
| Upgrades | `UpgradeData`, `PlayerDataService` | WalkSpeed / JumpPower / ParryWindow (+0.05 s max) for Coins |
| Leg Styles | `AbilityData`, `AbilityService`, `CombatFX` | Lag Switch (freeze 0.5 s → blink), Invis-Dash, Shadow Clone (3 lanes, 1 real hitbox); weighted crate roll |
| Round loop + Final Duel | `RoundManager`, `RoundController` | Intermission 15 s → Spawning → Active → FinalDuel (FOV 70→84, music swap) → MatchEnd payout |
| Betting | `BettingService` | eliminated / lobby players bet; odds locked at bet time; closes at the Final Duel |

## Design decisions where the GDD was open

These are deliberate calls. Each one is a single number or line in `Config` / the code if you want it different.

- **The ricochet gap is set instantly.** A parried attacker is blasted straight to the gap (raycast-clamped at walls) instead of gliding there, because the counter-dash launches on the same frame and would overtake a glide, making late parries point-blank, unanswerable kills.
- **No exclusive Surge.** Playtesting showed one-attacker-at-a-time felt restrictive, so anyone can kick at any moment; the only limits are physical (one kick in the air, stunned or tumbling) plus a 1.25 s cooldown. Each fresh kick starts a new rally at base speed. Juggernaut keeps its asymmetry through the mode's `canLaunch` rule.
- **Blocking is free, whiffing isn't.** You can Block at any moment, but a Block that parries nothing costs a 0.45 s lockout. With many kicks in the air, free spam-blocking would make players unhittable.
- **Stunned players can still Block.** Stun freezes movement and launching, not parrying. Otherwise any counter-dash arriving within 0.5 s would be an unanswerable kill and the ping-pong could never happen.
- **The Perfect 1.2× is one-shot.** It boosts that counter-dash only and does not compound into the rally (the +10% does).
- **"Clash hold" before a hit is confirmed.** On contact the server waits `0.05 s + the defender's latency (≤ 0.25 s)` before declaring a hit, so in-flight parries count. That is lag compensation without rewinding anyone. It reads as a brief clash freeze-frame.
- **Lag Switch blinks to *almost* the target,** leaving 0.12 s of flight (`AbilityData.LagSwitch.params.LeadTime`), so a sharp player can still answer it. Set it to 0 for the literal "teleport the remaining distance".
- **Whiff cooldown (0.45 s) and no pre-pressing.** These weren't in the GDD. They make spamming Block, and naive macros, lose.
- **Auto-parry heuristics flag, they don't kick** (`Config.Integrity.KickOnFlag = false`) until the thresholds are tuned on real playtest data.
- **Invisibility and decoys are client-side visuals.** The server hitbox and parry math are unchanged, so no Leg Style can make a kick unparryable or desync.

## Development

The code is `--!strict` throughout and was checked with these tools:

```bash
# Type-check against the Roblox API (luau-lsp + a Rojo sourcemap)
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
  --definitions=@roblox=globalTypes.d.luau src/

# Unit tests for the pure combat math (standalone Luau CLI)
luau tests/CombatMath.spec.luau

# Formatting
stylua --check src tests
```

`globalTypes.d.luau` comes from the [luau-lsp repo](https://github.com/JohnnyMorganz/luau-lsp/tree/main/scripts).

## Not built yet

- Lobby shop / crate / betting **UI** (the server remotes are ready: `GetProfile`, `PurchaseUpgrade`, `SpinCrate`, `EquipLegStyle`, `PlaceBet`)
- Animations, art assets, sound effects; a spectator camera for eliminated players; AFK toggle
- Session-locked persistence. `PlayerDataService` uses plain DataStore Get/Set; swap in ProfileStore before launch (the public API stays the same).
- Playtest tuning of every number in `Config.luau`
- Juggernaut balance (the mode is a working draft, not in `Config.Round.ModeRotation`)
