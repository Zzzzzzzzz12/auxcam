import Foundation
import Combine

/// 三种画面来源
enum SourceMode: String, CaseIterable, Identifiable {
    case usb        = "usb"        // USB 直连（走数据线网卡 / 直连通道）
    case lan        = "lan"        // 局域网推流
    case album      = "album"      // 相册本地视频

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usb:   return "直连"
        case .lan:   return "局域网"
        case .album: return "相册"
        }
    }
}

final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let host        = "auxcam.host"          // 电脑 IP
        static let port        = "auxcam.port"          // 端口
        static let path        = "auxcam.path"          // HLS 路径
        static let mode        = "auxcam.mode"
        static let albumPath   = "auxcam.albumPath"     // 相册模式选中的文件（沙盒内）
        static let mirror      = "auxcam.mirror"
        static let rotation    = "auxcam.rotation"      // 0/90/180/270
        static let autoStart   = "auxcam.autoStart"
        static let muted       = "auxcam.muted"
    }

    // 电脑端默认地址：USB 直连时 iPhone 侧看到的电脑地址，局域网时是电脑的 WiFi 地址
    @Published var host: String {
        didSet { defaults.set(host, forKey: Key.host) }
    }
    @Published var port: Int {
        didSet { defaults.set(port, forKey: Key.port) }
    }
    @Published var path: String {
        didSet { defaults.set(path, forKey: Key.path) }
    }
    @Published var mode: SourceMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    @Published var albumPath: String {
        didSet { defaults.set(albumPath, forKey: Key.albumPath) }
    }
    @Published var mirror: Bool {
        didSet { defaults.set(mirror, forKey: Key.mirror) }
    }
    @Published var rotationDegrees: Int {
        didSet { defaults.set(rotationDegrees, forKey: Key.rotation) }
    }
    @Published var autoStart: Bool {
        didSet { defaults.set(autoStart, forKey: Key.autoStart) }
    }
    @Published var muted: Bool {
        didSet { defaults.set(muted, forKey: Key.muted) }
    }

    private init() {
        let isFirstRun = defaults.object(forKey: Key.port) == nil

        self.host = defaults.string(forKey: Key.host) ?? "172.20.10.2"
        self.port = defaults.object(forKey: Key.port) as? Int ?? 8899
        self.path = defaults.string(forKey: Key.path) ?? "live.m3u8"
        self.mode = SourceMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .usb
        self.albumPath = defaults.string(forKey: Key.albumPath) ?? ""
        self.mirror = defaults.bool(forKey: Key.mirror)
        self.rotationDegrees = defaults.object(forKey: Key.rotation) as? Int ?? 0
        self.autoStart = defaults.object(forKey: Key.autoStart) as? Bool ?? true
        self.muted = isFirstRun ? true : (defaults.object(forKey: Key.muted) as? Bool ?? true)
    }

    /// 当前模式下的播放地址
    var currentURL: URL? {
        switch mode {
        case .album:
            guard !albumPath.isEmpty else { return nil }
            let url = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(albumPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .usb, .lan:
            guard !host.isEmpty else { return nil }
            let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
            var s = "http://\(host)"
            if port > 0 && port != 80 { s += ":\(port)" }
            s += "/\(p)"
            return URL(string: s)
        }
    }

    var urlText: String {
        switch mode {
        case .album: return albumPath.isEmpty ? "还没选视频" : albumPath
        default:     return currentURL?.absoluteString ?? "未配置"
        }
    }

    /// 应用电脑端传来的地址（形如 192.168.1.5:8899/live.m3u8 或完整 http 链接）
    func applyAddress(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if s.hasPrefix("http://") { s = String(s.dropFirst(7)) }
        if s.hasPrefix("https://") { s = String(s.dropFirst(8)) }

        var hostPart = s
        var rest = ""
        if let slash = s.firstIndex(of: "/") {
            hostPart = String(s[s.startIndex..<slash])
            rest = String(s[s.index(after: slash)...])
        }
        if let colon = hostPart.lastIndex(of: ":"), let p = Int(hostPart[hostPart.index(after: colon)...]) {
            port = p
            hostPart = String(hostPart[hostPart.startIndex..<colon])
        }
        host = hostPart
        if !rest.isEmpty { path = rest }
    }
}
