# HD2 Auto Reload

Helldivers 2 自动换弹 Mod，依赖 **Bingus Shared Loader v15+ / API 1**。
本仓库独立维护自动换弹源码、打包工具和测试，不包含 Loader 或其他 Mod 项目。

## 功能与状态

- 空仓等待 **1 秒**后请求换弹；继续攻击也能触发。
- 支持 WeaponRounds 与 WeaponMagazine，覆盖主手、副武器、支援武器槽位。
- 使用弹匣/逐发弹药系统的能量武器走同一逻辑，不按武器外观过滤。
- **散热型激光/能量武器（WeaponHeat）尚未完成自动换弹**：v4 收集定点只读诊断，待验证过热字段后启用。不能把散热等待或正常充能当作空仓。
- 仅只读检查武器状态并模拟 R，不改弹药、不写游戏内存、不调用游戏函数。
- 备用弹药不足、原生动作限制等交给游戏处理。默认换弹键须为 R。

当前为测试版本。v2 WeaponRounds 已有用户实机成功反馈；Magazine 分支已实现并通过离线检查，仍需持续实机确认。
支持的游戏版本固定为 Steam build `24826606`，更新游戏后需重新验证。

## 安装与测试

从 [Releases](https://github.com/1264600905/HD2-Auto-Reload/releases) 下载 `Auto-Reload-v4.zip`。
在现用 Mod 管理器中替换旧 Auto Reload，保持只启用一份，再与 Bingus Shared Loader 一起部署。
新版本沿用旧版 GUID，所以应替换旧包，不应并行安装。

普通武器带足备用弹药，测试打空后等待 1 秒，以及继续攻击的触发方式。
本次能量武器测试请使用原本计划测试的散热型武器：射击至过热、等待、再手动 R 更换散热器。
**本版不会自动对未验证的 Heat 状态按 R**；测试日志用于下一步实现该分支。
资源 `11c27d3babb38956` 曾被报告装备后崩溃，始终跳过，不要用于测试。

日志位置：`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。
版本行应含 `revision=auto-reload-4`。输入被系统接受不等于游戏完成换弹，日志会区分请求、弹药恢复与未确认结果。
不要将完整个人运行日志、游戏 DLL 或内存转储提交到本仓库。

## 构建

Python 3.10+，仅使用标准库，无需下载或安装其他项目：

```powershell
python scripts/build.py
# 可选：对本地游戏执行完整 SHA256 校验
python scripts/build.py --game-dir '你的 Steam 游戏目录/Helldivers 2'
```

产物为 `build/Auto-Reload-v4.zip`。`build/` 不纳入源码提交。
组件 map 以十六进制文本保存在 `data/`，构建时嵌入 Lua；运行时验证完整指纹、资源记录和实体身份。
游戏内还会验证 DLL PE 标识和已知 Magazine 指令片段。

## 测试

安装 LuaJIT 2.1 并将其加入 PATH 后，在仓库根目录运行：

```powershell
python scripts/build.py
python -m unittest discover -s tests -p 'test_*.py'
luajit tests/test_auto_reload.lua
luajit tests/test_auto_reload_maps.lua
```

Lua 测试模拟内存和输入接口，不向 Windows 或游戏发送实际按键。
按键时序、最后一发膛内子弹、槽位、身份校验、完整静态 map 等均有覆盖。
离线测试不能代替游戏内验证。

参考来源和许可说明见 [THIRD_PARTY.md](THIRD_PARTY.md)。
