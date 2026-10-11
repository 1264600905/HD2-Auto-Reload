# 自动换弹 v0.6.8

安装 `[战术换弹]Auto-Reload-v0.6.8-tactical.zip` 和配套 `Mod-Options-Menu-v1.3.zip`，替换各自旧包，部署并重启游戏。已有战术开关及射击选项保存值沿用；旧换弹延迟保存值被忽略，不需要手动删除设置文件。

| 项目 | 默认 | 行为 |
| --- | --- | --- |
| 战术换弹/Tactical Reload | 战术包开启，普通包关闭；已有保存值优先 | 战术总开关，关闭后仍保留打空自动换弹；原站桩武器及 AC-8 非战术模式仍需空仓后新点击开火 |
| 换弹不阻止开火/Reload Does Not Block Firing | 沿用旧射击选项 | 按用户要求只改名，不控制主动松左键；零延迟下不推迟请求 |
| 逐发换弹武器换弹阈值/Per-round Reload Threshold | 默认/Default | 默认使用原阈值；最后一发/Last Round 使用弹匣加膛内总余弹 ≤1；第一发/First Shot 使用当前弹匣容量减1，打掉第一发后就尝试补弹 |
| AC-8机炮换弹阈值/AC-8 Reload Threshold | 1发战术换弹/Tactical at 1 Round | 弹匣 ≤1、≤5，或不战术换弹/No Tactical Reload；后者只在确认真正打空后的新开火点击请求 |

战术总开关关闭时隐藏三个子选项，保存值保留。菜单显示跟随尚未应用的开关编辑，游戏行为只在 APPLY 后改变。逐发选项只影响现有 `continuous=true` 规则，不影响 AC-8 的整夹装填。

22 个整弹匣武器均改为弹匣 ≤1：AR-2、AR-23、AR-23A、AR-23C、AR-23P、AR-32、AR-59、AR-61、AR/GL-21、BR-14、StA-11、M7S、SMG-203、SMG-32、SMG-37、SMG-72、SMG/FLAM-34、P-2、P-19、M6C/SOCOM、M-105、M-105 MK3。

首次满足条件后立即复核并请求 R。逐发续装保留自有 R 的松键约束；有限失败补发的间隔不是首次换弹延迟。主动松左键始终按 v0.6.7 的非站桩手持武器规则启用，不自动恢复左键按下。

第一发模式读取已经校验的 WeaponRounds 配置 `magazine_capacity` 向量（+0x48/+0x4c），使用当前选择的弹匣，并沿用实体覆盖。字段含义参考[提取的 WeaponRounds 组件定义](https://raw.githubusercontent.com/shalzuth/HelldiversData/master/data/components/WeaponRoundsComponent.json)。容量非有限正整数时跳过提前补弹，保留已确认的空仓处理；没有扩大内存读取链。

控制器、真实菜单保存恢复、条件显示、读取链与打包在游戏自带 LuaJIT 的独立进程中检查，不向游戏发送输入。实机菜单及新阈值仍待用户安装后验证。
