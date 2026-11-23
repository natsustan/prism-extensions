import Foundation
import PrismExtensionKit

/// Every Shottr URL-scheme action supported by Shottr 1.8+.
enum ShottrAction: String, CaseIterable, Sendable {
    case area
    case fullscreen
    case window
    case scrolling
    case scrollingReverse = "scrolling-reverse"
    case delayed
    case `repeat`
    case append
    case ocr
    case loadClipboard = "load-clipboard"
    case loadFile = "load-file"
    case uploads
    case openApp = "open-app"
    case settings

    enum Group: String, CaseIterable, Sendable {
        case capture
        case tools
        case app

        var sectionTitle: String {
            switch self {
            case .capture: localized("Capture")
            case .tools: localized("Tools")
            case .app: localized("Shottr")
            }
        }
    }

    /// Post-capture actions supported by Shottr's `?then=` query parameter on
    /// `/grab/` URLs.
    enum PostCapture: String, CaseIterable, Sendable {
        case copy
        case save
        case edit
        case pin
        case thumbnail

        var title: String {
            switch self {
            case .copy: localized("Copy")
            case .save: localized("Save")
            case .edit: localized("Edit")
            case .pin: localized("Pin")
            case .thumbnail: localized("Show Thumbnail")
            }
        }

        var symbol: String {
            switch self {
            case .copy: "doc.on.doc"
            case .save: "square.and.arrow.down"
            case .edit: "pencil"
            case .pin: "pin"
            case .thumbnail: "photo"
            }
        }
    }

    static let defaultDelaySeconds = 3
    static let delayPresets = [3, 5, 10]

    var group: Group {
        switch self {
        case .area, .fullscreen, .window, .scrolling, .scrollingReverse, .delayed, .repeat, .append:
            .capture
        case .ocr, .loadClipboard, .loadFile:
            .tools
        case .uploads, .openApp, .settings:
            .app
        }
    }

    /// Whether the action captures the screen, so Prism should close first
    /// when `closeBeforeCapture` is enabled.
    var capturesScreen: Bool {
        switch self {
        case .area, .fullscreen, .window, .scrolling, .scrollingReverse, .delayed, .repeat, .append, .ocr:
            true
        case .loadClipboard, .loadFile, .uploads, .openApp, .settings:
            false
        }
    }

    /// Shottr accepts `?then=copy,save,edit,pin,thumbnail` on every `/grab/`
    /// command.
    var supportsPostCapture: Bool {
        group == .capture
    }

    var title: String {
        switch self {
        case .area: localized("Capture Area")
        case .fullscreen: localized("Capture Fullscreen")
        case .window: localized("Capture Window")
        case .scrolling: localized("Capture Scrolling")
        case .scrollingReverse: localized("Capture Scrolling Reverse")
        case .delayed: localized("Capture Delayed")
        case .repeat: localized("Capture Repeat")
        case .append: localized("Capture Append")
        case .ocr: localized("Capture Text (OCR)")
        case .loadClipboard: localized("Load from Clipboard")
        case .loadFile: localized("Load from File")
        case .uploads: localized("Uploads")
        case .openApp: localized("Open Shottr")
        case .settings: localized("Shottr Settings")
        }
    }

    func subtitle(delaySeconds: Int?) -> String {
        switch self {
        case .area:
            return localized("Select a region on screen")
        case .fullscreen:
            return localized("Capture the entire display")
        case .window:
            return localized("Capture a single window")
        case .scrolling:
            return localized("Capture a scrolling view downward")
        case .scrollingReverse:
            return localized("Capture a scrolling view upward")
        case .delayed:
            let seconds = delaySeconds ?? Self.defaultDelaySeconds
            return seconds == 1
                ? localized("Wait 1 second before capturing")
                : localized("Wait \(seconds) seconds before capturing")
        case .repeat:
            return localized("Recapture the previous area")
        case .append:
            return localized("Add a capture to the current screenshot")
        case .ocr:
            return localized("Recognize and copy text from screen")
        case .loadClipboard:
            return localized("Open the clipboard image in Shottr")
        case .loadFile:
            return localized("Choose an image file to open in Shottr")
        case .uploads:
            return localized("Open Shottr Cloud uploads")
        case .openApp:
            return localized("Show the Shottr window")
        case .settings:
            return localized("Open Shottr preferences")
        }
    }

