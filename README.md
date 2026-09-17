# 隐私窗口 (PrivacyWindow)

一个常驻菜单栏的 macOS 小工具：**只让当前焦点窗口保持清晰，其余所有背景全部高斯模糊**。

效果类似 HazeOver，但用「模糊」而不是「变暗」——打开后，屏幕上除你正在用的那个窗口之外的一切（其他窗口、菜单栏、桌面）都会被实时模糊盖住，只有焦点窗口透过透明挖洞露出来，并且仍然可点击、可交互。

## 原理

- 用 **ScreenCaptureKit** 周期性（每 ~0.2s）对所有屏幕截图，并排除本 app 自身的窗口，避免覆盖层自己被拍进去。
- 每张截图用 `CIGaussianBlur` 做高斯模糊。
- 用一个置顶、透明、不接收鼠标事件的 `NSWindow` 覆盖整屏显示模糊图。
- 用 `CGWindowListCopyWindowInfo` 找到当前最前应用的最上层窗口，在覆盖层上以 **even-odd 路径挖一个透明矩形洞**，让真实的焦点窗口透出来。
- 焦点窗口移动/缩放时，洞随之更新；焦点切到别的屏时，洞跟着切到对应屏幕。

## 构建与运行

需要 macOS 14+ 与 Xcode 命令行工具。

```bash
./build.sh --run      # 编译、签名并启动
```

首次点击菜单栏「启用隐私模糊」时，macOS 会弹出 **屏幕录制** 权限请求，允许后才会生效（重新编译后可能需再次授权）。

## 使用

菜单栏图标（眼睛带斜杠）点开后：

- **启用 / 停用隐私模糊**：开关效果。
- **模糊强度**：轻度 / 中度 / 强度（对应模糊半径 10 / 20 / 40 pt）。
- **退出**。

## 说明 / 已知取舍

- 模糊是**视觉层面**的：覆盖层不拦截鼠标，因此模糊区域背后的窗口其实仍可点击（和 HazeOver 一致）。如果你需要「背景完全不可交互」，需要让覆盖层接收事件，但这会同时挡住焦点窗口的点击——本版本选择保持焦点窗口可交互。
- 多显示器：每张屏幕各有一层覆盖；焦点窗口在哪张屏，洞就挖在哪张屏，其余屏整体模糊。
- 截图刷新率约 5fps，背景里的视频会略显迟滞，这是为省 CPU 的取舍。

## 代码结构

```
Sources/
  main.swift             // 入口，启动 NSApplication
  AppDelegate.swift      // 应用代理，挂菜单栏控制器
  StatusItemController.swift  // 菜单栏图标与菜单
  PrivacyController.swift     // 总控：多屏覆盖 + 定时刷新 + 焦点洞
  FocusTracker.swift          // 找焦点窗口矩形（CGWindowList）
  ScreenCapturer.swift        // 单屏截图（ScreenCaptureKit，排除自身）
  BlurOverlay.swift           // 单屏模糊覆盖窗口 + 透明挖洞
  CoordinateConverter.swift   // 坐标系互转 + NSScreen.displayID
```
