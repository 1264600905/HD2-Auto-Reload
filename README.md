# HD2 Auto Reload

![HD2 Auto Reload mod cover](HD2-Auto-Reload-cover.png)

Helldivers 2 自动换弹 Mod，依赖 **Bingus Shared Loader v18+ / API 1**。
本仓库独立维护自动换弹源码、打包工具和测试，不包含 Loader 或其他 Mod 项目。

## v0.6.13（补充车载机枪换弹）

当前安装包为 `build/Auto-Reload-v0.6.13.zip`，包含此前定期检查、坦克炮手与乘客修复。替换旧包、部署并重启游戏。

- 补充已只读核对的载具类型 `0x1A`、炮手座位 4 的车载机枪，资源 `085c1edb038ec24e`；弹匣和膛内均打空后自动请求 R。
- 新读取器已在当前游戏中正确读到该机枪空仓，定期复查沿用现有四档设置。本次未运行测试套件，自动输入效果待部署后确认。详见 [v0.6.13 说明](docs/RELEASE_0.6.13.md)。

## v0.6.12（历史发布：坦克炮手与乘客换弹修复）

该版本安装包为 `build/Auto-Reload-v0.6.12.zip`，替换部署后重启游戏。

- 修复原生坦克炮手 `role=2` 被旧 Pilot 限制排除的问题；堡垒和风暴漩涡主炮继续使用原有空仓规则。
- 支持乘客 `role=3` 当前手持武器的换弹，读取人物 Wieldable 当前主槽位，并沿用该武器的空仓、战术、逐发开火优先和定期复查规则。
- 修复座位 `+0x30` 的单字节过渡标志被当作四字节读取的问题；相邻 `+0x31` 标志置位不再误判为正在换座。
- 2026-10-13 只读核对当前游戏：新读取器已正确识别堡垒炮手位的空主炮和乘客位的空手持武器。本次未运行测试套件，自动输入效果待部署后确认。详细证据见 [v0.6.12 说明](docs/RELEASE_0.6.12.md)。

## v0.6.11（历史发布：可设置的定期复查）

该版本安装包为 `build/Auto-Reload-v0.6.11.zip`。替换旧自动换弹包，部署后重启游戏；依赖 Bingus Shared Loader v18+ / API 1，游戏内设置需单独安装支持 API 1 的 Mod Options Menu。

- 新增 **定期检查/Periodic Check**：**0.2 秒（默认）**、**0.5 秒**、**1 秒**、**关闭**，修改后 APPLY，菜单保存和恢复设置。
- 定期复查作为原有即时判断的补充：仍需要换弹时重新请求 R；爆裂铳仍待拉栓时继续尝试。关闭此选项后保留原有行为。
- 沿用开火优先、站桩武器、焦点和输入限制；拉栓仍核对原生标记与动作，相邻请求至少间隔 1 秒。周期开启时可继续尝试超过原三次上限，关闭时仍为三次。
- 按用户要求本次不运行测试，尚未实机验证。安装和行为说明见 [v0.6.11 说明](docs/RELEASE_0.6.11.md)。

## v0.6.10（历史发布：爆裂铳自动拉栓）

