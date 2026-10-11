# HD2 Auto Reload

![HD2 Auto Reload mod cover](HD2-Auto-Reload-cover.png)

Helldivers 2 自动换弹 Mod，依赖 **Bingus Shared Loader v15+ / API 1**。
本仓库独立维护自动换弹源码、打包工具和测试，不包含 Loader 或其他 Mod 项目。

## 本地持续开火试验版 v0.6.7

非站桩手持武器达到换弹条件时，若左键仍按住，会先模拟松开左键，并在同一次更新中请求 R，不增加固定延迟，也不松开瞄准。经过打断的单次请求最多补发两次，间隔为 1、2 秒；弹药增加或上下文改变即取消。站桩武器与载具保持原有规则，毒矛和逐发续装保留原有重试。

本次先验证停止开火后换弹，不自动恢复左键按下；换弹后需重新按下开火。实机效果尚待验证。诊断安装包为 `build/[战术换弹]Auto-Reload-v0.6.7-tactical-debug.zip`，运行版本应为 `auto-reload-0.6.7-debug`。替换旧包、部署后重启游戏，保持仅一份自动换弹。

## v0.6.6 菜单设置

当前工作区支持 **Mod Options Menu**，在游戏 `Esc → MODS → 自动换弹` 中设置：

- **启用战术换弹**：控制是否按现有武器阈值提前换弹。普通包默认关闭，战术包默认开启；已有保存值优先。
- **换弹延迟（秒）**：0–5 秒，步进 0.05 秒，默认 0。适用于普通、战术和散热器换弹，包括此前立即换弹的高速武器和最后一发。
- **射击推迟下一次换弹**：默认开启；在换弹窗口内每次射击重新计算上述延迟，包括按住射击产生的弹药消耗。关闭后射击不重置计时。

点击 **APPLY / 应用（Tab）** 后生效，Mod Options Menu 负责保存并在重启后恢复。替换自动换弹包、同时安装 Mod Options Menu v1.2 和 Bingus Shared Loader v18+，部署后重启游戏。只需保留一个自动换弹包，两种包都能在菜单中切换战术换弹。未安装菜单时沿用原有构建默认值及计时规则。

v0.6.6 保留 v0.6.5 的 S-11 矛枪（毒矛）有限空仓重试；安装菜单后重试间隔至少为设置的延迟。站桩换弹武器仍需空仓后重新点击射击，并从该次点击开始等待；逐发续装开始后仍保持至少 0.1 秒的请求间隔。

离线控制器、菜单 API、设置保存恢复、读取链和打包验证通过。用户已确认驱逐者在调整键位后恢复正常；尚未完成全部菜单选项与武器的实机验证。构建和测试方法见下文，设置行为及实机检查步骤见 [菜单设置说明](docs/MOD_OPTIONS_0.6.6.md)。运行日志版本为 `auto-reload-0.6.6`，诊断包为 `auto-reload-0.6.6-debug`。

当前构建脚本的普通、战术及诊断产物均为 v0.6.7。下文的 v0.6.4 分支表、Release 链接和历史安装说明对应已发布基线；v0.6.7 暂为本地测试版本，未发布。v0.6.5 的毒矛诊断记录见 [原修复说明](docs/SPEARGUN_RETRY_0.6.5.md)。

## 分支与版本

