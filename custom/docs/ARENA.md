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

## Target (user decision 2026-11-02): "EFT: Arena with bots instead of humans, or co-op"

The whole loop is live Arena's loop. Where Arena does something, we do it or emulate it. Ranked/ARP is out.
Facts below are live as of patch 0.6.x (Oct 2026); numbers are the calibration knobs, kept in JSON on the server.

### Modes (official only; mutators, gun game, deathmatch, zombies, own-gear and PitFireTeam labels removed)
| Live mode | Rules | Stock base to adapt |
|---|---|---|
| TeamFight | 5v5, 7 rounds, no respawn in round, capture point decides after timer | Tactical (TeamArenaRoundPolicy) |
| BlastGang | 5v5, attack plants device (40 s), defence defuses, side swap | new mode on Tactical |
| CheckPoint | 5v5, side swap, capture and hold objectives | Domination + Tactical rounds |
| ShootOut | 1v1 / 2v2 / 3v3 rounds | Tactical with small rosters |
| Duel | 1v1 rounds | ShootOut 1v1 |
| Last Hero | free-for-all rounds, last one alive wins | Rounds |
| Overrun | 5-player PvE vs bot waves | Zombie/Endless population, PMC/scav waves |

### Presets, metascore, matchmaking (live 0.2.0.0+ model)
- Four classes: Assault, Enforcer, Scout, Marksman. 12 preset slots (3 per class), fully custom builds; 3 starter
  presets per class; equipment is class-specific or universal.
- Every item has a metascore. A preset shows Firepower (weapon, ammo, mods), Defense (armour, helmets),
  Utility (meds, rigs, headsets) and Total bars, with per-class lower/upper limits (live: total 9,000-11,000,
  later 7,500-10,000). Preset is invalid outside the limits.
- Armory: buy with roubles + GP coins (both taken from the extraction stash, live-like sync); unlock by PMC level,
  daily/weekly (operational) tasks, or weapon level. Ammo and most plates always available. Weapon levels: kill XP
  (250 TeamFight/BlastGang, 100 Last Hero), each level unlocks attachments permanently; caps per weapon.
- Matchmaking emulation: "Searching for match" with a short fake queue, then bots built from the same preset
  catalogue, same class mix, metascore within the same bracket as the player's preset (bracket width = live band).
  No ARP.
- Item metascore table (schema 2, 2026-11-03): live MP values for 261 items (every Armory weapon, body armour,
  eyewear, med, stim, pill, melee; ammo per round with class access) from the Japanese wiki Armory/ammo tables at
  patch 0.6.0, packaged by Codex in `tools/live-data/codex-2026-11-03` and joined to SPT template ids by
  `tools/map-templates.py` (375 of 389 records, incl. Content Backport 1.0 items). Helmets, plates, rigs, headsets,
  grenades, magazines and mods use the package's category seeds applied to SPT item stats. Accounting: a weapon's
  live MP covers its default preset mods; ammo is per round; inserts and plates inside a valued armour are not
  added. `tools/generate-metascore.py` writes `defaults/metascore.json` and the live server copy.

### Rewards and progression (every number in `progression.json`)
- Match end: PMC XP (kills, assists, device actions, result; losers get 20% of winners' max cash), roubles,
  Battle Pass XP (per result and per mode, Last Hero +50%), weapon XP. PMC XP/level/skills go straight into the
  extraction profile (stock already does XP); roubles, GP coins, Lega medals and crates arrive as Ref mail.
- Operational tasks: daily (1,500 BP XP) and weekly (5,000 BP XP), reward GP coins and, for hard ones, Ref
  reputation. Ref reputation writes to the real Ref trader standing, so his assort and quests react.
- Battle Pass: 2,000 BP XP per level, 2 Battle Points per level; rewards bought with Battle Points, next page
  opens after 3 claims on the current one; all rewards free; BP exchangeable for roubles/GP; overflow levels
  compensated. Rewards: clothing, camos, masks, armour, GP coins, Lega medals, Ref drop crates (Arena only).
- Ref quests: conditions on arena results (kills/wins per mode/map); the PvE conversions stay for the rest.
- Shop (user decision 2026-11-02): emulated with the live screen, but every real-money price becomes a GP coin
  price (catalogue + prices in `shop.json`; clothing, camos, masks, armbands, crates, Battle Pass levels at
  10 levels + 30 BP per bundle). GP coins are the one currency the player earns by playing, so the shop is a
  sink for them, never a wallet.
- Not emulated: ranked/ARP, Tactical Map/Tactical Tokens (maybe later).

### UI (user decision: from the main menu on, indistinguishable from live Arena)
Hard fact (2026-11-02): live EFT: Arena is Unity 6000.3.6f1 + IL2CPP; the EFT/SPT client is Unity 2022.3.43f1
Mono. A 2022 player cannot load Unity 6 assets, so Arena's menu prefabs cannot be loaded at runtime. Map Port
does not do that either: it ships its own ported map bundles and only checks the Arena install (keys/ + install
path) as the licence gate.

Method that reaches "identical":
1. **Extract, don't load.** AssetRipper (supports 6000.x) rips the Arena install offline: UI sprites, atlases,
   fonts, colours, and every menu prefab/scene as YAML with exact RectTransform anchors, sizes, paddings,
   layout groups, sprite refs and TMP text settings.
2. **Layout transpiler.** `tools/arena-ui-export.py` turns those YAML hierarchies into our own JSON layout
   files (one per screen) keyed by object name. The arena client plugin rebuilds each screen at runtime from the
   JSON + ripped sprites: same tree, same numbers, same art, same fonts. No hand-measuring, so no drift.
3. **Behaviour is ours**, attached by object name: button handlers, bar fills, list binding, animations
   re-created from the ripped Animator/DOTween params where present.
4. **Friends' PCs:** INSTALL-ARENA runs the same rip + transpile against their own Arena install into their
   arena client folder. The repo ships the transpiler and the behaviour plugin only, never BSG art. No Arena
   install = no arena client (same gate as Map Port).
5. **Whole shell replaced** in the arena client: EFT's main menu, bottom bar, settings, inventory and
   post-raid screens are swapped for Arena's (menu, Play, Presets, Armory, Battle Pass, Tasks, Profile,
   match HUD, round/match results). Extraction client is untouched.
