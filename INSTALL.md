# SPT Co-op Pack: Setup Guide

For SPT 4.1.6 with Fika 2.4.6. Do these steps after you have installed SPT.

## Before you start

- You need retail Escape from Tarkov installed through the BSG launcher and fully updated.
- Install SPT 4.1.6 into an empty folder using the official SPT installer. It copies your game and downgrades the copy. Your retail install is not touched.
- The installer may ask for .NET 10 Desktop Runtime and ASP.NET Core 10 Runtime. Install them from Microsoft if it does.

## Step 1: Run SPT once, clean

1. Open your SPT folder and start **SPT.Server**. Wait for "happy playing".
2. Start **SPT.Launcher**. Create any profile. Click Start Game.
3. Wait for the main menu to appear, then close the game, the launcher, and the server window.

This confirms the base install works. Do not skip it.

## Step 2: Install the mod pack

1. Copy the whole **FriendPack** folder into your SPT folder. It must sit next to EscapeFromTarkov.exe.
2. Double-click **INSTALL.bat**. A window opens and shows progress.
3. Let it run. It downloads about 13 GB and installs 55 mods. Expect 20 to 60 minutes.
4. When it says Done, press Enter.

If Windows SmartScreen pops up, click More info, then Run anyway.

If a download fails, run the script again. It only fetches what is missing.

## Step 3: Point the launcher at the host

1. Open **SPT.Launcher**.
2. Click **Add New Server**. Name it anything. Address is the host's IP, nothing else. No port, no https.
3. Select that server and click **Create profile**. Pick your edition and name. This profile lives on the host's server.

Do **not** start SPT.Server on your own PC. The host runs the only server. If the host's server is off, the launcher will not connect.

## Step 4: First launch

1. Click Start Game. The first launch is slow while mods load. Two or three minutes is normal. If the launcher says it is fetching bundles from the server, that is normal too, but it should be a few small files, not gigabytes. If it sits downloading for a long time, the pack was installed before the bundle fix; rerun INSTALL.bat.
2. On the main menu you should see **Fika** in the bottom left corner. If it is not there, Fika did not install. Tell the host.
3. Press **F12** to open the mod settings. Under **DynamicMaps Extended**, set artwork style to **Satellite**. Close with F12.
4. In the game's own Settings, Graphics tab, set the **menu theme to Factory**. The Menu Overhaul mod expects that theme as its base.

Bot difficulty, raid length, found-in-raid rules, and spawns are all set on the host's server. You do not configure them.

## Playing together

- Anyone can pick a map and click **Host Raid** in the lobby screen. Others see it and click **Join**. The raid host presses Start Raid once everyone is in.
- The raid host's PC runs all the bots. Let the person with the strongest PC host.
- You can play solo any time the host's server is up. Host a raid with nobody else in it.
- Press **M** in raid for the map. It shows exfils, your position, and quest markers.
- Press **F6** in raid for the SAIN bot settings if you want to look. Leave the preset alone, it comes from the server.

## Rules for keeping everyone compatible

- Do not add, remove, or update mods on your own. Everyone must match the host. If you want something added, ask the host and they will add it to the pack for everyone.
- If you get **"Your client doesn't meet server requirements"**, your mod list differs from the host's. Run the installer again.
- If the game crashes on launch, send the host the file **BepInEx\LogOutput.log** from your SPT folder.

## Playing day to day

Use **PLAY.bat** instead of SPT.Launcher. It checks the host for pack changes, installs or removes whatever changed, then opens the launcher. Takes a few seconds when nothing changed. If the host's pack server is unreachable it just launches with what you have.

## Updating later

You normally never need a new zip. If the host does send one, replace your FriendPack folder and run PLAY.bat.
