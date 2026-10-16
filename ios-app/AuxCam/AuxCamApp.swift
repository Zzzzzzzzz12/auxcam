// AuxCam v4 手机端 —— 万相同款"智能"版
// 人只按一下「开始视频直播」，其余全部手机自动：
//   自动唤醒相机进程 → 自动注入 → 自动进直连 → 断流自动重连 → 卡顿自动换路 → 四态自动显示
import SwiftUI
import AVFoundation
import PhotosUI
import Foundation
import Darwin

@main
struct AuxCamApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

// ───────────────────────── 通道层 ─────────────────────────
struct Link {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var cmdURL: URL { docs.appendingPathComponent("auxcam.cmd") }
    static var statURL: URL { docs.appendingPathComponent("auxcam.stat") }
    static var dcimStatURL: URL { URL(fileURLWithPath: "/var/mobile/Media/DCIM/auxcam.stat") }
    static var esURL: URL { URL(fileURLWithPath: "/var/mobile/Media/DCIM/stream.h264") }
    static var vcamURL: URL { URL(fileURLWithPath: "/var/mobile/Media/DCIM/vcam.mp4") }
    static var videoURL: URL { docs.appendingPathComponent("picked.mp4") }

    static func send(_ lines: [String: String]) {
        var t = ""
        for (k, v) in lines { t += "\(k)=\(v)\n" }
        t += "ts=\(Int(Date().timeIntervalSince1970))\n"
        try? t.write(to: cmdURL, atomically: true, encoding: .utf8)
    }

    static func parse(_ t: String) -> [String: String] {
        var d: [String: String] = [:]
        for line in t.split(separator: "\n") {
            if let i = line.firstIndex(of: "=") {
                d[String(line[..<i]).trimmingCharacters(in: .whitespaces)] =
                    String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return d
    }

    static func status() -> [String: String] {
        if let t = try? String(contentsOf: statURL, encoding: .utf8), t.contains("kernel") { return parse(t) }
        if let t = try? String(contentsOf: dcimStatURL, encoding: .utf8) { return parse(t) }
        return [:]
    }

    static func esSize() -> Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: esURL.path)
        return (a?[.size] as? NSNumber)?.int64Value ?? -1
    }

    static func vcamStamp() -> Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: vcamURL.path)
        let t = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return Int64(t)
    }

    // 内核看门狗：内核没了，App 自己把它拉回来（不用电脑）
    static func spawnCLI(_ args: [String]) {
        var argv = args.map { strdup($0) }
        argv.append(nil)
        var pid: pid_t = 0
        posix_spawn(&pid, args[0], nil, nil, &argv, nil)
        for p in argv { free(p) }
    }

    static func reviveKernel() {
        let fm = FileManager.default
        let base = "/private/var/containers/Bundle/Application/"
        var jb: String?
        if let items = try? fm.contentsOfDirectory(atPath: base) {
            for it in items where it.hasPrefix(".jbroot-") { jb = base + it; break }
        }
        guard let jb else { return }
        let plist = jb + "/Library/LaunchDaemons/com.auxcam.agent.plist"
        spawnCLI(["/usr/bin/launchctl", "bootstrap", "user/501", plist])
        spawnCLI(["/usr/bin/launchctl", "kickstart", "-k", "user/501/com.auxcam.agent"])
    }
}

// ───────────────────────── 相机预览层 ─────────────────────────
final class Cam: ObservableObject {
    let session = AVCaptureSession()
    @Published var denied = false
    @Published var diag = "启动中…"
    @Published var position: AVCaptureDevice.Position = .front
    private var lastFlip = Date.distantPast
    private var busy = false
    private let queue = DispatchQueue(label: "auxcam.cam", qos: .userInitiated)

