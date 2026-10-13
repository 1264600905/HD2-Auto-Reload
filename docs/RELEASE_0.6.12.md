# v0.6.12：坦克炮手与乘客换弹修复

## 问题和修复

旧读取器只允许 `role=4`（Pilot），这是此前单人载具模组的操作状态。原生坦克炮手使用 `role=2`（Gunner），因此在读取弹药前就返回 `vehicle_role_unsupported`。本版允许原生炮手使用现有已核对载具武器规则：堡垒、风暴漩涡主炮打空换弹，突破沿用原有逐发阈值。载具类型、座位、武器资源和弹药路径限制仍保留。

乘客位使用 `role=3`，同样被原角色限制排除。此外，原实现用四字节读取 Seater `+0x30`，把相邻 `+0x31` 的独立标志也算入过渡判断；稳定乘客位的 `00 01 00 00` 因而被误判为正在换座。游戏原生指令 `game.dll+0xA7E7DA` 对 `+0x30` 使用单字节比较，乘客路径 `0xA7EB98` 单独读取 `+0x31`。

本版分别读取两个标志，仅 `+0x30` 非零时跳过过渡。乘客武器从本地人物 Wieldable 主槽位解析，匹配原生乘客当前武器查询 `0xA7EBD7..0xA7EBEF`，避免使用已过期的物品栏选择。上下文标记为 `vehicle_passenger`，沿用该手持武器的普通空仓、战术阈值、逐发开火优先、定期复查与爆裂铳拉栓规则。

座位、两个标志和 Wieldable 选择均在快照结束时复读，并在发送输入前再次核对。驾驶员 `role=1`、未知角色、未支持载具主炮和真正的换座/上下车过渡继续跳过。原生炮手仍不注入主动松开火；乘客手持武器沿用步行时的输入规则。

## 当前游戏的只读证据

2026-10-13，build `25480438`，用户先停留在打空主炮的堡垒炮手位，再切到乘客位，最后返回炮手位。采集器只使用外部只读进程句柄，不安装回调、不写内存、不发送按键。

| 场景 | 实际座位 | 旧读取器 | 新读取器 |
| --- | --- | --- | --- |
| TD-220 堡垒主炮 | 类型 `0x2B`，座位 1，`role=2` | `vehicle_role_unsupported`，未读取主炮 | `context_observed`，资源 `1fa1f596769225c2`，弹匣 0，膛内 0 |
| 乘客当前手持武器 | 类型 `0x1A`，座位 1，`role=3` | `vehicle_seat_transition`；旧四字节值为 256 | `context_observed`，资源 `80f1a156d9fa1e36`，弹匣 0，膛内 0 |

当前加载模块还核对了原生乘客 Wieldable 查询与 Seater 字节判断指令。只读样本说明新读取链已能把正确的空仓状态交给原有换弹控制器；不代表新安装包已经在游戏中实际发送 R 并完成换弹。风暴漩涡原生炮手、其他乘客武器及乘客爆裂铳未在本次会话逐一确认。

采样和局部指令输出保留在本地 `build/`：`tank-context-before-v0.6.12.log`、`tank-context-after-v0.6.12.log`、`passenger-context-before-v0.6.12.log`、`passenger-context-after-v0.6.12.log`、`passenger-input-v0.6.12.txt`。个人完整日志、游戏 DLL 和内存转储不提交。

## 安装和诊断

安装包为 `build/Auto-Reload-v0.6.12.zip`，GUID 沿用旧版本。替换旧自动换弹包、部署并重启游戏，保持只启用一份。依赖 Bingus Shared Loader v18+ / API 1；设置菜单仍单独安装 Mod Options Menu API 1。原有四档定期检查和全部保存值沿用。

开启日志后版本应含 `revision=auto-reload-0.6.12`。`CTX` 新增 `seat_transition` 和 `seat_passenger_flag`，乘客上下文显示 `weapon_context=vehicle_passenger`、`slot=passenger_primary`；坦克炮手显示 `weapon_context=vehicle`、`seat_role=2`。空仓时应出现 `RELOAD_REQUEST`，随后弹药恢复记录用于确认读取状态的变化。

构建命令：`python scripts/build.py`。沿用用户此前的效率要求，本次未运行测试套件，仅完成所要求的当前游戏只读诊断和修复后状态采集。