    var icon: ExtensionIcon {
        switch self {
        case .area:
            ExtensionIcon(symbol: "crop", tint: "orange")
        case .fullscreen:
            ExtensionIcon(symbol: "rectangle.inset.filled", tint: "orange")
        case .window:
            ExtensionIcon(symbol: "macwindow", tint: "orange")
        case .scrolling:
            ExtensionIcon(symbol: "scroll", tint: "orange")
        case .scrollingReverse:
            ExtensionIcon(symbol: "arrow.up.and.line.horizontal.and.arrow.down", tint: "orange")
        case .delayed:
            ExtensionIcon(symbol: "timer", tint: "orange")
        case .repeat:
            ExtensionIcon(symbol: "arrow.clockwise", tint: "orange")
        case .append:
            ExtensionIcon(symbol: "plus.rectangle.on.rectangle", tint: "orange")
        case .ocr:
            ExtensionIcon(symbol: "text.viewfinder", tint: "blue")
        case .loadClipboard:
            ExtensionIcon(symbol: "doc.on.clipboard", tint: "teal")
        case .loadFile:
            ExtensionIcon(symbol: "folder", tint: "teal")
        case .uploads:
            ExtensionIcon(symbol: "icloud.and.arrow.up", tint: "indigo")
        case .openApp:
            ExtensionIcon(symbol: "camera.viewfinder", tint: "orange", app: WorkspaceShottrOpener.bundleID)
        case .settings:
            ExtensionIcon(symbol: "gearshape", tint: "gray")
        }
    }

    var keywords: [String] {
        switch self {
        case .area:
            ["area", "region", "selection", "crop", "screenshot", "grab", "区域", "选区", "框选", "截图", "quyu", "qyjt", "jietu"]
        case .fullscreen:
            ["fullscreen", "full screen", "desktop", "display", "screenshot", "grab", "全屏", "全螢幕", "整个屏幕", "截图", "quanping", "qpjt"]
        case .window:
            ["window", "app", "screenshot", "grab", "窗口", "視窗", "截图", "chuangkou", "ckjt", "shichuang"]
        case .scrolling:
            ["scrolling", "scroll", "long", "page", "screenshot", "grab", "滚动", "捲動", "长截图", "長截圖", "gundong", "gdjt", "changjietu", "cjt"]
        case .scrollingReverse:
            ["scrolling", "reverse", "up", "chat", "slack", "long", "grab", "反向滚动", "向上滚动", "反向捲動", "fanxiang", "fxgd"]
        case .delayed:
            ["delayed", "delay", "timer", "countdown", "wait", "grab", "延时", "延迟", "延遲", "倒计时", "定时", "yanshi", "yanchi", "ysjt"]
        case .repeat:
            ["repeat", "again", "previous", "last", "area", "grab", "重复", "重複", "上次", "chongfu", "cfjt"]
        case .append:
            ["append", "add", "combine", "stitch", "grab", "追加", "拼接", "添加", "zhuijia", "pinjie", "zj"]
        case .ocr:
            ["ocr", "text", "recognize", "scan", "extract", "copy text", "文字识别", "文字辨識", "识别文字", "提取文字", "shibiewenzi", "sbwz"]
        case .loadClipboard:
            ["clipboard", "paste", "load", "image", "剪贴板", "剪貼簿", "粘贴", "贴上", "jiantieban", "jtb"]
        case .loadFile:
            ["file", "open", "load", "image", "文件", "檔案", "打开", "開啟", "wenjian", "wj"]
        case .uploads:
            ["uploads", "cloud", "share", "links", "上传", "上傳", "云端", "雲端", "shangchuan", "sc"]
        case .openApp:
            ["open", "show", "shottr", "app", "打开", "開啟", "显示", "dakai", "dk"]
        case .settings:
            ["settings", "preferences", "config", "url schema", "设置", "設定", "偏好", "shezhi", "sz"]
        }
    }

    func url(delaySeconds: Int? = nil, then postCapture: PostCapture? = nil) -> URL {
        let base: String = switch self {
        case .area: "shottr://grab/area"
        case .fullscreen: "shottr://grab/fullscreen"
        case .window: "shottr://grab/window"
        case .scrolling: "shottr://grab/scrolling"
        case .scrollingReverse: "shottr://grab/scrolling/reverse"
        case .delayed:
            if let delaySeconds, delaySeconds > 0 {
                "shottr://grab/delayed=\(delaySeconds)"
            } else {
                "shottr://grab/delayed"
            }
        case .repeat: "shottr://grab/repeat"
        case .append: "shottr://grab/append"
        case .ocr: "shottr://ocr"
        case .loadClipboard: "shottr://load/clipboard"
        case .loadFile: "shottr://load/file"
        case .uploads: "shottr://uploads"
        case .openApp: "shottr://show"
        case .settings: "shottr://settings"
        }
        if let postCapture, supportsPostCapture {
            return URL(string: "\(base)?then=\(postCapture.rawValue)")!
        }
        return URL(string: base)!
    }

    /// Parses the user's `delaySeconds` preference. Blank or invalid input
    /// returns `nil`, which lets Shottr use its built-in 3-second delay.
    static func parseDelay(_ raw: String?) -> Int? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let seconds = Int(trimmed),
              seconds > 0 else {
            return nil
        }
        return seconds
    }
}
