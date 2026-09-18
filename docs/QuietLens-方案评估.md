# QuietLens 技术方案评估（对比 PrivacyWindow）

评估对象：[QuietLens](https://github.com/…)（本地仓库 `/Users/yinheng/Documents/GitHub/QuietLens`）
评估日期：2026-09-18 · macOS 26 · 基于两边源码逐文件阅读，非推测

---

## 0. 一句话结论

**QuietLens 的方案是成立的，而且在它的产品定位（专注 / 氛围美化）上是最优解；但把它平移到我们的定位（隐私遮蔽）上不够用。**

核心分野只有一句话：

> 它的模糊是**系统合成器给的**（`NSVisualEffectView`），我们的模糊是**我们自己算的**（ScreenCaptureKit + `CIGaussianBlur`）。

这一个选择往下决定了权限、可调性、功耗、隐私、可维护性全部五项。系统给的模糊便宜、实时、零权限，但你只能从系统预设的几档材质里挑，改不动；自己算的模糊贵、要权限、有延迟，但半径是连续可调的真实高斯，能做 inpainting、能把窗口精确排除在画面之外。

对"专注工具"来说前者足够；对"隐私工具"来说，"够不够糊"是这个产品唯一的承诺，交出去给系统材质决定是不行的。

---

## 1. 两套方案的技术骨架

### QuietLens

| 环节 | 实现 | 文件 |
| --- | --- | --- |
| 模糊 | `NSVisualEffectView(blendingMode: .behindWindow)`，材质四档切换 | `Overlay/BlurOverlayView.swift` |
| 强度控制 | `blurRadius` 0–50 滑块 → `switch` 映射到 4 个 `Material` | 同上 L75–80 |
| 焦点窗口 | Accessibility：`AXUIElementCreateApplication` + `kAXFocusedWindowAttribute` | `Core/WindowTracker.swift` |
| 露出方式 | 两个叠加：① overlay 上 even-odd 掩膜开洞；② **私有 CGS API 把焦点窗口抬到 screenSaver 层级** | `Overlay/CutoutView.swift` + `Core/WindowRaiser.swift` |
| 窗口层级 | overlay 在 `screenSaverWindow - 1` | `Overlay/OverlayWindow.swift` L16 |
| 菜单栏 / Dock | **缩小 overlay 的 frame** 绕开（按 `visibleFrame` 差值裁剪四个边） | `Core/OverlayManager.swift` L188–215 |
| 权限 | 仅 `NSAccessibilityUsageDescription` | `Resources/Info.plist` |

### PrivacyWindow

| 环节 | 实现 | 文件 |
| --- | --- | --- |
| 模糊 | `SCScreenshotManager` 截屏 → `CIGaussianBlur`，真实半径 | `ScreenCapturer.swift` + `BlurProcessor.swift` |
| 强度控制 | 连续半径 5–60 pt，钳制后直接进入 CI 滤波器 | `PrivacyController.swift` |
| 焦点窗口 | `CGWindowListCopyWindowInfo` + 分层启发式（无 AX） | `FocusTracker.swift` |
| 露出方式 | 截屏时**按 windowID 排除**焦点窗口 + 掩膜开洞 + 洞内先 inpainting 再模糊 | `ScreenCapturer.swift` + `BlurProcessor.swift` |
| 窗口层级 | `shieldsPresent` 级（chrome 清晰时降级） | `BlurOverlay.swift` |
| 菜单栏 / Dock | 截屏时按 bundleID / 几何排除，overlay 仍是整屏 | `ScreenCapturer.swift` L276–298 |
| 权限 | 屏幕录制（`NSScreenCaptureUsageDescription`） | `Resources/Info.plist` |

---

## 2. 逐项对比

| 维度 | QuietLens（合成器） | PrivacyWindow（SCK） | 谁赢 |
| --- | --- | --- | --- |
| 权限成本 | 辅助功能（AX） | 屏幕录制 | 平手（都是 TCC，都要用户手动勾） |
| 权限副作用 | AX 等于"允许控制你的 UI"，敏感度高 | 屏幕录制授权后**必须重启 app**，且重签名就失效 | QuietLens |
| 模糊强度上限 | 被系统 4 档材质封顶 | 无上限，半径 5–60 连续 | **我们** |
| 强度是否跨版本稳定 | 否，材质观感随 macOS 版本变 | 是，自己算的 | **我们** |
| 模糊实时性 | **同帧**，合成器直接采样 | 滞后 1–3 帧（截屏固有） | QuietLens |
| CPU / GPU 开销 | 接近零（WindowServer 干） | 持续：截屏 + 降采样 + CI 卷积 | QuietLens |
| 隐私（自身） | 完全不接触像素，不可能泄露 | 每帧持有整屏位图 | QuietLens |
| 排除特定窗口 | 做不到（只能几何规避 / 开洞） | 按 windowID 精确排除 | **我们** |
| 防光晕 | 洞是硬边，洞外材质模糊，无晕开问题 | 需要 inpainting，已做 | 平手 |
| 鼠标圆盘 | 做不到（洞里是下层真实像素，在非焦点区开洞 = 泄露） | 已实现 | **我们** |
| 菜单栏 / Dock 保留清晰 | 缩小 frame 绕开，依赖 `visibleFrame` 差值 | 截屏时排除，frame 不动 | **我们**（更稳） |
| 多显示器 | 支持，每屏一个窗口 | 支持，每屏一个窗口 | 平手 |
| 焦点窗口识别精度 | AX 精确，但对 Electron / Java / 游戏 / 无 AX 支持的 app 拿不到 | 启发式，对所有 app 一视同仁，偶尔挑错 | 各有优劣 |
| 私有 API | **用了 `CGSSetWindowLevel` / `CGSMainConnectionID`** | 无 | **我们** |
| 上架 Mac App Store | 用私有符号，基本不可能过审 | 全公开 API | **我们** |
| macOS 升级风险 | 私有符号消失 → **dyld 链接失败，启动即崩** | 无 | **我们** |

---

## 3. 几个关键点的深入判断

### 3.1 "模糊半径 0–50" 是假的

QuietLens 有一个 0–50 的滑块，看起来连续可调，实际落点是：

```swift
switch radius {
case ..<10: effect.material = .hudWindow
case ..<25: effect.material = .underWindowBackground
case ..<40: effect.material = .fullScreenUI
default:    effect.material = .menu
}
```

四档，而且每档到底多糊由系统决定。这不是他们的偷懒——`NSVisualEffectView` 只暴露 `material` 和 `alphaValue`，**没有任何 API 能设定高斯半径**。这是这条路线的硬天花板。

对我们的产品来说这是致命的：隐私工具的全部价值是"别人看不清"。而"看不清"是一个可以客观检验的标准（字号 × 模糊半径），把它交给系统材质意味着我们无法给出、也无法保证这个承诺。

### 3.2 私有 API 是最重的一笔技术债

`WindowRaiser` 用 `@_silgen_name` 直接链接了两个未公开的符号：

```swift
@_silgen_name("CGSMainConnectionID")  private func _CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetWindowLevel")    private func _CGSSetWindowLevel(...) -> Int32
```

然后把**属于其他 app 的窗口**抬到 screenSaver 层级。三个问题：

1. **链接期风险**：`@_silgen_name` 是硬符号绑定，macOS 哪天把 `CGSSetWindowLevel` 改名或收进私有框架，dyld 在启动阶段就失败——不是"功能不可用"，是**app 打不开**。
2. **状态风险**：改了别人窗口的层级，就得负责改回来。他们写了 `clearAll()` 兜底，但我们进程被 `kill -9`、或者系统休眠唤醒时序不对时，会留下一个永远浮在 screenSaver 层的窗口。
3. **分发风险**：私有符号 = 与 Mac App Store 无缘。

顺带一提：既然窗口已经被抬到 overlay 之上，`CutoutView` 的洞其实是多余的（双保险，可能是历史遗留）。也就是说这条路线上，**真正起作用的机制是改别人的窗口**，这比"我们只画自己的东西"要侵入得多。

### 3.3 我们的路线要诚实承认的三个劣势

评估不能只挑对自己有利的：

1. **滞后**。截屏-模糊-上屏这条链路必然落后真实桌面 1–3 帧。窗口被拖动时，洞是实时的（真窗口透出来），洞外的模糊背景是旧的，会有一帧级的错位。QuietLens 完全没有这个问题——合成器采样就是同帧的。我们做了 inpainting 解决了"光晕闪烁"，但滞后本身在 SCK 路线上无法根除，只能靠降采样和帧率调度压低。
2. **功耗**。无论怎么优化，每帧都在做截屏 + 卷积。我们的降采样（目标宽 1600px）和失败退避已经把开销压到很低，但不会是零。QuietLens 是零。
3. **自身的隐私姿态**。"隐私工具每帧持有你的整屏画面"这件事本身是有张力的。我们不落盘、不上传、不跨进程，但屏幕录制权限一旦给了，这个二进制就有能力看一切。这是 SCK 路线无法辩解的成本，只能靠开源 + 权限最小化来交代。

### 3.4 焦点窗口：AX vs CGWindowList

QuietLens 用 AX，精确，但**依赖目标 app 自己实现无障碍**。Electron 打包的应用（VS Code、Slack、Notion、飞书）、Java Swing、Unity 游戏、部分原生 app 的 AX 树是残缺的，`kAXFocusedWindowAttribute` 会拿不到或拿到错的窗口——而拿不到焦点 = 整个功能失效。

我们用 `CGWindowListCopyWindowInfo`，不需要任何权限，对所有 app 一视同仁（读的是窗口服务器的事实，不是 app 自己上报的）。代价是它是启发式：我们已经固化了实测证据（Dock 的窗口矩形是整屏 layer 20、菜单栏 layer 24 且 `excludeDesktopElements` 不排除它、桌面宠物在 layer 3），据此设计了分层挑选策略。偶尔会挑错，但**不会失效**。

对隐私工具来说"偶尔挑错但永远工作"优于"精确但可能不工作"。这一条我们选对了。

### 3.5 鼠标圆盘：两条路线的含义完全不同

这是最能说明差异的一个功能。

- 我们的圆盘 = **在模糊图上挖一个洞**，洞里是真实的桌面（焦点窗口区域本来就是真的，非焦点区域则露出下层真实内容）。

  等等——那不就是泄露吗？不是：我们的洞只在焦点窗口的语义下有意义，且半径由用户控制。圆盘落在非焦点窗口上时，确实会露出那块真实内容，这是**设计取舍**（用户主动要求的"光标周围保持清晰"），文档里要说清楚。

- QuietLens 若要做同样的事 = 在 overlay 上开一个圆洞，洞里露出**下层真实像素**。在非焦点区域开洞，露出的就是那个区域真实的内容——微信、邮件、什么都可能是。同样是"露出真实内容"，但他们的模糊是系统材质，无法在"洞的边界"做任何过渡或遮罩处理，只能硬边。

结论不是"他们做不到"，而是：**在他们那条路线上，"清晰"永远是"露出真实桌面"，没有任何中间态**；而我们可以做"半清晰"（局部降低半径、加遮罩、做渐变过渡）。这是有像素和无像素的根本差别。

---

## 4. 可行性判定

### QuietLens 方案本身：可行，且是它定位下的正解

- 技术上完全跑得通，已经交付了可用产品。
- 权限只要一项（AX），体验成本低。
- 零功耗、同帧、不碰像素——对"专注 / 氛围"这个目标，这三个属性比"模糊半径精确可调"重要得多。
- 真正的风险不在技术能不能跑，而在**私有 API 的长期维护**和**无法上架**。

### 平移到 PrivacyWindow：不可行（作为主路线）

卡在两点，且都不可绕过：

1. **强度不可控**——隐私工具的核心承诺交不出去。
2. **无法排除特定窗口**——只能几何开洞。焦点窗口一多、一重叠、一跨屏，几何规避就会漏。

### 作为降级路径：可行，而且很值得做

这是本次评估最有价值的产出。

注意一个事实：**我们现在的"露出焦点窗口"，视觉上就是 overlay 上开个洞，洞里是真窗口。** 如果换成 `NSVisualEffectView`，洞还是那个洞，真窗口还是那个真窗口——**用户看到的画面几乎一样**，只是洞外的模糊从"我们的高斯"变成"系统材质"。

也就是说：

> 把模糊后端抽象成一个协议，SCK 与 Vibrancy 两种实现共用同一套"洞 / 焦点 / 层级 / 生命周期"逻辑，是完全可行的。

带来的收益：

| 场景 | 现状 | 有 Vibrancy 后端后 |
| --- | --- | --- |
| 用户未授权屏幕录制 | app 基本没用，只能引导去设置 | **开箱即用**（零权限立刻看到效果），授权后再无缝切到高质量 |
| 省电档位最高档 | 降帧率，仍有截屏开销 | **真正的零 CPU**——合成器静态模糊 |
| 低电量 / 高温降频 | 卡顿 | 自动降级到 Vibrancy，功能不中断 |
| 屏幕录制被企业策略禁用 | 完全不可用 | 仍可用 |

实现要点（如果决定做）：

1. `protocol BlurBackend { func makeView(...) -> NSView; func apply(radius:...) }`，两个实现：`SCKBlurBackend`（现状）、`VibrancyBackend`（`NSVisualEffectView` + 同一份掩膜）。
2. 半径映射：`VibrancyBackend` 内部把 5–60 映射到 4 档材质 + `alphaValue` 微调，UI 上标注"降级模式：模糊强度由系统决定"。
3. 降级模式**不做** inpainting（没有像素可处理），洞边直接硬边 + 描边。
4. 切换时机：权限状态变化、用户在设置里手动切、系统进入低电量模式。
5. 只共用 `NSVisualEffectView`，**绝不要**碰 `CGSSetWindowLevel`。

---

## 5. 该从 QuietLens 借鉴的（已做 / 待做）

**已借鉴：**

- 设置模块的形态：侧边栏分页 + 全标签搜索 + 玻璃质感组件（本轮已实现，见 `Sources/PrivacyCore/Settings/`）。

**值得再借鉴：**

1. **无权限时的降级路径**（第 4 节）——最高优先级。
2. **排除应用规则**（`ExcludedApp` / `pinnedBundleIDs`）：用户可以指定"某几个 app 永远不被模糊 / 永远保持清晰"。这是隐私工具真实需要的功能（比如"我的终端永远清晰"）。
3. **拖动检测的细节判断**：他们只在"鼠标按下 **且** 收到 AX 几何变化通知"时才隐藏 overlay，理由是"只在左键拖动时隐藏，会让用户在焦点窗口里做文本选择时一直闪"。这类踩坑经验值得记住——我们的持续更新路线没有这个问题，但将来若加"拖动时暂停"要照抄这个条件。
4. **淡入淡出的实现坑**：他们在 `fadeIn`/`fadeOut` 的注释里记录了两个真实 bug——`NSAnimationContext` 在 `LSUIElement` app 里不 tick（要改用 `CABasicAnimation`）、`fadeOut` 的 `fillMode=.forwards` 残留会盖掉下一次 `fadeIn`。我们若做动画，直接抄结论。
5. **状态单一出口**：`OverlayManager.onEnabledChanged` 让菜单 / 快捷键 / 摇晃 / URL 自动化触发的状态变化都从一处同步。我们已有类似结构，可以再收拢一下。

**不该借鉴：**

1. `CGSSetWindowLevel` 私有 API（理由见 3.2）。
2. 用四档材质假装连续半径——那是被逼的，我们不该主动复刻这个 UX。
3. 大量视觉特效层（`grain` 噪点、`breathing`/`pulse`/`drift` 动画、`shader` 模式）。对氛围工具是卖点，对隐私工具是负担：分散注意力、白吃 GPU、而且和"隐形、不打扰"的定位冲突。

---

## 6. 结论

- **保持 ScreenCaptureKit 主路线**。它换来的是"模糊强度可控"和"窗口可精确排除"，这两项是隐私工具区别于氛围工具的全部。
- **补一条 Vibrancy 降级路线**，解决"未授权即不可用"和"省电档只能降帧"两个体验缺口。这是从 QuietLens 身上能拿到的最大价值，而且不需要接受它的私有 API 债。
- **不引入 Accessibility**。我们用 `CGWindowListCopyWindowInfo` 就够了，多要一项权限换来的精确度不值这个成本。
- **不引入 CGS 私有符号**。