    private func log(_ s: String) {
        DispatchQueue.main.async { self.diag = s }
        let line = "\(Int(Date().timeIntervalSince1970)) \(s)\n"
        if let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let f = d.appendingPathComponent("diag.txt")
            if let h = try? FileHandle(forWritingTo: f) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8) ?? Data())
                try? h.close()
            } else {
                try? line.write(to: f, atomically: true, encoding: .utf8)
            }
        }
    }

    func start() {
        let st = AVCaptureDevice.authorizationStatus(for: .video)
        switch st {
        case .notDetermined:
            log("权限未定，正在请求")
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { ok ? self.begin() : self.markDenied() }
            }
        case .authorized:
            begin()
        default:
            markDenied()
        }
    }

    func flip() {
        if Date().timeIntervalSince(lastFlip) < 2.5 { return }
        lastFlip = Date()
        position = position == .front ? .back : .front
        begin(restart: true)
    }

    private func markDenied() {
        denied = true
        log("相机权限被拒")
    }

    private func begin(restart: Bool = false) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.busy { return }
            self.busy = true
            if restart {
                self.session.beginConfiguration()
                for i in self.session.inputs { self.session.removeInput(i) }
                self.session.commitConfiguration()
            }
            guard restart || !self.session.isRunning else { self.busy = false; return }
            var dev: AVCaptureDevice? = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.position)
            if dev == nil { dev = AVCaptureDevice.default(for: .video) }
            guard let d = dev else { self.log("找不到相机"); self.busy = false; return }
            do {
                let input = try AVCaptureDeviceInput(device: d)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                } else {
                    self.log("输入被占用，稍后自动重试")
                    self.busy = false
                    // 智能：10 秒后自动再试一次（相机进程可能正在重启）
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                        self.begin()
                    }
                    return
                }
            } catch {
                self.log("建输入失败: \(error.localizedDescription)")
                self.busy = false
                return
            }
            if !self.session.isRunning {
                self.session.sessionPreset = .high
                self.session.startRunning()
            }
            self.log("会话运行中=" + String(self.session.isRunning))
            self.busy = false
        }
    }
}

struct CamPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class V: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var pl: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> V {
        let v = V()
        v.pl.session = session
        v.pl.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: V, context: Context) {}
}

// ───────────────────────── VCU1 接收层（接万相桌面端） ─────────────────────────
// 万相电脑端通过数据线(usbmux)连 iPhone 的 28765 端口，包格式：
//   24 字节头: "VCU1" + 版本(1B) + 类型(1B) + flags(2B BE) + 长度(4B BE) + 序号(4B BE) + 时间戳(8B BE 微秒)
//   类型: 1=视频配置(AVCC SPS/PPS) 2=视频帧(H264 NALU, flags bit0=关键帧) 3=音频配置 4=音频帧(ADTS) 5=心跳(每秒)
final class VCU1Receiver: ObservableObject {
    @Published var status = "等待电脑连接"
    @Published var fps = 0.0
    @Published var alive = false

    static let listenPort: UInt16 = 28765
    static let outPath = "/var/mobile/Media/DCIM/stream.h264"
    private var listenFd: Int32 = -1
    private var shouldRun = false
    private var frameCount: Int32 = 0
    private var lastCountAt = Date()
    private let lock = NSLock()
    private let maxFile: Int64 = 8 * 1024 * 1024
    private var sps: Data = Data()
    private var pps: Data = Data()

    func start() {
        if shouldRun { return }
        shouldRun = true
        lock.lock(); sps = Data(); pps = Data(); lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { self.serve() }
    }

    func stop() {
        shouldRun = false
        if listenFd >= 0 { close(listenFd); listenFd = -1 }
        DispatchQueue.main.async { self.status = "已停止"; self.alive = false }
    }

