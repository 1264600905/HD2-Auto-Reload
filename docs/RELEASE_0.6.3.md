# v0.6.3 — 模拟 R 换弹主干版

支持 Steam build `25327279`、`25480438`，依赖 **Bingus Shared Loader v15+ / API 1**。本版仅只读检查武器状态并模拟 R；原生换弹开发与实机测试在 `native-test` 分支维护。

## 本版修复

- 适配 Steam build `25480438`，保留 `25327279` 兼容检查；已只读核对关键指令和 Magazine/Rounds/Heat 完整组件表。
- 修复独立加载时 `SendInput` 缺少 FFI 声明导致初始化失败，兼容其他 Mod 已有的不同指针声明。
- 保留空仓即时换弹、烧毁散热器更换、已有战术阈值与输入时序修复。
- 安装包名称统一添加中文前缀：普通版为 `[普通换弹]`，战术版为 `[战术换弹]`；原有英文名称、版本及诊断后缀继续保留。

## 下载与安装

| 安装包 | 用途 |
| --- | --- |
| `[战术换弹]Auto-Reload-v0.6.3-tactical.zip` | 推荐：启用武器配置与战术阈值 |
| `[普通换弹]Auto-Reload-v0.6.3.zip` | 仅普通空仓换弹 |
| `[战术换弹]Auto-Reload-v0.6.3-tactical-debug.zip` | 战术版，附详细诊断日志 |
| `[普通换弹]Auto-Reload-v0.6.3-debug.zip` | 普通版，附详细诊断日志 |

从 [v0.6.3 Release](https://github.com/1264600905/HD2-Auto-Reload/releases/tag/v0.6.3) 下载所需安装包。四个包沿用同一 Mod GUID，只能启用一份。关闭游戏，在 Mod 管理器中替换旧包，与 Loader 一起重新部署后重启游戏。换弹键须为 R。

日志位置：`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。`START` 行应含 `revision=auto-reload-0.6.3`，诊断包另含 `-debug`；战术版应记录 `tactical_reload=true reload_delay=0`。

## 验证与限制

已通过 51 项行为测试，以及组件映射、读取链、两种 Windows 输入 API 初始化场景和 Python 打包检查；四个 ZIP 均完成版本与内容核对。离线测试不能代替游戏内验证，系统接受按键也不代表游戏完成换弹。

MG-43 历史装备崩溃报告尚未确认原因，保留此前试验性读取与空仓后重新点击射击的规则。游戏动作限制及备用弹药仍由游戏处理。原生 v0.7.0 实验包的验证范围不适用于本版。
