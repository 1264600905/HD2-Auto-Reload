# HD2 Auto Reload

![HD2 Auto Reload mod cover](HD2-Auto-Reload-cover.png)

Helldivers 2 自动换弹 Mod，依赖 **Bingus Shared Loader v15+ / API 1**。
本仓库独立维护自动换弹源码、打包工具和测试，不包含 Loader 或其他 Mod 项目。

## 功能与状态

- 空仓等待 **1 秒**后请求换弹；继续攻击也能触发。
- 支持 WeaponRounds 与 WeaponMagazine，覆盖主手、副武器、支援武器槽位。
- 使用弹匣/逐发弹药系统的能量武器走同一逻辑，不按武器外观过滤。
- **散热型激光/能量武器（WeaponHeat）**：确认散热器烧毁并锁定 1 秒后请求 R；持续开火也等待满 1 秒。LAS-98 采用下述站桩武器例外，仅在烧毁锁定后重新点击射击才请求 R。正常升温、充能和可自行恢复的冷却锁定不触发。
- 仅只读检查武器状态并模拟 R，不改弹药、不写游戏内存、不调用游戏函数。
- 备用弹药不足、原生动作限制等交给游戏处理。默认换弹键须为 R。
- 可在构建前启用战术换弹，对指定武器按弹匣余量提前请求 R；SG-97、GL-15 保留原有的弹匣加膛内一发口径。
- MG-43、GR-8 等站桩换弹武器不再按空仓计时自动请求 R，必须在确认空仓后重新点击射击。MG-43 曾被报告装备后崩溃；本地版按用户要求试验性启用其 Magazine 读取，尚未实机验证。

v5 已获用户实机反馈：功能测试通过，能量武器也能自动换弹。激光大炮另已只读验证未过热 → 过热锁定 → 换散热器后解锁及备用数量减少。此反馈不代表所有武器和场景均已覆盖。
支持的游戏版本固定为 Steam build `25327279`，更新游戏后需重新验证。

## 安装与测试

从 [v0.5.1 Release](https://github.com/1264600905/HD2-Auto-Reload/releases/tag/v0.5.1) 下载 `Auto-Reload-v0.5.1.zip`，或在本地构建。旧版 v4 不支持此次游戏更新。
在现用 Mod 管理器中替换旧 Auto Reload，保持只启用一份，再与 Bingus Shared Loader 一起部署。
新版本沿用旧版 GUID，所以应替换旧包，不应并行安装。

普通武器带足备用弹药，测试打空后等待 1 秒，以及继续攻击的触发方式。
能量武器测试：装备激光大炮等有可更换散热器的武器，射击至过热，观察约 1 秒后是否自动请求换弹；也测试持续按住攻击的情况。
普通冷却过程中不应按 R。换槽位、手动按 R、失去游戏焦点均须取消旧武器的待发送请求。
替换部署后需重启游戏，已运行的 Lua 不会因替换 zip 自动刷新。
资源 `11c27d3babb38956`（MG-43）曾被报告装备后崩溃；本地版已试验性启用。测试时先观察装备及空仓前的日志与稳定性，再测试空仓后的新射击点击。

日志位置：`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。
版本行应含 `revision=auto-reload-0.5.1`。输入被系统接受不等于游戏完成换弹，日志会区分请求、弹药恢复与未确认结果。
不要将完整个人运行日志、游戏 DLL 或内存转储提交到本仓库。

## 构建

Python 3.10+，仅使用标准库，无需下载或安装其他项目：

```powershell
python scripts/build.py
# 构建“启用战术换弹”的独立安装包
python scripts/build.py --enable-tactical-reload
# 可选：对本地游戏执行完整 SHA256 校验
python scripts/build.py --game-dir '你的 Steam 游戏目录/Helldivers 2'
```

当前本地默认产物为 `build/Auto-Reload-configurable.zip`；加 `--enable-tactical-reload` 会生成 `build/Auto-Reload-configurable-tactical.zip`。二者沿用同一 GUID，只能部署其中一份。正式发布版仍从上面的 v0.5.1 Release 下载。`build/` 不纳入源码提交。
“启用战术换弹”是构建前的开关：可以使用上述参数，或在 [静态换弹配置](src/reload_config.lua) 中将 `ENABLE_TACTICAL_RELOAD` 设为 `true`；默认关闭。配置改动后须重新构建、部署并重启游戏，游玩时不能修改。每条规则按武器资源 ID 指定弹匣阈值、组件类型及是否逐发续装；可为其他已验证的武器新增规则。SG-97（总弹 ≤4）和 GL-15（总弹 ≤2）的现有计数口径不变。弹药数量大于 1 时，达到战术阈值后按最近一次射击点击等待 0.1 秒；0.5 秒内继续点击会将等待提高到 0.2、0.4、0.6 秒，每次从最新点击重新计时。按该武器规则计数恰好为 1、且已达到阈值时，在同一次更新中复核并请求 R，不等待点击或计时；0 发沿用原逻辑。普通测试包的日志版本为 `auto-reload-configurable-fast-one-25327279`，`START` 行还会记录开关状态。
组件 map 以十六进制文本保存在 `data/`，构建时嵌入 Lua；运行时验证完整指纹、资源记录和实体身份。
游戏内还会验证 DLL PE 标识，以及玩家、实体、物品栏、Rounds、Magazine 和 Heat 的已核对指令片段。v5 使用新版 Magazine/Rounds/Heat 全表指纹和定点槽位。

排查空仓附近闪退时可构建 `python scripts/build.py --debug`，产物为
`build/Auto-Reload-configurable-debug.zip`。调试包沿用同一 GUID，应替换普通版并重启游戏。
日志的 `START` 行会显示 `revision=auto-reload-configurable-fast-one-25327279-debug debug=true`；
`DEBUG_SNAPSHOT_*`、`DEBUG_AUTO_STEP_*`、`DEBUG_RELOAD_*` 和 `DEBUG_SENDINPUT_*`
会在接近空仓及请求换弹时记录调用边界。
日志仍位于 `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。

## 测试

安装 LuaJIT 2.1 并将其加入 PATH 后，在仓库根目录运行：

```powershell
python scripts/build.py
python -m unittest discover -s tests -p 'test_*.py'
luajit tests/test_auto_reload.lua
luajit tests/test_auto_reload_maps.lua
luajit tests/test_context.lua
```

Lua 测试模拟内存和输入接口，不向 Windows 或游戏发送实际按键。
按键时序、最后一发膛内子弹、槽位、身份校验、完整静态 map 等均有覆盖。
离线测试不能代替游戏内验证。

参考来源和许可说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。

新版布局和实机字段证据见 [HEAT_LAYOUT_EVIDENCE.md](docs/HEAT_LAYOUT_EVIDENCE.md)。`scripts/read_live_context.lua` 可用只读进程句柄运行实际读取器，不执行 Mod 回调、不发送按键。
