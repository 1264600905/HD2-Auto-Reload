# Changelog

## manual suppression removal (local v4)

- Remove all manual R suppression of automatic reload requests, including the episode latch that blocked M-105 after manual input and further firing to empty.
- Require a separate update between synthetic R release and the next press. Failed sends no longer consume the attack retry or update the accepted-request timestamp.
- Reproduce the observed M-105 sequence in controller tests and verify release-frame separation in the input API test.

## immediate reload and plan 2 (local test branch)

- Fix startup R held-state blocking every automatic request. Ignore the inherited level, release it before a new synthetic press, and distinguish our own held R from a new manual press. A manual hold no longer renews the request cooldown every frame.
- Remove the fixed one-second empty/heat delay and the two-second attack retry limiter. Read ammo each focused update; preserve fresh identity checks and attack-only stationary weapons.
- Apply plan 2: 3 magazine rounds for the listed fast weapons; 10 for M-105 and its handheld MK3. These 22 rules bypass the click wait. Preserve other zero thresholds and the 0.1/0.2/0.4/0.6-second rapid-click policy for other tactical weapons.
- Accept ammo decreasing during the immediate pre-input recheck; still reject refills above the observed count and changed identities.
- Regression coverage includes startup stuck R, our injected R release, manual input, threshold crossings, rapid clicks, and stale contexts. Game confirmation is still required.

## immediate one-round tactical request (local test branch)

- When a configured tactical threshold includes one round and that count is observed, refresh its context and exact ammo count in the same update, then request R without the attack or idle delays.
- Bypass the ordinary two-second repeat limiter for this case while respecting manual R, pending key release and one request per one-round episode. Zero-round behavior is unchanged.

## tactical click delay (local test branch)

- When tactical ammo is above one, wait 0.1 seconds after the latest attack click before R; rapid clicks within 0.5 seconds raise that wait to 0.2, 0.4 and at most 0.6 seconds.
- Keep the previous reload timing at one or zero rounds, and preserve SG-97 and GL-15's total-ammo thresholds.

## configurable tactical reload (local test branch)

- Add a build-time “启用战术换弹” switch and per-resource thresholds for the requested player-held weapons. Exclude sentries, Guard Dogs and JAR-5; include SG-8P.
- Retain SG-97 and GL-15's existing magazine-plus-chamber thresholds and continuous loading behavior.
- Require a new attack press after verified empty state for the specified stationary reload weapons. Enable MG-43's Magazine reader experimentally at the user's request; its earlier crash report remains unresolved.

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
