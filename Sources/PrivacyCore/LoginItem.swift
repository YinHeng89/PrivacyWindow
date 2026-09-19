import AppKit
import Foundation
import ServiceManagement

/// 开机 / 登录自启。
///
/// macOS 用 Apple 官方 `SMAppService.mainApp`（登录项，macOS 13+）：注册后应用
/// 出现在「系统设置 › 通用 › 登录项」中，用户可直观开关，也最稳定，且能被系统
/// 管理。参考 desktop-pet_live2d 的同款方案（它也是常驻后台的应用，自启逻辑一致）。
///
/// 要点与坑：
/// - `SMAppService` 要求应用是已打包的 `.app`（位于 /Applications 或任意有效
///   bundle 路径）。开发态（`swift build` 的裸二进制、`swift test`、XCTest）没有
///   `.app` 外壳，注册会失败——此时 `canRegister` 为 false，模块静默降级，真正的
///   注册留到从打包好的 `.app` 运行时发生。
/// - 注册是**幂等**的：已经注册时再 `register()` 会抛 `alreadyRegistered`，所以
///   `apply` 在动手前先读 `isRegistered`，避免无谓的报错。
/// - 应用被移动 / 重装到不同路径后，旧的登录项会指向失效位置：启动时 `reconcile`
///   按用户偏好重新注册到当前 `.app`，实现自愈。
enum LoginItem {
    /// 应用是否位于 `.app` bundle 内——`SMAppService` 能注册的前提。
    ///
    /// `swift build` 产出的裸二进制在 `build/.../PrivacyWindow`（无 `.app` 后缀），
    /// 这种情况直接判为不可注册；`build.sh` 打包出的 `build/PrivacyWindow.app` 与
    /// 安装到 /Applications 的副本都算可注册。
    static var canRegister: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// 当前是否已注册为登录项（`enabled` 或 `requiresApproval` 均视为已注册）。
    static var isRegistered: Bool {
        guard #available(macOS 13, *), canRegister else { return false }
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// 注册 / 注销登录项。非 `.app` 环境或系统不支持时返回 `false`（调用方应静默
    /// 处理，因为偏好本身已被 `SettingsPreferences` 记住，留待从正式 `.app` 运行时
    /// 自愈）。
    @discardableResult
    static func apply(_ shouldRegister: Bool) -> Bool {
        guard #available(macOS 13, *), canRegister else { return false }
        let service = SMAppService.mainApp
        do {
            if shouldRegister {
                guard !isRegistered else { return true }
                try service.register()
            } else {
                guard isRegistered else { return true }
                try service.unregister()
            }
            return true
        } catch {
            NSLog("LoginItem: 注册/注销登录项失败: \(error.localizedDescription)")
            return false
        }
    }
}
