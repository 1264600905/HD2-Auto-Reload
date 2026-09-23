# v0.5.1 — 输入轮询 FFI 修复

适用 Steam build **25327279**，依赖 **Bingus Shared Loader v15+ / API 1**。

- 修复 [#2](https://github.com/1264600905/HD2-Auto-Reload/issues/2)：`GetAsyncKeyState` 的 FFI 声明只在初始化时执行一次，逐帧输入轮询复用已绑定的函数。
- 提供可选的 `Auto-Reload-v0.5.1-debug.zip`。它会在接近空仓、重新读取武器状态和发送 R 的前后刷新诊断日志，帮助定位 [#1](https://github.com/1264600905/HD2-Auto-Reload/issues/1) 报告的闪退。#1 的原因尚未确认，本次发布不宣称已修复该闪退。

正常使用请选择 `Auto-Reload-v0.5.1.zip`。调试包与普通包沿用同一 GUID；只启用其中一份，在 Mod 管理器部署后重启游戏。日志位于 `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/AutoReloadRounds.log`，`START` 行应分别显示 `auto-reload-0.5.1` 或 `auto-reload-0.5.1-debug`。
