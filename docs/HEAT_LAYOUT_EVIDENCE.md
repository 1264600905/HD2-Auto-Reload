# Heat reader and build migration — 25327279

Verified by read-only disassembly and live observations on 2026-09-22.
No game function calls, memory writes, or whole-module dumps are used.

The user's Steam installation changed from 24826606 to **25327279** during the
handoff. v4 stopped with `unsupported_game_build`; changing only that guard
would have retained wrong globals, entity offsets and Rounds configuration stride.

- game.dll SHA256: `73374bd4e38386beb9a23bef480082b67d457ebc77485fbec5f488b4e95e201f`
- EXE SHA256: `d8e23968d1412b07e06785321727d63edf74e711214d6f6adeb3bfca95ca6827`
- game.dll PE timestamp: `0x6aa96b14`; SizeOfImage: `0x4770000`.

| Native code | Verified meaning |
| --- | --- |
| `0x744c20` | Ammo query; flags 0x80 Magazine, 0x100 Rounds, 0x400 Resource, 0x200 Heat |
| `0x744ea2` | Heat dispatch calls `0x764ee0` |
| `0x764ee4` | Independent action-inhibition check `0x7777a0`; must not mean empty |
| `0x764efa` | Heat global `game + 0x3326d48` |
| `0x764f0a..0x764f98` | Heat map +0x28, runtime array +0x58, stride 12, byte +8 is lock |
| `0x762f74..0x762fae` | Registry +0x40 holds full entity pointers; effective config getter `0x50e1f0` |
| `0x76307f..0x763094` | Config byte +0x50 permits lock; reaching config float +0x60 sets runtime byte +8 |
| `0x7630ac..0x7630c8` | Cooling can clear lock at config float +0x64 only if config byte +0x90 is zero |
| `0x50e212..0x50e2ac` | Entity config override map +0x68, array +0xa8, stride 0x250; otherwise resource getter |
| `0x50dd30` | Heat resource table: owner +0xf12cc8, 58 map entries, 0x250-byte records |
| `0x76503d..0x7650a1` | Runtime +0 holds spare sink count, used by replenishment path |

The Heat reader requires the native layout signatures, the **complete** resource
map, matching resource record, owned 24-byte entity identity and stable guarded
pointers/state. It uses the effective entity override when present. Only a true
lock with config +0x50 and +0x90 both set may request R. Heat amount by itself is
never an authorization. Unsupported configuration flags, failed reads, unknown
resources and mismatched identities produce no input.

The delay is one full second for Heat, including attack edges and held attack.
Before input, the entire current context is re-read and compared for entity,
resource, avatar, slot and ammo path. One automatic request is sent per lock
episode; explicit later attack can retry under the existing two-second cooldown.

## Context and other ammo paths

| Item | New address/layout | Evidence |
| --- | --- | --- |
| Player global | 0x3326468 | 0x607200; local registry +0xe8, count +0x84 |
| Player-to-avatar | player map +0xd0, avatar unit +0x3a8 for local index 0 | 0x606630 |
| Entity owner | 0x346bf98 | 0xfd9c93 |
| Unit/entity maps | +0xf22ec8 / +0xf1aeb0 | 0xfd9c80 / 0xfd9d40 |
| Entity array | +0xf32f18, stride 24 | 0xfd9d1c / 0xfd9ddb |
| Inventory global | 0x3326738 | 0x9a83e0 |
| Inventory state | +0x50, stride 48, selector +0x1c | 0x9a846f |
| Weapon driver global | 0x3326660 | 0x745db6 |
| Magazine global | 0x3326648 | 0x744d02 |
| Magazine runtime | unchanged +0x48/stride16 and +0x50/stride12 | 0x744d6c..0x744db7 |
| Magazine resource table | owner +0xf124a0, 540 entries, stride160 | 0x4f32f0 |
| Rounds global | 0x3326cf0 | 0x744dc2 |
| Rounds resource table | owner +0xf12820, 50 entries, **stride0x88** | 0x4fd8e0 / 0x4fddc2 |

The migrated context uses the directly verified local-player-to-avatar chain and
checks the avatar's unit ID, ownership, inventory registry and current weapon.
The old mode-manager/secondary-avatar-manager/weapon-data diagnostic reads were
removed rather than assigning unverified new offsets to those redundant paths.
Thus menu/death transitions are rejected through absent, mismatched or unowned
local avatar/inventory/weapon state. These transitions still need v5 gameplay
testing. Resource-ammo weapons remain unsupported and are no longer probed.

Magazine uses its full native resource table and entity identity; the old
reference Reload map is no longer required to interpret the magazine counters.
Both magazine count and chamber token must be zero. Historical map files remain
in `data/` for provenance; the v5 builder uses only `.25327279.map.hex` files.

## Live observations

User identified the equipped support weapon as **Laser Cannon / 激光大炮**.
Resource `d54b9505c0f72873`, slot 3, same entity across all three observations:

| User action | Lock | Spare sinks | Reader result |
| --- | --- | --- | --- |
| Equipped, normal cooling complete | false | 2 | heat_ready |
| Fired to overheat, no manual R | true | 2 | heat_sink_burned_out |
| Manual R completed | false | 1 | heat_ready |

At the locked observation, heat float bits were already `00000000`: checking
heat amount alone would miss the burned-out sink. Config classification was
`heat_requires_replacement=true` with a resource template, and all identity/map
checks passed. Magazine resource `1abbff60d26ba391` was also read successfully
with count 11 on slot 1.

External long-lived read handles sometimes returned Windows error 5 after an
initial successful sample; each failed snapshot was rejected. Single-sample
fresh processes produced the three observations above. This is not evidence
that the addon's in-process reads fail, nor proof that they never will.

The three observations above verify **state interpretation and manual replacement**.
The user subsequently reported: “功能测试通过，能量武器也能使用了。” This is
user confirmation that the functional test passed, including energy-weapon
automatic reload. It does not establish coverage of every weapon variant,
held-fire scenario or zero-spare behavior. `SendInput` acceptance
and `HEAT_LOCK_CLEARED_AFTER_REQUEST` are logged separately; neither log claims
the reload animation was independently verified.
