# Magazine reader evidence — build 24826606

Source: user's v2 AutoReloadRounds.log, `AMMO_QUERY_CODE` at RVA 0x73cf80.
The instruction stream was disassembled offline with Capstone. No native calls.

| Code RVA | Observation |
| --- | --- |
| 0x73d05a | bit 0x80 selects Magazine |
| 0x73d062 | RIP-relative manager pointer resolves to game + 0x276c378 |
| 0x73d06d–0x73d0c8 | entity map at manager + 0x20 |
| 0x73d0cc | entity registry at manager + 0x38 |
| 0x73d0d0–0x73d0d7 | state at manager + 0x48, stride 16 |
| 0x73d0df | effective configuration getter 0x4eecc0; never called by mod |
| 0x73d0e4 | effective config + 0x9c selects chamber-aware branch |
| 0x73d0ed–0x73d0f5 | runtime at manager + 0x50, stride 12, byte + 8 blocks chamber |
| 0x73d0fc | state + 8 is the chamber token checked for nonzero |
| 0x73d10d | non-chambered branch checks signed state + 0 > 0 |

The reader checks the exact manager-load bytes and the 76-byte state/query block
against this capture, validates full static Magazine and Reload maps plus resource
records, and matches the runtime registry's full 24-byte entity identity.
The normal snapshot's final re-read validates mutable pointers/state/entity guards.

Effective configuration overrides have not been decoded. Consequently, v3 does
not use the static chamber flag to authorize reload: **both count and chamber token
must equal zero**, independent of template flags. A blocked chamber with a nonzero
token is preserved. This can conservatively miss a non-chambered weapon with an
unused nonzero token; it does not guess that token away.

v2 user's log confirms main weapon `dcd1c835407ef7ba` used WeaponRounds and recovered
ammo following two requests. Resources `02eecd0b1fa49630`, `cf8934ff6567a42d`, and
`3828e2051aa9e897` were all skipped as Magazine. v3 covers this ammo branch for all
selected slots; it still needs game testing for Magazine counter transitions.