    private func serve() {
        listenFd = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            DispatchQueue.main.async { self.status = "开监听失败" }
            return
        }
        var on: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = VCU1Receiver.listenPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let b = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if b != 0 {
            DispatchQueue.main.async { self.status = "端口被占" }
            close(listenFd); listenFd = -1
            return
        }
        listen(listenFd, 4)
        DispatchQueue.main.async { self.status = "已开门(28765)，等电脑连" }
        while shouldRun {
            var caddr = sockaddr_in()
            var clen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &caddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFd, $0, &clen)
                }
            }
            guard cfd >= 0 else { break }
            DispatchQueue.main.async { self.status = "电脑已连上，收画面中"; self.alive = true }
            handleConnection(cfd)
            close(cfd)
            if shouldRun {
                DispatchQueue.main.async { self.status = "断开，等电脑重连"; self.alive = false }
            }
        }
    }

    private func readFull(_ fd: Int32, _ n: Int) -> Data? {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: n)
        while buf.count < n {
            let r = read(fd, &tmp, n - buf.count)
            if r <= 0 { return nil }
            buf.append(tmp, count: r)
        }
        return buf
    }

    private func handleConnection(_ fd: Int32) {
        var lastHb = Date()
        while shouldRun {
            guard let head = readFull(fd, 24) else { return }
            let magic = String(bytes: head[0..<4], encoding: .ascii) ?? ""
            guard magic == "VCU1" else { return }
            let version = Int(head[4])
            let type = Int(head[5])
            let flags = Int(head[6]) << 8 | Int(head[7])
            let len = Int(head[8]) << 24 | Int(head[9]) << 16 | Int(head[10]) << 8 | Int(head[11])
            guard version == 1, len >= 0, len <= 4 * 1024 * 1024 else { return }
            let payload = len > 0 ? (readFull(fd, len) ?? Data()) : Data()
            if len > 0 && payload.count < len { return }
            switch type {
            case 1: parseAVCC(payload)
            case 2:
                appendVideo(payload, keyframe: (flags & 1) != 0)
                countFrame()
            case 5: lastHb = Date()
            default: break
            }
            if Date().timeIntervalSince(lastHb) > 4 { return }   // 心跳断了
        }
    }

    // type1: AVCC 配置（AVCDecoderConfigurationRecord）→ 提出 SPS/PPS
    private func parseAVCC(_ d: Data) {
        guard d.count > 7, d[0] == 1 else { return }
        var i = 5
        let numSPS = Int(d[i] & 0x1F); i += 1
        var s = Data(); var p = Data()
        for _ in 0..<numSPS where i + 2 <= d.count {
            let l = Int(d[i]) << 8 | Int(d[i + 1]); i += 2
            guard i + l <= d.count else { return }
            s = d.subdata(in: i..<(i + l)); i += l
        }
        guard i < d.count else { return }
        let numPPS = Int(d[i] & 0x1F); i += 1
        for _ in 0..<numPPS where i + 2 <= d.count {
            let l = Int(d[i]) << 8 | Int(d[i + 1]); i += 2
            guard i + l <= d.count else { return }
            p = d.subdata(in: i..<(i + l)); i += l
        }
        if !s.isEmpty && !p.isEmpty {
            lock.lock(); sps = s; pps = p; lock.unlock()
        }
    }

    private static let startCode = Data([0, 0, 0, 1])

    // type2: H264 NALU → 转 Annex-B 追加写 stream.h264（3MB 循环）
    private func appendVideo(_ d: Data, keyframe: Bool) {
        var nalu = d
        let sc4 = Data([UInt8(0), UInt8(0), UInt8(0), UInt8(1)])
        let sc3 = Data([UInt8(0), UInt8(0), UInt8(1)])
        if nalu.starts(with: sc4) { nalu = nalu.subdata(in: 4..<nalu.count) }
        else if nalu.starts(with: sc3) { nalu = nalu.subdata(in: 3..<nalu.count) }
        guard !nalu.isEmpty else { return }

        let fm = FileManager.default
        var size: Int64 = 0
        if let a = try? fm.attributesOfItem(atPath: VCU1Receiver.outPath) {
            size = (a[.size] as? NSNumber)?.int64Value ?? 0
        }
        var fh = FileHandle(forWritingAtPath: VCU1Receiver.outPath)
        if fh == nil {
            fm.createFile(atPath: VCU1Receiver.outPath, contents: nil)
            fh = FileHandle(forWritingAtPath: VCU1Receiver.outPath)
        }
        guard let fh else { return }

        var head = Data()
        if keyframe {
            lock.lock()
            let s = sps, p = pps
            lock.unlock()
            if !s.isEmpty && !p.isEmpty {
                head.append(VCU1Receiver.startCode); head.append(s)
                head.append(VCU1Receiver.startCode); head.append(p)
            }
        }
        head.append(VCU1Receiver.startCode)
        head.append(nalu)

        if size + Int64(head.count) > maxFile {
            try? fh.truncate(atOffset: 0)   // 绕回，解码器会自己重置
        }
        try? fh.seekToEnd()
        try? fh.write(contentsOf: head)
        try? fh.close()
    }

    private func countFrame() {
        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(lastCountAt) >= 1 {
            let f = Double(frameCount) / now.timeIntervalSince(lastCountAt)
            frameCount = 0
            lastCountAt = now
            DispatchQueue.main.async { self.fps = f }
        }
    }
}

// ───────────────────────── 主界面 ─────────────────────────
// 直播状态机（跟万相一样四态，自动走）
enum LiveState: String {
    case idle = "未启用"
    case starting = "正在启动 USB"
    case live = "已开启"
    case broken = "断流重连中"

    var color: Color {
        switch self {
        case .idle: return .secondary
        case .starting: return .orange
        case .live: return .green
        case .broken: return .red
        }
    }
}

