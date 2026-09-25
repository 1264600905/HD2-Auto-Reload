# GL-15 native reload prototype

Research date: 2026-09-26. This records the earlier GL-15-only prototype, superseded by [the expanded native build](NATIVE_RELOAD.md). The ABI binding and fail-closed approach follows the independently maintained [C4 native-action architecture](https://github.com/etxp/HD2-C4-Quick-Actions/blob/main/docs/ARCHITECTURE.md); the reload entry and its arguments were identified separately for this build.

- The read-only inspection used the running Steam build `25480438`, `game.dll` SHA256 `2e2c3b7c2500646dadd5f2b4c6e0504dbb7e7896139f64cddc0d1813c718f51e`.
- The native reload request at RVA `0x774b60` is called by original game paths including `0xa7cad3`, `0xa7ecae`, `0xa7f4ae`, `0xa7f78e`, `0x10bb65f`, `0x111e799`, `0x11c1652` and `0x11c1732`. The normal call sites pass the Reload manager pointer, weapon entity ID and false for the third argument.
- The routine resolves the weapon's Reload component, calls the effective config getter `0x4fd220`, checks native eligibility through `0x775580`, then starts the config's ability through `0x7caf40`. It also performs original post-start processing; calling only the ability starter would skip that path.
- The selected local GL-15 had resource `006e44327bb953fe`, matching Reload registry identity, a resource-template Reload config, and ability ID `2769` at config offset `+4`. Its config duration at `+0x38` was zero.
- The prototype accepts only this resource and build. Before each call it rechecks the known native instruction sites, selected weapon identity, Reload registry, ability ID and idle Ability component. It sends one request per empty-ammo episode and does not inject R or directly write process memory.
- No native reload call was performed during the initial read-only research. The user subsequently installed the GL-15 prototype and reported automatic reload at empty; its log recorded native call return followed by ammunition recovery. This supports that limited path, not every weapon or multiplayer behavior.
- Later external read-only samples returned Windows access denied while the game remained running, so the complete Lua preflight was not observed with GL-15 selected. The earlier component, registry and ability readings succeeded; access denial is not a native-call test result.

The GL-15-only build flag is historical. Use the current build instructions in [NATIVE_RELOAD.md](NATIVE_RELOAD.md). All variants share the ordinary mod GUID and must replace one another rather than run together.
