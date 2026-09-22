# Changelog

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
