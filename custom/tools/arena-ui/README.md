# Arena UI pack builder

`Build-ArenaUi.ps1` builds the live Arena UI pack on the player's own PC from their own EFT: Arena install.
The installer calls it when the arena client has no `arena-ui` folder. It downloads AssetRipper 2.0.0 and a
portable Python with PyYAML into a scratch folder, rips Arena's menu prefabs, sprites, fonts and sound banks,
transpiles the prefabs to layout JSON (`arena-ui-export.py`), packs only what the layouts use
(`pack-arena-ui.py`) into `BepInEx\plugins\maschine-ArenaMode\arena-ui`, then deletes the scratch folder.

`Unity.TextMeshPro.dll` is our layout shim (built from the ArenaMode fork's `tools/TmpShim`); it is what lets
AssetRipper deserialize TextMeshPro components from the Arena files. No BSG files are in this folder.

Needs about 14 GB free while it runs and 10 to 30 minutes. Re-run by deleting the `arena-ui` folder and running
INSTALL-ARENA.bat again.
