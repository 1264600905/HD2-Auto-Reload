# Changelog

## function-test-fork (local test branch)

- Add early reload for APW-1 AMR at magazine count 1; R-36 Eruptor requests R at magazine count 0 without a bolt action check.
- Add continuous R requests at low ammo for SG-97 Sweeper (four total rounds) and GL-15 Evictor (two total rounds), with fresh context checks, manual R suppression, and request logging.
- Keep the one-time `GetAsyncKeyState` FFI declaration from v0.5.1.

## 0.5.1

- Declare `GetAsyncKeyState` once during API initialization and reuse its binding in the per-frame input probe.
- Add a `--debug` package with focused context, reload decision and `SendInput` boundary logging.

## 0.5.0

- Migrate to Steam build 25327279; reject mismatched binaries and native layouts.
- Add verified Heat latch reading with effective configuration overrides and a full one-second delay, including held fire.
- Skip normal heating and automatically recoverable cooling locks.
- Revalidate full entity identity, local avatar, slot and ammo path immediately before R.
- Update Rounds record stride (0x84 -> 0x88) and use complete build-specific resource maps for all supported ammo paths.
- Verify Laser Cannon ready/burned-out/manually-replaced states on the live game. User subsequently confirmed functional testing passed, including automatic reload for energy weapons.
- Add read-only inspection tools and synthetic context-chain regression coverage.

## 0.4.0 — test build

- Reduce the idle-empty reload timer from 3 seconds to 1 second.
- Separate the project into its own source tree and repository.
- Remove all disabled broad manager-scan code.
- Make builds portable: standard-library Python, local hexadecimal map data,
  optional `--game-dir` hash verification, no hardcoded developer paths.
- Extend the fixed ammo-query capture to include the Heat branch for the next
  energy-weapon test. Heat auto-reload is still pending verified runtime layout.

## 0.3.0

- Add verified Magazine state reader and conservative chamber preservation.

## 0.2.0

- Hold scan-code R across frames, validate fresh weapon context before requests,
  and support held attack. Distinguish input acceptance from ammo recovery.
