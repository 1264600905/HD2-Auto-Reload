# Provenance and third-party notices

- Context/entity lookup and WeaponRounds layout derive from
  [etxp/HD2-C4-Quick-Actions](https://github.com/etxp/HD2-C4-Quick-Actions), MIT.
  The required notice is retained in `LICENSES/HD2-C4-Quick-Actions-MIT.txt`.
  C4 action invocation and memory-writing code are not included.
- `data/*.map.hex` are byte-for-byte hexadecimal encodings of the Magazine and
  Reload resource-map fingerprints extracted from the local release of
  [starmatch666-droid/Directional-Shield-Hammer](https://github.com/starmatch666-droid/Directional-Shield-Hammer).
  They are reference data for exact identity checks, not its modification logic.
  No additional license for these reference data is asserted here.
- The addon declaration, archive format and manifest are compatible with Bingus
  Shared Loader. The package encoder was separated from the existing shared-loader
  workspace. The loader itself, its game assets and other mods are not bundled.
- LuaJIT is a separately supplied test/runtime dependency (MIT), not vendored.

No repository-wide license grant is implied by publication. Third-party MIT
notices continue to apply to the corresponding adapted material.
