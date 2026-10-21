# Day Offload — development notes

Mac app: offload only chosen shoot days from a camera card (never the whole card, never writing to it), verified to several drives; and compare shoot copies with a whole-card Stow backup made at the office. Owner: Chris (kurikurikun / move-ment). Built with Claude Code, Oct 2026.

## Build & run

- `./build.sh` — dev build for this Mac, ad-hoc signed, installed to /Applications.
- `./make-app.sh` — universal release: runs `Tests/run.sh`, builds arm64 + x86_64, signs with Developer ID, notarizes (keychain profile `peripheralspeed-notary`, override `NOTARY_PROFILE`), staples, gates on `spctl`, writes `build/DayOffload-<v>.zip` and `build/DayOffload.zip`. Stages in /tmp (iCloud re-stamps xattrs). Dev zip: `ALLOW_ADHOC=1`.
- `./Tests/run.sh` — XXH3-128 vs reference vectors (`Tests/xxh3_vectors.txt`, from python-xxhash 4.0.1 on a fixed LCG byte stream).
- `./Icon/make.sh` — regenerates `Icon/AppIcon.icns` + `docs/icon.png`.
- Hidden flags: `--engine <scan|copy|compare> …` (the engine, see below), `--mount-check` (launchd helper), `--demo [sheet|compare]` (made-up data for screenshots — run a copy with another bundle id so real settings are untouched).

## Release ritual (same as Peripheral Speed)

1. Bump `AppInfo.version` in `Sources/DayOffload.swift`.
2. Commit, push, `./make-app.sh` on the Mac with the Developer ID cert (Chris's M1 Mac mini), `git tag vX.Y && git push origin vX.Y`.
3. GitHub Release for the tag with BOTH zips attached: `DayOffload-X.Y.zip` and `DayOffload.zip` — move-ment.co/day-offload downloads `releases/latest/download/DayOffload.zip`.

## Architecture (Sources/)

- `DayOffload.swift` — SwiftUI app (Model + views). Runs the engine as a child process of the same binary (`--engine …`) and reads JSON-line events (`scan`, `plan`, `progress`, `done`, `compare_plan`, `compare_done`, `error`), so the UI never blocks and Cancel = terminate.
- `Engine.swift` — scan / copy / compare. Ported 1:1 from the original Python engine (kept out of the repo); outputs and the manifest/cache file formats are identical, and both engines were diffed against each other.
- `XXH3.swift` — streaming XXH3-128 (the hash Stow / ASC-MHL v2 use). ~8 GB/s.
- Card detection (`looksLikeCard`) runs off the main thread with a 3 s budget: a pending macOS removable-volume permission prompt blocks `open()` and used to freeze the window.
- launchd agent `co.move-ment.dayoffload.cardwatch` (StartOnMount) runs `--mount-check`, which opens the app only if a camera card is mounted and the app isn't running.

## Rules that matter (do not regress)

- The card is read-only. Never write, rename or delete on a source.
- A clip's day = earliest created/modified time over all files sharing its name stem; day starts at a configurable hour (default 04:00).
- Copy writes `.partial`, F_FULLFSYNC, keeps mtime, then renames; verify re-reads every destination with F_NOCACHE and compares xxh3 with the card read.
- Manifest `_offload_manifest.csv` columns: path,size,mtime,md5,xxh3_128,verified_at,source. Old manifests without xxh3 are upgraded in place.
- Compare matches shoot files to the office by (file name, size); Stow's `_verification/checksums.csv` gives the office hash; folders without Stow records are read. Shoot-only `Proxy/` folders are informational, not errors. Real gaps list every file by name.
- Backup drives are never treated as cards: any destination's volume is remembered (`notCardVolumes`), drives with `_offload_manifest.csv` / `_verification` near the top are skipped, and media must sit at the card's top levels.
- Each ad-hoc rebuild is a "new app" to macOS privacy (TCC): it asks again for removable-volume access. Notarized releases keep the grant across updates.