Known gaps that stay visible: the loading screen before the Arena menu (SPT launcher + EFT splash), and
Arena features we do not emulate (ranked, shop, Tactical Map).
First task once the install finishes: rip, inventory the screens, confirm sprite/font coverage.

## Work plan
1. Phase 1 (passed 2026-11-02): solo match through the non-Fika arena client against the Fika server, ported map,
   kits, bots, respawn all fine, zero client errors. Needed: SPT_Data junction + working directory for the arena
   launcher, and a user whitelist file (`overrides-arena/BepInEx/config/com.maschine.ArenaMode.whitelist.json`,
   unlisted allowed, ORBIT allowed) because the policy also checks the server's mod list.
2. Phase 2: ArenaFork, Fika-aware client (unchanged below).
3. Phase 3: server progression: metascore table (generator done 2026-11-02), preset slots, armory, weapon levels, tasks, battle pass, mail
   rewards, Ref standing, bot matchmaking by metascore. Mode trim to the official list.
4. Phase 4: UI screens in the order Presets/Armory, Play+queue, post-match, Battle Pass, Tasks.
5. Phase 5: `SPT.HeadlessArena`, friend docs, pack entries.

### Phase 2: ArenaFork, Fika-aware (client) — design 2026-11-03, from Fika 2.4.6 and Redeploy source
Facts that shape it:
- Redeploy.Core refuses under Fika at engine level (`DeathInterception.IsAvailable` -> false when Fika loaded), and
  its whole pipeline is body replacement. Not usable in co-op; keep it for solo.
- Fika's revive system already does what arena needs: lethal damage -> `ClientHealthController.SendNetworkSyncPacket`
  -> `TryProcessDownedState` -> `FikaPlayer.ToggleDowned(true)` (prone, `DownedSyncPacket` to everyone). Revive =
  `ToggleDowned(false)` (restores IsAlive, damage coeff, `Revive()`), `RevivedPlayerPacket` on the wire. Teleport is
  EFT's `Player.Teleport`, synced by Fika's movement packets. Health restore syncs through `HealthSyncPacket`.
  Observers can rebuild a player's whole inventory from an `ItemDescriptor` (`ObservedPlayer.SetInventory`).
- Downed is gated: `CanBeDowned` requires another living human (`CanBeRevivedByOtherPlayer`), revive count under
  `MaxRevives`, and no headshot/grenade instant kill. All three are patched open inside an arena match.
- Fika mod API: `FikaEventDispatcher` events (`FikaNetworkManagerCreatedEvent`, `FikaGameCreatedEvent`,
  `FikaRaidStartedEvent`, `FikaGameEndedEvent`), `IFikaNetworkManager.RegisterPacket<T>` + `SendData/SendGenericPacket`,
  `FikaBackendUtils.IsServer` for host authority. `CoopGame : BaseLocalGame<EftGamePlayerOwner>` overrides vmethod_1..7,
  Stop, Dispose; bots are spawned by the host only.

