# Changelog

## 分支维护

- `main` 恢复 v0.6.3 的模拟 R 换弹实现，后续维护版本保持在 v0.7.0 以下。
- v0.7.0 原生换弹源码、构建开关、测试和说明保留在 `native-test`；原有 v0.7.0 标签保留为历史测试版本。

## 0.6.11（可设置的定期复查）

- 新增“定期检查/Periodic Check”：0.2 秒、0.5 秒、1 秒、关闭，默认 0.2 秒；支持 APPLY、保存恢复，未安装菜单时也使用默认值。
- 在原有即时判断之外定期复核，仍达到换弹条件时允许再次请求 R，避免先前请求被忽略后只等待新的开火点击；站桩等必须重新开火的武器继续遵守原规则。
- 爆裂铳仍待拉栓时，定期检查允许在原三次请求之后继续重试；每次重新核对身份、原生标记、动作和输入，相邻拉栓请求仍至少间隔 1 秒。
- 关闭定期检查后沿用原有换弹触发和最多三次拉栓请求；设置切换重置复查计时，失焦期间不累计补发，复用现有逐帧快照。
- 重新构建 `build/Auto-Reload-v0.6.11.zip`。按用户要求不运行测试，尚未实机验证。

## 0.6.10（爆裂铳自动拉栓）

- 新增默认开启的“爆裂铳自动拉栓/Eruptor Auto Bolt”独立开关，支持 APPLY 和保存恢复；不受战术换弹总开关控制。
- 仅对当前本地玩家手持爆裂铳读取原生待拉栓标记 `0x800`、有效拉栓动作 ID `2660` 和动作执行状态；新字段适配 build 25480438，其他构建或布局不符时保留原有弹药读取和换弹。
- 发送前再次检查身份、标记、武器与玩家实体的动作及 UI 屏幕栈；玩家按住左键/R、自动 R 尚未释放、动作进行中、屏幕打开或失焦时不补开火。
- 一次左键短按最多保持 80 毫秒；动作开始、标记清除、换枪、失焦、关闭设置或 shutdown 时释放自有输入。失败的松键保留所有权并重试，释放帧不开始新 R 或左键。
- 未确认输入最多三次，至少间隔 1 秒；输入接受与标记清除分别记录。自有短按不生成玩家的开火边沿。
- 只读实机分析已确认手动拉栓不消耗下一发。新包自动输入、界面保护和最后一发组合仍待部署后的实机验证。

## 0.6.9（逐发满弹判断与开火优先修复）

- 第一发模式改用选中弹匣加膛内一发的总余弹，与生效容量减1比较；“弹匣容量−1＋膛内1发”的满弹状态停止请求。无枪膛武器不添加膛内弹，膛内信息不完整时跳过提前补弹。
- 所有现有逐发武器按住左键时暂停自动 R，松手后立即复核并继续补弹；首次请求、连续补弹及发送输入前均检查开火状态。逐发识别独立于战术总开关，不扩大到 AC-8 等整夹装填武器。
- 逐发武器不再主动松开左键；其他手持武器、站桩武器及非逐发载具规则保持原行为。
- 安装包仅保留自动换弹资源，Mod Options Menu 改为单独安装，支持 API 1 即可；所有设置始终显示，不再依赖条件显示菜单补丁。
- 新增随状态变化输出的 `PER_ROUND_STATE` 诊断，含弹匣、膛内 token、总余弹、当前弹匣容量、配置来源、模式、阈值与开火暂停原因。日志开关与保存值沿用，默认关闭。
- Python 只读采集入口自动定位游戏进程，沿用已校验的读取器，记录容量、枪膛、选择弹匣和左键状态；同一次游戏会话即可核对。
- 72 项控制器、8 项设置集成和 7 项 Python 检查，以及读取链与包体验证通过。2026-10-12 用户实测反馈无明显问题；SG-97 / GL-15 日志确认容量口径、满弹停发、开火等待与松手补弹，无主动松键、读取错误或 8 秒未确认记录。其他武器与模式组合的完整实机覆盖仍待补充。

## 0.6.8（战术阈值与菜单更新、后续本地调整）

原始公开 Release 内置 Mod Options Menu v1.3；下文包含后续本地独立菜单调整，独立菜单方案随 v0.6.9 正式发布。

- 合并普通、战术、诊断产物为唯一 `Auto-Reload-v0.6.8.zip`，仅包含自动换弹，Mod Options Menu 单独安装。战术开关和日志开关均在游戏内设置；首次默认战术开启、日志关闭，已有保存值优先。
- 日志关闭时不打开、写入或刷新自动换弹日志，也不打印诊断文本；日志切换不重置正在进行的换弹。
- 22 个整弹匣高速武器配置统一改为弹匣 ≤1 发；原逐发规则保留为“默认”选项。
- 移除换弹延迟设置与所有射击/点击等待，首次请求固定零延迟。主动松开左键仍默认启用，无配置开关；旧射击选项仅更名为“换弹不阻止开火”。
- 新增逐发武器“默认 / 最后一发 / 第一发”选项；第一发模式按已验证的当前生效弹匣容量计算阈值，兼容实体覆盖与双弹匣。
- 新增 AC-8“1发 / 5发 / 不战术换弹”；不战术或总开关关闭时，仅真正空仓后的新射击点击触发。
- 所有菜单标签、选择与分类采用中文/英文。菜单只需支持 API 1；所有设置始终显示，不随战术总开关隐藏，关闭战术总开关仍保留子选项保存值。
- 移除菜单资源、菜单条件显示补丁及构建时的菜单源码依赖，避免与单独安装的 Mod Options Menu 重复覆盖同一资源。
- 仅离线验证与打包，不执行外部注入测试。待用户部署后验证游戏内菜单与新阈值。