| 分支 | 当前版本 | 用途 |
| --- | --- | --- |
| [`main`](https://github.com/1264600905/HD2-Auto-Reload/tree/main) | v0.6.4 | 模拟 R 换弹主干，后续维护版本保持在 v0.7.0 以下 |
| [`native-test`](https://github.com/1264600905/HD2-Auto-Reload/tree/native-test) | v0.7.0 实验版 | 原生换弹开发与实机测试 |

当前分支为 **`main`**，仅只读检查武器状态并模拟 R。原生换弹源码、构建开关、测试与说明在 `native-test` 维护；测试通过并决定正式发布后，再单独评估合入主干。

当前版本为 **v0.6.4**。修复 SG-8P 等离子制裁者的 8 发提前换弹，并增加已核对 Pilot 操作位的堡垒、风暴漩涡和突破机甲支持；四项已获用户实机确认通过。规则、资源 ID、操作位范围和实测状态见 [v0.6.4 测试记录](docs/VEHICLE_RELOAD_0.6.4.md)。

## 功能与状态

- 确认空仓后立即复核并请求换弹，取消固定 1 秒等待；游戏获得焦点时每次更新读取弹药。
- 支持 WeaponRounds 与 WeaponMagazine，覆盖主手、副武器、支援武器槽位。
- 使用弹匣/逐发弹药系统的能量武器走同一逻辑，不按武器外观过滤。
- **散热型激光/能量武器（WeaponHeat）**：确认散热器烧毁且需要更换后立即请求 R。LAS-98 采用下述站桩武器例外，仅在烧毁锁定后重新点击射击才请求 R。正常升温、充能和可自行恢复的冷却锁定不触发。
- 仅只读检查武器状态并模拟 R，不改弹药、不写游戏内存、不调用游戏函数。
- 备用弹药不足、原生动作限制等交给游戏处理。默认换弹键须为 R。
- 可在 Mod Options Menu 中切换战术换弹，对指定武器按弹匣余量提前请求 R；保留计划 2 的高速武器阈值和其他 0 发规则。SG-97、GL-15 保留原有的弹匣加膛内一发口径。未安装菜单时也可在构建前选择默认值。
- MG-43、GR-8 等站桩换弹武器不再按空仓计时自动请求 R，必须在确认空仓后重新点击射击。MG-43 曾被报告装备后崩溃；本地版按用户要求试验性启用其 Magazine 读取，尚未实机验证。

v5 已获用户实机反馈：功能测试通过，能量武器也能自动换弹。激光大炮另已只读验证未过热 → 过热锁定 → 换散热器后解锁及备用数量减少。此反馈不代表所有武器和场景均已覆盖。
支持 Steam build `25327279` 和 `25480438`；其他游戏更新仍需重新验证。

主干 **v0.6.4** 沿用 `25480438` 适配。推荐安装 `build/[战术换弹]Auto-Reload-v0.6.4-tactical.zip`，普通空仓版为 `build/[普通换弹]Auto-Reload-v0.6.4.zip`。在 Mod 管理器中替换旧包、重新部署并重启游戏。本次战术诊断包已实测 SG-8P 和三种载具自动换弹；版本适配证据见 [更新记录](docs/BUILD_25480438.md)。

## 安装与测试

从 [v0.6.4 Release](https://github.com/1264600905/HD2-Auto-Reload/releases/tag/v0.6.4) 下载，或在 `main` 按下方构建步骤生成：推荐 `[战术换弹]Auto-Reload-v0.6.4-tactical.zip`（启用武器配置，突破机甲 ≤5 发补弹），仅普通空仓换弹可选 `[普通换弹]Auto-Reload-v0.6.4.zip`。安装与修复说明见 [v0.6.4 发布说明](docs/RELEASE_0.6.4.md)。历史 v0.6.1 包不含游戏更新的适配与初始化修复；v0.7.0 包对应 `native-test` 实验分支。
在现用 Mod 管理器中替换旧 Auto Reload，保持只启用一份，再与 Bingus Shared Loader 一起部署。
新版本沿用旧版 GUID，所以应替换旧包，不应并行安装。

普通武器带足备用弹药，测试达到阈值或打空后立即请求 R，以及继续攻击的重试方式。
能量武器测试：有可更换散热器的普通武器烧毁后立即请求换弹；LAS-98 仍须烧毁后重新点击射击。
普通冷却过程中不应按 R。换槽位、失去游戏焦点均须取消旧武器的待发送请求。手动按 R 不会禁用自动换弹。
替换部署后需重启游戏，已运行的 Lua 不会因替换 zip 自动刷新。
资源 `11c27d3babb38956`（MG-43）曾被报告装备后崩溃；本地版已试验性启用。测试时先观察装备及空仓前的日志与稳定性，再测试空仓后的新射击点击。

日志位置：`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。
v0.6.4 包版本行应含 `revision=auto-reload-0.6.4`。输入被系统接受不等于游戏完成换弹，日志会区分请求、弹药恢复与未确认结果。
不要将完整个人运行日志、游戏 DLL 或内存转储提交到本仓库。

## 构建

Python 3.10+，仅使用标准库，无需下载或安装其他项目：

```powershell
python scripts/build.py
# 构建默认启用战术换弹的安装包；安装菜单后两种包都可切换
python scripts/build.py --enable-tactical-reload
# 可选：对本地游戏执行完整 SHA256 校验
python scripts/build.py --game-dir '你的 Steam 游戏目录/Helldivers 2'
```

当前本地默认产物为 `build/[普通换弹]Auto-Reload-v0.6.7.zip`；加 `--enable-tactical-reload` 会生成 `build/[战术换弹]Auto-Reload-v0.6.7-tactical.zip`。普通和普通诊断包均加 `[普通换弹]` 前缀，战术和战术诊断包均加 `[战术换弹]` 前缀。二者沿用同一 GUID，只能部署其中一份。`build/` 不纳入源码提交。
安装 Mod Options Menu 后，两种包都支持全部三个设置；已有保存值优先于包的默认值。没有菜单且需要提前换弹时请选择 **`build/[战术换弹]Auto-Reload-v0.6.7-tactical.zip`**。

构建默认值也可在 [换弹配置](src/reload_config.lua) 中将 `ENABLE_TACTICAL_RELOAD` 设为 `true`。武器阈值仍为静态配置，修改后须重新构建、部署并重启游戏。菜单设置在应用后生效，无需重新构建。

以下点击等待和立即换弹规则说明**未安装 Mod Options Menu 时的行为**；菜单成功注册延迟选项后，所有武器改用设置的延迟，不再递增到 0.2、0.4、0.6 秒，也不再由高速规则或最后一发绕过延迟。

- `limit` 是弹匣阈值，不包含膛内弹；SG-97（总弹 ≤4）和 GL-15（总弹 ≤2）保留 `basis='total'`。
- 计划 2：AR 开头的手持武器（不含 JAR）、BR-14、SMG 系列、M7S、StA-11、P-2、P-19、M6C/SOCOM 为弹匣 ≤3；M-105 和手持 MK3 为 ≤10。原文 M-105 同时列出 3 和 10，以后一条专门要求为准。
- 上述武器配置 `immediate=true`：达到阈值立即复核并请求 R，不等 0.1 秒，也不等连续点击延迟。复核期间弹药继续下降仍允许请求；同一余量不每帧重发，继续消耗弹药或重新点击射击可以重试。
- 其他零阈值规则保留，弹匣 0 发即请求，不必等膛内最后一发打完。没有战术规则的武器仍要求真正空仓。
- SG-8P 改为 0 发，取消旧 8 发阈值。已核对 Pilot 操作位的堡垒和风暴漩涡主炮均为 0 发，突破机甲战术版为弹匣 ≤5 发逐发补弹；普通版仅空仓触发。其他座位角色与载具武器跳过。
- 其他战术武器余量大于 1 时，只有进入配置阈值的换弹窗口才开始等待 0.1 秒；窗口内相邻点击间隔 ≤0.5 秒时，提高到 0.2、0.4、0.6 秒，从最新点击重新计时。窗口外的点击不计入，离开窗口后清空计时和档位。余量 1 或 0 时不受这段等待限制。逐发续装请求间隔仍为 0.1 秒。
- 不设置手动换弹抑制：手动 R 不会锁住后续自动请求。自动输入遇到 R 已按下时先松开，下一次更新再按下；每次模拟按键释放后也至少隔一次更新才允许再次按下。发送失败或等待松键不会消耗重试机会。

当前日志版本为 `auto-reload-0.6.7`，战术版 `START` 行记录构建默认值 `tactical_reload=true reload_delay=0`；菜单已保存或新应用的值见 `OPTIONS_APPLIED` 行。“立即”指设置延迟为 0 后，读取、复核符合条件就发送输入；游戏动画和原生动作限制仍可能拒绝换弹。

组件 map 以十六进制文本保存在 `data/`，构建时嵌入 Lua；运行时验证完整指纹、资源记录和实体身份。
游戏内还会验证 DLL PE 标识，以及玩家、实体、物品栏、Rounds、Magazine 和 Heat 的已核对指令片段。v5 使用新版 Magazine/Rounds/Heat 全表指纹和定点槽位。

排查空仓附近闪退时可构建 `python scripts/build.py --debug`，产物为
`build/[普通换弹]Auto-Reload-v0.6.7-debug.zip`；默认启用战术规则时加 `--enable-tactical-reload`，使用 `build/[战术换弹]Auto-Reload-v0.6.6-tactical-debug.zip`。调试包沿用同一 GUID，应替换普通版并重启游戏。
日志的 `START` 行会显示 `revision=auto-reload-0.6.7-debug debug=true`；
`DEBUG_SNAPSHOT_*`、`DEBUG_AUTO_STEP_*`、`DEBUG_RELOAD_*` 和 `DEBUG_SENDINPUT_*`
会在接近空仓及请求换弹时记录调用边界。
日志仍位于 `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。

## 测试

安装 LuaJIT 2.1 并将其加入 PATH 后，在仓库根目录运行：

```powershell
python scripts/build.py
python -m unittest discover -s tests -p 'test_*.py'
luajit tests/test_auto_reload.lua
luajit tests/test_mod_options.lua
luajit tests/test_auto_reload_maps.lua
luajit tests/test_context.lua
luajit tests/test_read_api.lua
```

Lua 测试模拟内存和输入接口，不向 Windows 或游戏发送实际按键。
按键时序、最后一发膛内子弹、槽位、身份校验、完整静态 map 等均有覆盖。
离线测试不能代替游戏内验证。

可选真实菜单集成测试（源码目录可替换为你的 ModOptionsMenu 路径），使用独立测试目录验证选项注册、滑块步进和保存恢复，不发送按键：

```powershell
New-Item -ItemType Directory -Path build/options-menu-test -Force | Out-Null
luajit tests/test_mod_options.lua ../ModOptionsMenu-main build/options-menu-test
```

参考来源和许可说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

新版布局和实机字段证据见 [HEAT_LAYOUT_EVIDENCE.md](docs/HEAT_LAYOUT_EVIDENCE.md)。`scripts/read_live_context.lua` 可用只读进程句柄运行实际读取器，不执行 Mod 回调、不发送按键。