Build as a separate plugin **ArenaMode.Fika** (hard BepInDependency on com.fika.core, references Fika.Core.dll) so
ArenaMode.Client keeps no Fika reference. ArenaMode.Client exposes a small bridge (`ArenaCoop` static: IsAvailable,
RespawnProvider, MatchStateSink) that the Fika plugin fills in. Steps:
1. Refusals -> capability. The seven Fika refusal sites (`ArenaClaim`, `ArenaLocalRaidStartedPatch`, `ArenaSession`
   ~405, `ArenaWhitelistAdmission.HasFika`, `PitFireTeamSelectionPolicy`, `ArenaLabyrinthAccess`,
   `HelperDirectStart`) become `FikaCompatCheck.IsFikaLoaded && !ArenaCoop.IsAvailable`.
2. In-place respawn (ArenaMode.Fika/Respawn): Harmony on `ClientHealthController.get_CanBeDowned` -> true and
   `CheckIfDamageShouldInstantKill` -> false while an arena match with respawns runs; postfix on
   `FikaPlayer.ToggleDowned(true)` for the local player raises `ArenaEvents.PlayerDied` (scores the kill from
   `LatestDamageInfo`) and starts the respawn coroutine: wait `IArenaMode.HoldRespawn` / live respawn rule (manual
   Space or auto), pick spawn via `ArenaSpawnSelector`, `ToggleDowned(false)`, `Teleport`, `RestoreFullHealth`,
   restore the kit in place (ammo, durability, meds) for the same preset; on a preset change between rounds rebuild
   equipment and send `ArenaInventorySyncPacket(netId, ItemDescriptor)` so observers call `SetInventory`.
   `IArenaMode.OnLocalRespawn(player)` receives the same body.
3. LocalGame -> CoopGame patch twins: `Stop` (ArenaTeamBoxRuntime, ArenaRewardCapture), `vmethod_2`
   (FastDeployPatches), `CreateBotByProfile` sites (PitFireTeamRoundLifecycle) get a second target resolved to
   `CoopGame` when Fika is loaded; `BaseLocalGame<EftGamePlayerOwner>` targets already apply.
4. Match authority: the Fika host runs the mode (`ArenaMatchService` as today); clients run a mirror that only renders
   HUD and honours HoldRespawn. Packets registered on `FikaNetworkManagerCreatedEvent`: `ArenaMatchStatePacket`
   (mode, round, phase, timer, scores, team of each netId, capture state), `ArenaRoundEventPacket` (round start/end,
   plant/defuse, MVP), `ArenaKitChoicePacket` (client -> host), `ArenaInventorySyncPacket`. Bots: host only, as now.
5. Team assignment: host assigns humans and bots to sides at arm time and sends it in the first state packet; the
   `ArenaTeamBoxRuntime` and armband colours follow the packet on clients.
6. Solo with Fika loaded (one human): the same path works because the downed gate is patched open; no Redeploy.

Status 2026-11-03: steps 1 and 2 scaffolded and compiling in the fork (commit dae157f): `ArenaMode.Client/Compat/ArenaCoop`
bridge, seven refusal sites rerouted, new `ArenaMode.Fika` plugin (hard deps com.fika.core + ArenaMode; patches
ReviveEnabled/CanBeDowned/instant-kill, freezes Bleedout, hides its UI, observers get no revive prompt; respawn routine
= un-down, teleport to a player spawn point 25 m+ from the corpse, full health, in-place refill of magazines,
durability and meds). Deployed to the arena client on 2026-11-02 together with Fika (fork Client dll + ArenaMode.Fika; stock dll kept
as `.stock-0.4.1`). Server runs one of two Fika mod lists: `SPT.Server.bat` (extraction list) or
`SPT.ServerArena.bat` (arena client list, restored on exit); both generated by `tools/make-fika-configs.py`
from the arena client's plugin set (`TypeDump --plugins`). Same port, same profiles, never both at once.
First solo-with-Fika match played out 2026-11-02 (Team DM on Air Pit, Fika host, kit issued into the profile, squads
admitted, reward captured). Fixes on the way there: Fika lobby must be shown (no pre-raid skip), the server mutates
Fika's cached match location in place, LocalGame alias to the base game class + ArenaGameType for concrete Harmony
targets, Redeploy accessors widened, bot game = IBotGame singleton, co-op entry kit via the protected-team entry
machinery. Respawn fired but in place; now picks a spawn through the raid's spawn system (team boxes apply).
DynamicMaps removed from the arena client on 2026-11-02 (user decision: no map overlay in arena); arena Fika list regenerated (14 required).
User priorities for the next build: Arena in-match UI from the rip (menus later), kits rebuilt on Arena's presets.

## Risks
- Fika's downed/revive is designed for teammate revive; using it as instant self-respawn needs the server
  revive config and client patches to agree (bleedout timers, revive counts).
- Two humans needed to test every sync change. Build in small verified steps; keep solo (Phase 1) as fallback.
- Arena Map Port maps need EFT: Arena installed on every PC that loads them.
