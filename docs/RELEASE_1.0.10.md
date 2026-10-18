# v1.0.10：逐帧开销优化与性能日志

本地安装包：`build/Auto-Reload-v1.0.10.zip`。运行版本：`auto-reload-1.0.10`。开发分支：`perf/auto-reload-v1.0.10`，尚未发布到 GitHub Release。

本版基于已提交的 v1.0.9（`6f79f01`）。原 watchdog 会话只有 3.82 分钟，其中自动换弹平均 58.94 ms/s、最差一分钟 114.18 ms/s、单帧最高 3.14 ms。没有将卡顿归因到自动换弹。本版尚无实机性能结果。

## 修改范围

- 保留前台每帧检测及请求发送前的最新快照，原有判定和输入时序沿用。
- Magazine、Rounds、Heat、Item、ResourceCounter 静态资源映射在加载时预建索引，避免每帧线性扫描、反复格式化资源 ID。
- 完整静态映射和固定组件代码签名最多缓存 1 秒，模块/上下文/映射地址变化时重新复核；当前选中映射条目、有效配置、组件注册身份、武器、玩家、背包及弹量继续每次读取、回读验证。不缓存动态指针来直接解引用。
- ReadProcessMemory 仍保留地址、长度、读取成功与字节数检查，复用固定缓冲区，每次结果立即复制成独立 Lua 字符串；身份守卫改为平行数组。
- 原生切枪动作 19/20/22/23/24/29/30 在一次连续读取中检查，输入边界仍重新读取；输入探测复用合并 FIRE 结果。关闭详细日志时跳过 RMB/F8 诊断和 Rounds 配置 hex。
- 日志每秒统一刷新，关闭日志开关及正常 shutdown 时刷新尾部；异常终止可能丢失最后一小段尚未刷新的输出。

静态索引会增加少量常驻 Lua 内存，换取逐帧查找和分配减少。本版保留原随机等待分布、阈值、半秒开火保护、重试间隔、站桩触发、无备弹停止及切枪取消规则。

## 安装与日志

在管理器中替换旧 Auto Reload，只启用一份，部署后重启游戏。沿用原 GUID 和已有设置 ID，Bingus Shared Loader 与 Mod Options Menu 依赖沿用。

日志文件：`%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`。

游戏内进入 `MODS → 自动换弹/Auto Reload`：

1. 关闭 **日志打印/Logging**，避免详细输入诊断影响性能统计。
2. 开启新增 **性能统计/Performance Logging** 并 APPLY。看到 `PERF_ENABLED revision=auto-reload-1.0.10` 后，每 5 秒输出一组统计；正常退出或关闭该开关时也会输出不足 5 秒的尾部。
3. 若排查换弹行为，另开详细日志；切枪取消的既有诊断仍保留。单独切换日志或性能开关不会取消待换弹请求。

两个日志开关默认都关闭。不开性能统计时不进行分段计时或统计读取计数。

## 性能字段

`PERF_SUMMARY` 的主要字段：

| 字段 | 含义 |
|---|---|
| `revision` / `timer` | 包版本；正常为 `qpc` 高精度时钟，初始化不可用时为 `clock` |
| `window_s` / `updates` | 本次统计实际时长与自身 update 次数 |
| `self_ms_per_s` | 本模组自身 update 累计耗时除以窗口秒数，不含被串联的原 update 和汇总日志输出 |
| `avg_update_ms` / `worst_update_ms` | 当前窗口的单次自身 update 平均值/最大值 |
| `reads_per_s` / `bytes_per_s` | ReadProcessMemory 调用次数/请求字节数，包括输入与身份回读 |
| `map_checks` / `map_hits` | 整表复核次数/复用校验结果次数；单位是本窗口次数 |
| `layout_checks` | 本窗口发起的组件代码布局校验次数 |
| `context_failures` | 外层完整快照读取失败次数，不含等待人物等正常状态或内部可选读取器降级 |
| `detailed_logging` | 是否同时启用了详细日志；比较开销时应为 `false` |
| `context_status` / `resource` | 窗口结束时最新上下文和武器资源，辅助区分飞船、战斗等状态 |

`PERF_STAGES` 给出 `options`、`input`、`context`、`static`、`control` 的调用次数、ms/s 和单次最大耗时。`static` 包含在 `context` 中；实际触发输入时，额外的 `context` 也包含在 `control` 中，因此不能把各阶段直接相加。计时覆盖错误返回的外层快照。开启统计本身有少量开销，最终仍结合 watchdog 报告比较。

## 用户实测

开发阶段按要求只检查完整 Lua 语法、ZIP 完整性、manifest、包内脚本一致性和版本，没有运行行为测试或启动/读取游戏。建议保留 v1.0.9 方便对比：

- 使用相同模组、设置及类似武器/场景，对比至少数分钟的 watchdog；比较 `ms_per_s`、最差分钟和单帧峰值。
- 新版可先只开性能统计收集分段日志；公平比较两版 watchdog 时，将两版日志开关均关闭。
- 顺便观察普通/逐发换弹、备弹耗尽和切枪取消，保留 v1.0.9 已确认的行为。

发现问题时提供新版 watchdog 和相应的 AutoReloadRounds.log，结合版本、资源和时间窗口定位。当前没有实机验证，不能承诺具体降耗比例。
