import AppKit
import SwiftUI

/// 管理设置窗口的单例——用 AppKit NSWindow 而非 SwiftUI Window 场景。
/// SwiftUI 的 `Window(id:)` 在 macOS 上创建的是 NSPanel（canBecomeKey → NO），
/// 导致 TextField 永远无法获得键盘焦点。用常规 NSWindow 根治。
@MainActor
enum SettingsWindowManager {
    private static var window: NSWindow?
    private static var delegate: WindowDelegate?

    /// 打开设置窗口（已存在则提到最前，不存在则创建）。
    static func open(model: AppModel) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "设置"
        w.contentView = NSHostingView(
            rootView: SettingsView().environmentObject(model)
        )
        w.center()
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 480, height: 420)

        // 窗口关闭时清引用，下次点击重建
        delegate = WindowDelegate { [weak w] in
            if window === w { window = nil; delegate = nil }
        }
        w.delegate = delegate

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    /// 关闭设置窗口（app 退出时清理用）。
    static func close() {
        window?.close()
        window = nil
        delegate = nil
    }
}

/// 窗口关闭回调。
private final class WindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