struct PB: View {
    let title: String
    let icon: String
    var color: Color
    let action: () -> Void

    init(_ t: String, _ i: String, _ c: Color = Color(red: 0.20, green: 0.72, blue: 0.62), action: @escaping () -> Void) {
        title = t; icon = i; color = c; self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.body)
                Text(title).font(.footnote.bold())
            }
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ContentView: View {
    @StateObject private var cam = Cam()
    @StateObject private var vcu = VCU1Receiver()
    @State private var st: [String: String] = [:]
    @State private var state: LiveState = .idle
    @State private var picker: PhotosPickerItem?
    @State private var pickerRequest = false
    @State private var hint = ""
    @State private var deadCount = 0
    @State private var revived = false
    @State private var mirrorOn = false
    @State private var recordOn = false
    @State private var aiOn = true
    @State private var showDiag = false
    @AppStorage("pcIP") private var pcIP = "192.168.31.141"
    @AppStorage("netMode") private var netMode = false   // false=USB直连 true=局域网
    @AppStorage("wasLive") private var wasLive = false   // 上次退出时是否在直播（重开自动恢复）

    // 心跳（判断电脑画面是否真的在流进手机）
    @State private var lastES: Int64 = -1
    @State private var lastTick: Date = Date()
    @State private var kbps: Double = 0
    @State private var stuckCount = 0
    @State private var retryCount = 0

    private var kernelOK: Bool { (st["kernel"] ?? "") == "运行中" }
    private var playingFake: Bool { (st["playing"] ?? "正常相机") != "正常相机" }
    private var builtURL: String { "http://\(pcIP):8899/live.m3u8" }

    private var sigText: String {
        if kbps <= 0 { return "—" }
        if kbps > 800 { return "好 · \(String(format: "%.1f", kbps / 1000))M" }
        if kbps > 200 { return "中 · \(Int(kbps))K" }
        return "差 · \(Int(kbps))K"
    }

    private var sigColor: Color {
        if kbps <= 0 { return .secondary }
        if kbps > 800 { return .green }
        if kbps > 200 { return .orange }
        return .red
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            preview
            statusLine
            infoRow
            panel
            sigRow
            bigButton
            tabBar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(Color(UIColor.systemGroupedBackground))
        .photosPicker(isPresented: $pickerRequest, selection: $picker, matching: .videos)
        .onChange(of: picker) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pick.mp4")
                    try? data.write(to: tmp)
                    try? FileManager.default.removeItem(at: Link.videoURL)
                    try? FileManager.default.copyItem(at: tmp, to: Link.videoURL)
                    Link.send(["cmd": "setvideo", "path": Link.videoURL.path])
                    hint = "相册视频已设为画面"
                }
            }
        }
        .onAppear { boot() }
        .sheet(isPresented: $showDiag) { diagSheet }
    }

    // ── 区块 ──
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "bag.fill").font(.footnote).foregroundStyle(.teal)
            Text("AuxCam").font(.subheadline.bold())
            Text("2026 最新").font(.caption2).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.teal))
            Spacer()
            Circle().fill(kernelOK ? .green : .orange).frame(width: 8, height: 8)
            Text(kernelOK ? "内核在线" : "内核唤醒中").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if cam.denied {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text(cam.diag).font(.footnote)
                    Button("重试") { cam.start() }.font(.footnote).buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
            } else {
                CamPreview(session: cam.session)
                VStack {
                    HStack {
                        Spacer()
                        Button { cam.flip() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.title3)
                                .padding(9)
                                .background(.black.opacity(0.55))
                                .clipShape(Circle())
                        }
                        .foregroundStyle(.white)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(state.color).frame(width: 7, height: 7)
                        Text(state.rawValue).font(.caption).bold()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())
                    .foregroundStyle(.white)
                }
                .padding(8)
            }
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var statusLine: some View {
        HStack(spacing: 4) {
            Text("画面：\(st["playing"] ?? "正常相机")").font(.footnote).bold()
            Spacer()
            Text(sigText).font(.caption2).bold().foregroundStyle(sigColor)
        }
    }

    private var infoRow: some View {
        VStack(spacing: 8) {
            HStack {
                Text("用户 8894AuxCam963302").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Toggle("开启位置", isOn: .constant(true))
                    .labelsHidden()
                Text("开启位置").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "number").font(.caption2).foregroundStyle(.secondary)
                Text("选择话题 · 视频适合手游虚拟电竞").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "cable.connector").font(.caption2).foregroundStyle(vcu.alive ? .green : .teal)
                Text("源：" + vcu.status).font(.caption2).foregroundStyle(.secondary)
                if vcu.fps > 0 {
                    Text(String(format: "%.0f 帧/秒", vcu.fps)).font(.caption2).bold().foregroundStyle(.green)
                }
                Spacer()
                Text(netMode ? "局域网" : "USB直连").font(.caption2).bold().foregroundStyle(.teal)
            }
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var panel: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                PB("相册", "photo.on.rectangle") { pickerRequest = true }
                PB("直连", "cable.connector") { tapDirect() }
                PB("内录", "record.circle", recordOn ? .red : Color(red: 0.20, green: 0.72, blue: 0.62)) { tapRecord() }
                PB("镜像", "arrow.left.arrow.right", mirrorOn ? .teal : Color(red: 0.35, green: 0.55, blue: 0.75)) { tapMirror() }
                PB("旋转", "rotate.right", Color(red: 0.55, green: 0.35, blue: 0.75)) { Link.send(["cmd": "rotate"]); hint = "已旋转 90°" }
                PB("恢复", "arrow.counterclockwise", Color(red: 0.90, green: 0.55, blue: 0.15)) { tapReset() }
            }
        }
    }

    private var sigRow: some View {
        HStack {
            Label(sigText, systemImage: "waveform.path.ecg")
                .font(.caption2).bold().foregroundStyle(sigColor)
            Spacer()
            Toggle("AI实时", isOn: $aiOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            Text("AI实时").font(.caption2).foregroundStyle(.secondary)
            Button { showDiag = true } label: {
                Text("实时分析").font(.caption2).bold()
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.teal.opacity(0.15)))
                    .foregroundStyle(.teal)
            }
        }
    }

    private var bigButton: some View {
        Button { toggleLive() } label: {
            Text(bigTitle)
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
        }
        .buttonStyle(.borderedProminent)
        .tint(bigTint)
    }

    private var tabBar: some View {
        HStack {
            tab("相机", "camera.fill", true)
            tab("相册", "photo.on.rectangle") { pickerRequest = true }
            tab("创作灵感", "sparkles") { hint = "灵感：电脑 OBS 推 rtmp://电脑IP:1935/live/auxcam，手机自动接上" }
            tab("内录", "record.circle", recordOn) { tapRecord() }
        }
        .padding(.vertical, 6)
    }

    private func tab(_ t: String, _ i: String, _ on: Bool = false, _ act: (() -> Void)? = nil) -> some View {
        Button(action: { act?() }) {
            VStack(spacing: 2) {
                Image(systemName: i).font(.footnote)
                Text(t).font(.caption2)
            }
            .foregroundStyle(on ? Color.teal : Color.secondary)
            .frame(maxWidth: .infinity)
        }
    }

    private var diagSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                diagRow("内核", kernelOK ? "运行中" : "未连接")
                diagRow("注入", st["inject"] ?? "-")
                diagRow("画面", st["playing"] ?? "-")
                diagRow("流", st["stream"] ?? "-")
                diagRow("素材", st["video"] ?? "-")
                diagRow("直播状态", state.rawValue)
                diagRow("实时码率", sigText)
                diagRow("重连次数", "\(retryCount)")
                if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.green) }
                Spacer()
            }
            .padding()
            .navigationTitle("实时分析")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func diagRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.caption).bold()
        }
    }

    // ── 智能核心：开机自检 + 每秒心跳 + 自动重连 ──
    private func boot() {
        // 重活全扔后台，主线程只发指令（不然启动超时会被系统掐死）
        DispatchQueue.global(qos: .userInitiated).async {
            self.cam.start()   // 一打开就唤醒相机进程，内核跟着自动注入
            self.keepAliveAudio()   // 静音保活：退后台也继续收画面
        }
        vcu.start()   // 开门 28765，等万相电脑端连
        Link.send(["cmd": "hello", "mode": netMode ? "stream" : "file", "url": builtURL])
        if wasLive {
            // 上次退出时在直播：自动恢复，不用人再点
            wasLive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { startLive() }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
    }

    // 后台保活：循环播静音，iOS 才不会挂起我们（退后台照样收电脑画面）
    private func keepAliveAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        let rate: Int32 = 8000
        let seconds = 1
        let dataLen = rate * Int32(seconds) * 2
        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        var n = UInt32(36 + dataLen)
        withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) }
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        n = 16; withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) }
        var audioFormat = UInt16(1); withUnsafeBytes(of: &audioFormat) { wav.append(contentsOf: $0) }
        var channels = UInt16(1); withUnsafeBytes(of: &channels) { wav.append(contentsOf: $0) }
        var sampleRate = UInt32(rate); withUnsafeBytes(of: &sampleRate) { wav.append(contentsOf: $0) }
        var byteRate = UInt32(rate * 1 * 2); withUnsafeBytes(of: &byteRate) { wav.append(contentsOf: $0) }
        var blockAlign = UInt16(2); withUnsafeBytes(of: &blockAlign) { wav.append(contentsOf: $0) }
        var bits = UInt16(16); withUnsafeBytes(of: &bits) { wav.append(contentsOf: $0) }
        wav.append("data".data(using: .ascii)!)
        withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) }
        wav.append(Data(count: Int(dataLen)))   // 全零 = 静音
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        try? wav.write(to: url)
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0.01
        player?.play()
    }

    private func tick() {
        st = Link.status()
        if kernelOK {
            deadCount = 0
        } else {
            deadCount += 1
            if deadCount == 5 && !revived {
                revived = true
                DispatchQueue.global(qos: .utility).async { Link.reviveKernel() }
            }
        }
        // 心跳：电脑画面每秒都在往手机里写数据 = 直连活着
        let now = Date()
        let cur = netMode ? Link.vcamStamp() : Link.esSize()
        if lastTick.timeIntervalSince(now) > 0.7, cur >= 0, lastES >= 0 {
            let dt = now.timeIntervalSince(lastTick)
            kbps = max(0, Double(cur - lastES) * 8.0 / dt / 1000.0)
        }
        lastES = cur
        lastTick = now

        guard state == .starting || state == .live || state == .broken else { return }
        if playingFake && cur > 0 {
            if kbps > 0 || st["stream"] == "帧模式" || st["stream"] == "文件模式" {
                state = .live
                stuckCount = 0
            }
        } else if cur <= 0 || (!playingFake && state == .live) {
            stuckCount += 1
            if stuckCount >= 8 {   // 8 秒没动静 = 断了，自己重连
                stuckCount = 0
                state = .broken
                autoRetry()
            }
        }
    }

    private func autoRetry() {
        if retryCount >= 3 {
            // 连不上：自动换一条路（直连 ↔ 局域网/文件模式）
            retryCount = 0
            netMode.toggle()
            hint = "已自动切换为" + (netMode ? "局域网" : "USB直连")
        } else {
            retryCount += 1
        }
        startLive()
    }

    private func startLive() {
        state = .starting
        stuckCount = 0
        Link.send(["cmd": "start", "mode": netMode ? "stream" : "file", "url": builtURL])
    }

    private func stopLive() {
        state = .idle
        stuckCount = 0
        retryCount = 0
        Link.send(["cmd": "stop"])
    }

    private var bigTitle: String {
        switch state {
        case .idle: return "开始视频直播"
        case .starting: return "正在启动 USB…"
        case .live: return "停止直连"
        case .broken: return "断流重连中…"
        }
    }

    private var bigTint: Color {
        switch state {
        case .idle: return .green
        case .starting, .broken: return .orange
        case .live: return .red
        }
    }

    private func toggleLive() {
        switch state {
        case .idle, .broken:
            retryCount = 0
            startLive()
            wasLive = true
        case .starting, .live:
            stopLive()
            wasLive = false
        }
    }

    private func tapDirect() {
        netMode = false
        hint = "USB直连：电脑画面走数据线"
        if state == .live || state == .starting { startLive() } else {
            Link.send(["cmd": "mode", "mode": "file", "url": builtURL])
        }
    }

    private func tapMirror() {
        mirrorOn.toggle()
        Link.send(["cmd": "mirror"])
        hint = mirrorOn ? "镜像已开" : "镜像已关"
    }

    private func tapRecord() {
        recordOn.toggle()
        Link.send(["cmd": recordOn ? "record_on" : "record_off"])
        hint = recordOn ? "内录已开（自动存档电脑画面）" : "内录已关"
    }

    private func tapReset() {
        state = .idle
        stuckCount = 0
        retryCount = 0
        wasLive = false
        mirrorOn = false
        recordOn = false
        Link.send(["cmd": "reset"])
        hint = "已恢复（正常相机）"
    }
}
