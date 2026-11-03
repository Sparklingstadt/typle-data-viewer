import AppKit

/// セルの値を全文で見るためのウインドウ。表のセルは1行に切り詰めて表示しているので、長い値はここで読む
@MainActor
final class ValueWindowController: NSWindowController {
    /// 開いているウインドウを保持する。閉じたら外す
    private static var openControllers: [ValueWindowController] = []

    static func show(title: String, value: String?) {
        let controller = ValueWindowController(title: title, value: value)
        openControllers.append(controller)
        controller.showWindow(nil)
    }

    private init(title: String, value: String?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false

        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        if let value {
            textView.string = Self.prettyPrinted(value)
            textView.textColor = .labelColor
        } else {
            textView.string = "NULL"
            textView.textColor = .tertiaryLabelColor
        }
        window.contentView = scrollView

        super.init(window: window)

        // 開いた順に少しずつずらして、重なっても見分けられるようにする
        if let previous = Self.openControllers.last?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
        } else {
            window.center()
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Self.openControllers.removeAll { $0 === self }
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// JSON（jsonb の列など）は読みやすいよう整形する。JSON でなければそのまま
    private static func prettyPrinted(_ value: String) -> String {
        guard let first = value.first, first == "{" || first == "[",
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: formatted, encoding: .utf8) else { return value }
        return string
    }
}
