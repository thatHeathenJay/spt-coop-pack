# Arena: live-like co-op arena on our SPT server

Status: design + build pipeline (2026-11-02). Phase 1 (solo, stock Arena Mode) installed.

## Goal

Run Escape from Tarkov: Arena inside our co-op setup the way live runs it:

- Separate client and launcher (`SPT.LauncherArena`), same account/profile, one backend (our `SPT.Server`).
- Kits, not stash gear. Nothing from a match touches the extraction stash.
- Matches with friends over Fika, hosted on the headless or a player.
- Progression and rewards flow back to the extraction profile (GP coins, Ref reputation, Arena level,
  unlocks, reward boxes).

## Base

[Arena Mode](https://github.com/maschine34675/ArenaMode) 0.4.1 (MIT) + [Arena Map Port](https://github.com/maschine34675/ArenaMapPort) 0.4.0.
Arena Mode already provides: ARENA entry beside PMC/Scav, six modes, twenty kits, profile snapshot/restore,
rewards hook, bot objectives on SAIN/BigBrain, a server mod with config UI. It is single-player by design.

Source clones (not in this repo): `C:\Games\SPT-4.1\Tools\src\{ArenaMode,Redeploy,Fika-Plugin}`.
Build: .NET 10 SDK + PowerShell 7. `Shared.props.user` in ArenaMode and Redeploy point at the install.
`dotnet build <proj> -c Release -p:SPTModType=NoDeploy` (client/gate/session), server with
`-p:SPTUserMods=<staging>\`. All five projects build clean.

## Why Arena Mode refuses Fika (root cause, from Redeploy source)

Respawn is implemented by **Redeploy.Core**: on death it creates a *new* `LocalPlayer`, re-registers it with
the world and swaps the profile. Remote Fika clients never learn about the replacement body, so the packet
flow breaks. Everything else about Fika is secondary. Fika's game class is `CoopGame : BaseLocalGame<EftGamePlayerOwner>`;
Arena's `BaseLocalGame` patches apply to it, its `LocalGame`-targeted patches (Stop, CreateBotByProfile,
vmethod_2, reward StopPatch) do not fire under Fika.

## Architecture

```
SPT.Server (one backend: profiles, rewards, arena server mod, Fika server)
   |-- SPT.Launcher        -> C:\Games\SPT-4.1          (extraction client, ORBIT etc.)
   |-- SPT.LauncherArena   -> C:\Games\SPT-4.1-Arena    (arena client: Fika + ArenaFork + maps + SAIN/BigBrain/Waypoints + ABPS; no ORBIT, no stash/UI mods)
   |-- SPT.Headless        -> extraction raids
   |-- SPT.HeadlessArena   -> arena matches (later; player-hosted first)
```

- Same profiles. The arena client logs in with the same token; the server mod snapshots the profile at match
  start and restores it at match end (Arena Mode already does this in direct-play mode).
- `SPT.LauncherArena` = a copy of SPT.Launcher whose `LauncherSettings.json` `GamePath` points at the arena
  folder. Account management for free.
- The arena folder shares `EscapeFromTarkov_Data` by directory junction (58 GB saved); own `BepInEx`.

## Work plan

### Phase 1 (done): solo arena, stock mods
Arena Mode + Map Port installed on the main client, in the pack (optional for Fika). With Fika loaded the
ARENA button offers START ARENA SESSION (private relaunch). Requires EFT: Arena installed per PC.
Validates maps, kits, rewards on our server before anything is forked.

Server fork change (commit 3f043cc in the ArenaMode clone): `ArenaRewardStartup` refused to enroll rewards
because Map Variants' `VariantSnapshot` callback shares its load priority (1). That callback only snapshots the
database, so the fork allowlists it. Rewards now enroll (`SPT_Runtime\user\arena-rewards\<profile>`). Server-only;
friends need nothing. `Tools\src\LoadOrderScan` lists every server mod's IOnLoad priority if this comes back.

## What stock Arena Mode gives vs live Arena (progression gap)

| Live Arena | Stock Arena Mode 0.4.1 | Plan |
|---|---|---|
| Preset catalog per class, tiers, bought with roubles/GP, unlocked by Arena level | 20 fixed kits in `kits.json`, no price, no unlock | Phase 3: extend kit entries with `tier`, `unlockLevel`, `price`; server filters kits per profile |
| Arena XP + level, ARP rating (ranked PvP) | XP credited to the PMC profile only | Phase 3: `ArenaProgression` block in the profile (xp, level, gpCoins, unlocks); rating skipped (PvE) |
| GP coins, Ref reputation, reward boxes | RUB by mail | Phase 3: GP coins + Ref rep + boxes replace RUB mail |
| Ref quests | none | Phase 3: arena-result conditions |

### Phase 2: ArenaFork, Fika-aware (client)
1. Replace the hard refusals (`ArenaClaim`, `ArenaLocalRaidStartedPatch`, `ArenaSession`,
   `ArenaWhitelistAdmission`, `PitFireTeamSelectionPolicy`, `ArenaLabyrinthAccess`, `Session/HelperDirectStart`)
   with a capability flag: Fika present => "co-op arena" path.
2. **In-place respawn under Fika**: a second Redeploy driver that never replaces the body. On lethal damage
   use Fika's synced downed/revive primitive (`FikaPlayer.ToggleDowned`, `ClientHealthController.Revive`,
   `DownedSyncPacket`) -> revive immediately, teleport to a team spawn, restore health, re-equip the kit.
   Same `Player` object, so Fika's position/health/inventory sync just works.
3. Patch mapping: every `typeof(LocalGame)` target gets a `CoopGame` twin when Fika is loaded
   (`Stop`, `CreateBotByProfile`, `vmethod_2`, reward capture).
4. Match-state sync: custom packets via Fika's `IFikaNetworkManager.RegisterPacket<T>` on
   `FikaNetworkManagerCreatedEvent` — mode, round, timer, scores, team assignment, capture points, kit choice.
   Host is authoritative; clients render.
5. Bots: host-side only (unchanged). ORBIT is not in the arena client, so no conflict.

### Phase 3: server
1. Arena match lifecycle on the real server for Fika raids (Arena Mode's arm/snapshot/restore endpoints already
   exist for direct play; extend to multi-player: one snapshot per participant).
2. Rewards -> live-like: GP coins, Ref reputation, Arena XP/level, unlock tiers, reward boxes (a server-side
   "ArenaProgression" block in the profile + mail). Replaces RUB mail.
3. Ref quests: conditions driven by arena results (kills/wins per mode/map) while PvE conversions from
   Ref SPT Friendly Quests stay for the quests we don't convert.

### Phase 4: client folder + launcher + pack
Arena folder, `SPT.LauncherArena`, friend manifest entries (arena client plugin set), Fika required/optional
lists for the arena client, docs for friends.

## Risks
- Fika's downed/revive is designed for teammate revive; using it as instant self-respawn needs the server
  revive config and client patches to agree (bleedout timers, revive counts).
- Two humans needed to test every sync change. Build in small verified steps; keep solo (Phase 1) as fallback.
- Arena Map Port maps need EFT: Arena installed on every PC that loads them.