安装包为 [Auto-Reload-v0.6.10.zip](https://github.com/1264600905/HD2-Auto-Reload/releases/download/v0.6.10/Auto-Reload-v0.6.10.zip)，本地构建输出位于 `build/`。替换旧自动换弹包，部署后重启游戏。保留 Bingus Shared Loader，菜单仍需单独安装支持 API 1 的 Mod Options Menu。

- 新增 **爆裂铳自动拉栓/Eruptor Auto Bolt**，默认开启，独立于战术换弹开关，已有保存值优先。
- 当前手持爆裂铳确认处于待拉栓状态时短按左键；动作进行中、玩家按住左键或 R、界面屏幕打开、失焦或上下文无效时等待。
- 发送前重新核对武器、原生 `0x800` 标记和动作状态。标记清除后停止；未确认请求最多三次，相邻间隔至少 1 秒。
- 拉栓功能目前仅适配已核对的 build `25480438`，默认开火键须为鼠标左键。旧版本仍保留自动换弹；不兼容的新读取路径只关闭自动拉栓。
- 新增只读字段、输入时序和设置测试。此前手动拉栓对照已确认不消耗下一发；新包的自动输入仍待部署后实测。

详细安装、诊断与验证边界见 [v0.6.10 说明](docs/RELEASE_0.6.10.md)。以下为 v0.6.9 的历史发布和验证记录。

## v0.6.9（历史发布）

唯一安装包为 `build/Auto-Reload-v0.6.9.zip`，仅包含自动换弹。替换旧自动换弹包，保留 Bingus Shared Loader；需要游戏内设置时，单独安装并启用支持 API 1 的 Mod Options Menu，部署后重启游戏。首次默认战术开启、日志关闭，已有保存值优先。未安装菜单时使用默认设置。

- 22 个整弹匣武器统一在弹匣剩 1 发时战术换弹；逐发武器原阈值仍是默认值。
- 换弹延迟固定为 0，删除延迟滑块与连续射击/点击等待。
- **战术换弹/Tactical Reload** 是战术总开关，关闭后仍保留打空自动换弹。
- **日志打印/Logging** 独立显示，默认关闭；关闭时停止自动换弹日志写入和打印，切换时不会重置换弹。
- **换弹不阻止开火/Reload Does Not Block Firing**、**逐发换弹武器换弹阈值/Per-round Reload Threshold** 和 **AC-8机炮换弹阈值/AC-8 Reload Threshold** 始终显示，不随战术总开关隐藏。
- 逐发模式：默认/Default、最后一发/Last Round、第一发/First Shot。AC-8 模式：1发战术换弹/Tactical at 1 Round、5发战术换弹/Tactical at 5 Rounds、不战术换弹/No Tactical Reload。
- 第一发模式将膛内一发计入总余弹，与当前生效容量减1比较，修复“弹匣容量−1＋膛内1发”满弹状态仍反复请求的问题。SG-97 与 GL-15 已通过实机日志核对。
- 所有现有逐发规则都在按住开火时暂停自动 R，松手后复核阈值并补弹；关闭战术换弹也遵守此规则。逐发武器不会注入左键松开事件。
- “换弹不阻止开火”沿用旧选项的名字与保存值；其他非站桩手持武器保留原有主动松键行为，AC-8 保留独立规则。

原站桩武器规则保留。AC-8 选不战术或关闭战术总开关后，须真正打空再点击开火才换弹。关闭战术总开关仍保留子选项保存值；游戏行为在 APPLY 后生效。旧延迟保存值被忽略。

用户实机反馈无明显问题；2026-10-12 日志确认 SG-97 和 GL-15 满弹停发、开火优先及松手后补弹，未发现读取错误或主动松左键。实测证据见 [日志核对记录](docs/RELOAD_LOG_ANALYSIS_2026-10-12.md)，完整更新、安装与诊断说明见 [v0.6.9 发布说明](docs/RELEASE_0.6.9.md)。其他逐发武器及最后一发模式、关闭战术开关的组合已离线覆盖，尚未全部实机验证。

## 分支与版本

| 分支 | 当前版本 | 用途 |
| --- | --- | --- |
| [`main`](https://github.com/1264600905/HD2-Auto-Reload/tree/main) | v0.6.13 | 模拟 R 换弹和爆裂铳拉栓，后续维护版本保持在 v0.7.0 以下 |
| [`native-test`](https://github.com/1264600905/HD2-Auto-Reload/tree/native-test) | v0.7.0 实验版 | 原生换弹开发与实机测试 |

当前分支为 **`main`**，只读检查武器状态并模拟 R；爆裂铳自动拉栓模拟一次左键短按。原生换弹源码、构建开关、测试与说明在 `native-test` 维护；测试通过并决定正式发布后，再单独评估合入主干。

**v0.6.4 历史实测记录**：修复 SG-8P 等离子制裁者的 8 发提前换弹，并增加已核对 Pilot 操作位的堡垒、风暴漩涡和突破机甲支持；四项已获用户实机确认通过。规则、资源 ID、操作位范围和实测状态见 [v0.6.4 测试记录](docs/VEHICLE_RELOAD_0.6.4.md)。

## 功能与状态

- 确认空仓后立即复核并请求换弹，取消固定 1 秒等待；游戏获得焦点时每次更新读取弹药。
- 支持 WeaponRounds 与 WeaponMagazine，覆盖主手、副武器、支援武器槽位。
- 使用弹匣/逐发弹药系统的能量武器走同一逻辑，不按武器外观过滤。
- **散热型激光/能量武器（WeaponHeat）**：确认散热器烧毁且需要更换后立即请求 R。LAS-98 采用下述站桩武器例外，仅在烧毁锁定后重新点击射击才请求 R。正常升温、充能和可自行恢复的冷却锁定不触发。
- 只读检查武器状态，换弹模拟 R，爆裂铳拉栓模拟左键；不改弹药、不写游戏内存、不调用游戏函数。
- 备用弹药不足、原生动作限制等交给游戏处理。默认换弹键须为 R。
- 可在 Mod Options Menu 中切换战术换弹，对指定武器按弹匣余量提前请求 R；保留计划 2 的高速武器阈值和其他 0 发规则。SG-97、GL-15 保留原有的弹匣加膛内一发口径。未安装菜单时也可在构建前选择默认值。
- MG-43、GR-8 等站桩换弹武器不再按空仓计时自动请求 R，必须在确认空仓后重新点击射击。MG-43 曾被报告装备后崩溃；本地版按用户要求试验性启用其 Magazine 读取，尚未实机验证。

v5 已获用户实机反馈：功能测试通过，能量武器也能自动换弹。激光大炮另已只读验证未过热 → 过热锁定 → 换散热器后解锁及备用数量减少。此反馈不代表所有武器和场景均已覆盖。
支持 Steam build `25327279` 和 `25480438`；其他游戏更新仍需重新验证。

主干 **v0.6.13** 沿用 `25480438` 适配，当前安装包为 `Auto-Reload-v0.6.13.zip`，普通空仓、战术、日志、爆裂铳拉栓与定期检查由游戏内设置切换。SG-8P 和三种载具的历史实测记录见上文；原生炮手、乘客和新增车载机枪支持见本页最新说明，版本适配证据见 [更新记录](docs/BUILD_25480438.md)。

## 安装与测试

按下方构建步骤生成本地 `Auto-Reload-v0.6.13.zip`；安装和行为说明见 [v0.6.13 说明](docs/RELEASE_0.6.13.md)。历史公开包仍可从 [v0.6.10 Release](https://github.com/1264600905/HD2-Auto-Reload/releases/tag/v0.6.10) 下载，该包没有定期检查选项和原生炮手/乘客修复。游戏内设置需单独安装支持 API 1 的 Mod Options Menu，所有设置始终显示。历史 v0.6.1 包不含游戏更新的适配与初始化修复；v0.7.0 包对应 `native-test` 实验分支。
在现用 Mod 管理器中替换旧 Auto Reload，保持只启用一份，再与 Bingus Shared Loader 一起部署。
新版本沿用旧版 GUID，所以应替换旧包，不应并行安装。

普通武器带足备用弹药，测试达到阈值或打空后立即请求 R，以及继续攻击的重试方式。
能量武器测试：有可更换散热器的普通武器烧毁后立即请求换弹；LAS-98 仍须烧毁后重新点击射击。
普通冷却过程中不应按 R。换槽位、失去游戏焦点均须取消旧武器的待发送请求。手动按 R 不会禁用自动换弹。
替换部署后需重启游戏，已运行的 Lua 不会因替换 zip 自动刷新。
资源 `11c27d3babb38956`（MG-43）曾被报告装备后崩溃；本地版已试验性启用。测试时先观察装备及空仓前的日志与稳定性，再测试空仓后的新射击点击。

日志位置：`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。
v0.6.13 包版本行应含 `revision=auto-reload-0.6.13`。输入被系统接受不等于游戏完成动作，日志会区分请求、弹药恢复、拉栓标记清除与未确认结果。
不要将完整个人运行日志、游戏 DLL 或内存转储提交到本仓库。

## 构建

Python 3.10+，仅使用标准库，无需下载或安装其他项目：

```powershell
python scripts/build.py
# 可选：对本地游戏执行完整 SHA256 校验
python scripts/build.py --game-dir '你的 Steam 游戏目录/Helldivers 2'
```

构建始终输出 `build/Auto-Reload-v0.6.13.zip`，只打包自动换弹资源，不需要菜单源码。普通、战术、诊断、拉栓和定期检查行为由单独安装的 Mod Options Menu 中的设置切换，不再生成不同包；菜单只需支持 API 1，无需条件显示功能。

当前逐发修复与验证步骤见 [v0.6.9 说明](docs/RELEASE_0.6.9.md)，其他规则与选项见 [v0.6.8 菜单说明](docs/MOD_OPTIONS_0.6.8.md)。首次请求在条件允许时零延迟；逐发武器按住开火时等待松手。即时复核、武器身份和自有 R 释放约束仍保留。系统接受输入不代表游戏完成换弹。

组件 map 以十六进制文本保存在 `data/`，构建时嵌入 Lua；运行时验证完整指纹、资源记录和实体身份。
游戏内还会验证 DLL PE 标识，以及玩家、实体、物品栏、Rounds、Magazine 和 Heat 的已核对指令片段。v5 使用新版 Magazine/Rounds/Heat 全表指纹和定点槽位。

需要排查时，在游戏 `MODS → 自动换弹/Auto Reload` 中开启 **日志打印/Logging** 并 APPLY。日志仍位于 `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`，启用行含 `LOGGING_ENABLED revision=auto-reload-0.6.13`。`OPTIONS_APPLIED` 记录定期检查选项及秒数，`PER_ROUND_STATE` 行在弹药、容量、设置或开火状态变化时记录总弹量、阈值和等待原因；座位诊断见 v0.6.12 说明，拉栓诊断见 v0.6.10 说明。关闭日志后不继续写入该文件。

## 测试

安装 LuaJIT 2.1 并将其加入 PATH 后，在仓库根目录运行：

```powershell
python scripts/build.py
python -m unittest discover -s tests -p 'test_*.py'
luajit tests/test_auto_reload.lua
luajit tests/test_eruptor_bolt.lua
luajit tests/test_mod_options.lua
luajit tests/test_auto_reload_maps.lua
luajit tests/test_context.lua
luajit tests/test_read_api.lua
```

Lua 测试模拟内存和输入接口，不向 Windows 或游戏发送实际按键。
按键时序、最后一发膛内子弹、槽位、身份校验、完整静态 map 等均有覆盖。
离线测试不能代替游戏内验证。

可选真实菜单集成测试（源码目录可替换为你的 ModOptionsMenu 路径），使用独立测试目录验证选项注册、始终显示和保存恢复，不发送按键：

```powershell
New-Item -ItemType Directory -Path build/options-menu-test -Force | Out-Null
luajit tests/test_mod_options.lua ../ModOptionsMenu-main build/options-menu-test
```

参考来源和许可说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

新版布局和实机字段证据见 [HEAT_LAYOUT_EVIDENCE.md](docs/HEAT_LAYOUT_EVIDENCE.md)。`scripts/read_live_context.lua` 可用只读进程句柄运行实际读取器，不执行 Mod 回调、不发送按键。
