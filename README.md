# HD2 Auto Reload

![HD2 Auto Reload mod cover](HD2-Auto-Reload-cover.png)

Helldivers 2 自动换弹 Mod，依赖 **Bingus Shared Loader v15+ / API 1**。
本仓库独立维护自动换弹源码、打包工具和测试，不包含 Loader 或其他 Mod 项目。

## 功能与状态

- 空仓等待 **1 秒**后请求换弹；继续攻击也能触发。
- 支持 WeaponRounds 与 WeaponMagazine，覆盖主手、副武器、支援武器槽位。
- 使用弹匣/逐发弹药系统的能量武器走同一逻辑，不按武器外观过滤。
- **散热型激光/能量武器（WeaponHeat）**：确认散热器烧毁并锁定 1 秒后请求 R；持续开火也等待满 1 秒。正常升温、充能和可自行恢复的冷却锁定不触发。
- 仅只读检查武器状态并模拟 R，不改弹药、不写游戏内存、不调用游戏函数。
- 备用弹药不足、原生动作限制等交给游戏处理。默认换弹键须为 R。

v5 已获用户实机反馈：功能测试通过，能量武器也能自动换弹。激光大炮另已只读验证未过热 → 过热锁定 → 换散热器后解锁及备用数量减少。此反馈不代表所有武器和场景均已覆盖。
支持的游戏版本固定为 Steam build `25327279`，更新游戏后需重新验证。

## 安装与测试

从 [v0.5.0 Release](https://github.com/1264600905/HD2-Auto-Reload/releases/tag/v0.5.0) 下载 `Auto-Reload-v5.zip`，或在本地构建。旧版 v4 不支持此次游戏更新。
在现用 Mod 管理器中替换旧 Auto Reload，保持只启用一份，再与 Bingus Shared Loader 一起部署。
新版本沿用旧版 GUID，所以应替换旧包，不应并行安装。

普通武器带足备用弹药，测试打空后等待 1 秒，以及继续攻击的触发方式。
能量武器测试：装备激光大炮等有可更换散热器的武器，射击至过热，观察约 1 秒后是否自动请求换弹；也测试持续按住攻击的情况。
普通冷却过程中不应按 R。换槽位、手动按 R、失去游戏焦点均须取消旧武器的待发送请求。
替换部署后需重启游戏，已运行的 Lua 不会因替换 zip 自动刷新。
资源 `11c27d3babb38956` 曾被报告装备后崩溃，始终跳过，不要用于测试。

日志位置：`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。
版本行应含 `revision=auto-reload-5`。输入被系统接受不等于游戏完成换弹，日志会区分请求、弹药恢复与未确认结果。
不要将完整个人运行日志、游戏 DLL 或内存转储提交到本仓库。

## 构建

Python 3.10+，仅使用标准库，无需下载或安装其他项目：

```powershell
python scripts/build.py
# 可选：对本地游戏执行完整 SHA256 校验
python scripts/build.py --game-dir '你的 Steam 游戏目录/Helldivers 2'
```

产物为 `build/Auto-Reload-v5.zip`。`build/` 不纳入源码提交。
组件 map 以十六进制文本保存在 `data/`，构建时嵌入 Lua；运行时验证完整指纹、资源记录和实体身份。
游戏内还会验证 DLL PE 标识，以及玩家、实体、物品栏、Rounds、Magazine 和 Heat 的已核对指令片段。v5 使用新版 Magazine/Rounds/Heat 全表指纹和定点槽位。

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
