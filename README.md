# HD2 Auto Reload

![HD2 Auto Reload mod cover](HD2-Auto-Reload-cover.png)

Helldivers 2 自动换弹 Mod，依赖 **Bingus Shared Loader v15+ / API 1**。
本仓库独立维护自动换弹源码、打包工具和测试，不包含 Loader 或其他 Mod 项目。

## 本地版 v0.6.8

战术版安装包为 `build/[战术换弹]Auto-Reload-v0.6.8-tactical.zip`，配套菜单为 `ModOptionsMenu-main/releases/Mod-Options-Menu-v1.3.zip`。替换各自旧包，部署后重启游戏，只保留各一份。默认推荐非诊断包。

- 22 个整弹匣武器统一在弹匣剩 1 发时战术换弹；逐发武器原阈值仍是默认值。
- 换弹延迟固定为 0，删除延迟滑块与连续射击/点击等待。
- **战术换弹/Tactical Reload** 是战术总开关，关闭后仍保留打空自动换弹。
- 开启战术换弹后显示 **换弹不阻止开火/Reload Does Not Block Firing**、**逐发换弹武器换弹阈值/Per-round Reload Threshold** 和 **AC-8机炮换弹阈值/AC-8 Reload Threshold**。
- 逐发模式：默认/Default、最后一发/Last Round、第一发/First Shot。AC-8 模式：1发战术换弹/Tactical at 1 Round、5发战术换弹/Tactical at 5 Rounds、不战术换弹/No Tactical Reload。
- “换弹不阻止开火”只沿用旧选项的名字与保存值，不控制主动松左键。非站桩手持武器仍默认先松左键并在同一次更新内发送 R，无松键开关；换弹后需重新按下开火。

原站桩武器规则保留。AC-8 选不战术或关闭战术总开关后，须真正打空再点击开火才换弹。子选项隐藏时保存值保留；游戏行为在 APPLY 后生效。旧延迟保存值被忽略。

本次只做离线检查和打包，新阈值与菜单仍待用户部署后验证。详细规则、默认值与容量读法见 [v0.6.8 菜单说明](docs/MOD_OPTIONS_0.6.8.md)。旧版记录保留在 [v0.6.6 菜单说明](docs/MOD_OPTIONS_0.6.6.md) 和 [更新记录](CHANGELOG.md)。

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

当前本地默认产物为 `build/[普通换弹]Auto-Reload-v0.6.8.zip`；加 `--enable-tactical-reload` 会生成 `build/[战术换弹]Auto-Reload-v0.6.8-tactical.zip`。普通和普通诊断包均加 `[普通换弹]` 前缀，战术和战术诊断包均加 `[战术换弹]` 前缀。二者沿用同一 GUID，只能部署其中一份。`build/` 不纳入源码提交。
安装 Mod Options Menu 后，两种包都支持全部三个设置；已有保存值优先于包的默认值。没有菜单且需要提前换弹时请选择 **`build/[战术换弹]Auto-Reload-v0.6.8-tactical.zip`**。

构建默认值也可在 [换弹配置](src/reload_config.lua) 中将 `ENABLE_TACTICAL_RELOAD` 设为 `true`。武器阈值仍为静态配置，修改后须重新构建、部署并重启游戏。菜单设置在应用后生效，无需重新构建。

当前规则与选项见 [v0.6.8 菜单说明](docs/MOD_OPTIONS_0.6.8.md)。所有首次请求均零延迟；即时复核、武器身份和自有 R 释放约束仍保留。系统接受输入不代表游戏完成换弹。

组件 map 以十六进制文本保存在 `data/`，构建时嵌入 Lua；运行时验证完整指纹、资源记录和实体身份。
游戏内还会验证 DLL PE 标识，以及玩家、实体、物品栏、Rounds、Magazine 和 Heat 的已核对指令片段。v5 使用新版 Magazine/Rounds/Heat 全表指纹和定点槽位。

排查空仓附近闪退时可构建 `python scripts/build.py --debug`，产物为
`build/[普通换弹]Auto-Reload-v0.6.8-debug.zip`；默认启用战术规则时加 `--enable-tactical-reload`，使用 `build/[战术换弹]Auto-Reload-v0.6.6-tactical-debug.zip`。调试包沿用同一 GUID，应替换普通版并重启游戏。
日志的 `START` 行会显示 `revision=auto-reload-0.6.8-debug debug=true`；
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
