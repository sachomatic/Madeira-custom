## Epic Cloud saves

Adds cloud-save sync for installed Epic games, on top of this PR (Milestones 1 and 2). It is the
cloud-saves item the docs list as outside the milestone, modelled on Madeira's Steam Cloud sync
(`docs/STEAM_CLOUD.md`) and ported from Legendary (`core.py` upload_save / download_saves,
`utils/savegame_helper.py`, the chunk and manifest writers, `utils/rolling_hash.py`).

### What it does

- Reads the game's `CloudSaveFolder`, `CloudIncludeList` and `CloudExcludeList` from its catalog entry
  and maps `{AppData}`, `{UserDir}`, `{UserProfile}`, `{UserSavedGames}`, `{InstallDir}` and `{EpicID}` to
  the Wine prefix. Anything else, or a path leaving `drive_c`, is refused.
- Compares the device's save files (SHA-1) with the newest cloud snapshot, using a record of the last
  state both sides had (`epic-cloud-sync.json`):
  cloud changed only → download; device changed only → upload a **new** snapshot; both changed, or they
  differ with no record → **conflict**, nothing is replaced until the user picks a side.
- Downloads are verified (every chunk and every file's SHA-1) in memory before anything is written, so
  a bad or missing chunk changes nothing. Files a download replaces are copied to
  `Documents/Epic Cloud Backups/<game> (<app>)/<time>/` first.
- Nothing is ever deleted or overwritten in the cloud: an upload is a new snapshot and older ones stay.
- When: for each installed game when Madeira starts and when its page opens, and on **Sync now**.
  Settings › Epic Games has *Sync saves with Epic Cloud* (on) and *Upload newer saves automatically*
  (**off by default**, because an upload becomes the newest snapshot that Epic's launcher on a PC may
  then offer).
- UI: an **Epic Cloud saves** section under the game's Epic Games section on Game details: status,
  Sync now, and Keep Epic's saves / Keep this device's saves for a conflict.

### Files

New: `Epic/EpicCloudSaves.swift` (formats, decision, transport; Foundation only), `Epic/EpicCloud.swift`
(coordinator, section, switches), `tests/host/check-epic-cloud.py`, `tests/host/epic-cloud/main.swift`.
Small edits: `EpicAuth` (`accountID`), `EpicInstaller` (start-up check), `EpicSignInView` (two toggles),
`Library.swift` (one line adding the section), the Xcode project (two sources), `docs/EPIC.md`.

### How it was checked

`python3 tests/host/check-epic-cloud.py` (macOS or Linux, needs `swiftc` and a copy of Legendary in
`$LEGENDARY_SRC`) builds the production Swift and checks:

- the decision table, filters and save-folder variables;
- a save written by this Swift code and read back by **Legendary's own `Manifest` and `Chunk` classes**:
  all files byte for byte, every chunk's rolling hash, SHA-1, GUID and sizes, and the manifest accepted
  and re-serialised by Legendary;
- a snapshot written by **Legendary's `SaveGameHelper`** restored by this code, including the backup of
  a replaced file and the snapshot's date;
- a damaged chunk aborting a download without writing anything.

The iOS app builds with it.

### Not checked

It has **not** been run against a live Epic account or CDN: the datastorage requests (listing, upload
targets, pre-signed PUT/GET) follow Legendary's `egs.py` but are untested here. The first real sync on a
device is the open test. Because of that, uploads are manual by default.

### Limits

Encrypted chunks are not supported; Mac-only variables and the legacy `locallow`/`roaming` forms of
`CloudSaveFolder` are refused; saves over 2000 files or 128 MB are not synced; no sync while a game runs.