## 0.6.7（持续开火换弹试验版）

- 非站桩的手持武器达到换弹条件后，若左键仍按住，先模拟松开左键，再在同一次更新内发送 R，不增加固定等待；右键瞄准不变。
- 打断开火后的单次请求在持续满足条件时最多补发两次，相邻间隔为 1、2 秒。弹药增加、换武器、失去焦点或应用设置会取消补发；毒矛和逐发续装保留原有重试方式。
- 站桩武器及载具输入保留原有行为。试验版不模拟重新按下左键，换弹后需重新按下开火。
- 输入顺序、发送失败、有限重试及取消条件已通过离线检查，尚待持续按住开火的实机验证。

## 0.6.6（本地设置版）

- 接入 Mod Options Menu API 1，在“自动换弹”分类添加中文战术换弹开关、0–5 秒延迟滑块（步进 0.05 秒）和射击推迟开关。
- 应用后生效并读取菜单保存值；支持菜单先后加载，未安装菜单时保留原有行为。两种构建包只影响首次使用时的战术默认值。
- 菜单延迟统一作用于普通、战术、散热器及站桩触发后的换弹，高速武器与最后一发不绕过设置；射击推迟支持鼠标点击与连续射击的弹药减少。
- 设置变更、离开换弹窗口、换武器或失去焦点时清除旧计时；站桩武器的新射击点击能保留至较长延迟结束。逐发续装保留 0.1 秒最小请求间隔。
- 保留毒矛有限重试，并让其间隔至少满足菜单延迟。真实菜单源码离线验证三个选项注册、步进及保存恢复，尚待游戏内验证。

## 0.6.5（本地修复候选）

- S-11 矛枪（毒矛）首次空仓请求后，若仍确认空仓，按 0.25、0.5、1 秒间隔最多补发三次 R；首次请求仍立即发送。
- 每次补发重新校验弹药和武器身份；弹药恢复、换武器或失去焦点时清除重试，发送失败和松键等待不消耗次数。
- 修复已观察到的“系统接受 R 后持续空仓，旧版仅等再次点击射击”的缺少自动重试问题；首次请求未被游戏执行的具体动作原因未确认。
- 仅作用于资源 `3828e2051aa9e897`，普通版和战术版均生效。尚待部署、重启游戏及毒矛实机验证。

## 0.6.4

- SG-8P 等离子制裁者取消 8 发提前换弹，改为打空触发。
- 增加已核对 Pilot 操作位的 Seater / Wieldable 选择读取，支持堡垒和风暴漩涡主炮打空换弹。
- 战术版增加突破机甲 ≤5 发逐发补弹；普通版仍仅空仓触发。
- 上下车、换座位和武器选择改变时取消旧请求，乘客和未核对角色跳过。
- 增加只读载具采样及控制器 dry-run 工具；实机数据、适用操作位和验证状态见 [测试记录](docs/VEHICLE_RELOAD_0.6.4.md)。
- 战术诊断版四项获用户实机确认通过，54 项控制器行为测试及其余读取链、组件表和打包检查通过。

## 0.6.3

- 作为 `main` 的模拟 R 换弹版本发布；普通、战术及对应诊断包统一添加 `[普通换弹]` / `[战术换弹]` 中文前缀。
- 修复独立加载时 SendInput 缺少 FFI 声明导致初始化失败，保留已有声明的兼容处理。
- 增加 Windows 独立进程初始化测试，覆盖无声明及已有不同指针声明两种情况，不发送按键。
- 修正输入测试桩的 void 指针读取，51 项行为测试全部通过。

## 0.6.2

- 支持 Steam build 25480438，保留 25327279 兼容性。
- 实机只读核对关键指令及三类完整组件表，保持原有布局、身份和状态校验。
- 统一实机诊断脚本和 Mod 的版本校验，构建校验要求 DLL/EXE 属于同一受支持版本。

## 0.6.1

- Fix `SendInput` FFI type collisions with other loaded addons.
- Publish rebuilt ordinary, tactical, and diagnostic packages.

## 0.6.0

- Publish configurable tactical thresholds, immediate empty reloads, window-scoped click delays, and manual suppression removal.
- Ship ordinary, tactical, and matching diagnostic packages with versioned names and runtime revision 0.6.0.
- See [release notes](docs/RELEASE_0.6.0.md) for installation, validation, and known limitations.

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
