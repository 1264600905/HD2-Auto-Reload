# Provenance and third-party notices

- Context/entity lookup and WeaponRounds layout derive from
  [etxp/HD2-C4-Quick-Actions](https://github.com/etxp/HD2-C4-Quick-Actions), MIT.
  The required notice is retained in `LICENSES/HD2-C4-Quick-Actions-MIT.txt`.
  C4 action invocation and memory-writing code are not included.
- The historical `data/WeaponMagazineComponent.map.hex` and
  `data/WeaponReloadComponent.map.hex` are hexadecimal encodings of the Magazine and
  Reload resource-map fingerprints extracted from the local release of
  [starmatch666-droid/Directional-Shield-Hammer](https://github.com/starmatch666-droid/Directional-Shield-Hammer).
  They are reference data for exact identity checks, not its modification logic.
  No additional license for these reference data is asserted here.
- `data/*.25327279.map.hex` are resource-ID/index tables read locally from build
  25327279 after independently identifying the native getters. They contain no
  game executable code or asset payloads and serve only exact identity checks.
- The addon declaration, archive format and manifest are compatible with Bingus
  Shared Loader. The package encoder was separated from the existing shared-loader
  workspace. The loader itself and its game assets are not bundled.
- The unified package includes Mod Options Menu v1.3 and its byte-identical
  Bingus Shared Runtime files, by CowboyBingus, under Zero-Clause BSD. The notice
  is distributed as `ModOptionsMenu-LICENSE.txt`; the conditional-menu changes
  are retained in `integrations/ModOptionsMenu-v1.3-conditional.patch`.
- LuaJIT is a separately supplied test/runtime dependency (MIT), not vendored.

No repository-wide license grant is implied by publication. Third-party MIT
notices continue to apply to the corresponding adapted material.
