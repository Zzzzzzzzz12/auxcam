// AuxCam 手机端 App v3
// 顶部：当下相机实况（电脑画面切过来时，这里看到的就是直播间观众看到的）
// 开关 + USB直连/局域网 两个模式 + 相册/镜像/旋转/恢复 + 电脑IP短地址
import SwiftUI
import AVFoundation
import PhotosUI
import Foundation

@main
struct AuxCamApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct Link {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var cmdURL: URL { docs.appendingPathComponent("auxcam.cmd") }
    static var statURL: URL { docs.appendingPathComponent("auxcam.stat") }
    static var dcimStatURL: URL { URL(fileURLWithPath: "/var/mobile/Media/DCIM/auxcam.stat") }
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

    // 内核看门狗：内核要是没了，App 自己用 launchctl 把它拉回来（不用电脑、不用装包）
    static func reviveKernel() {
        let fm = FileManager.default
        let base = "/private/var/containers/Bundle/Application/"
        var jb: String?
        if let items = try? fm.contentsOfDirectory(atPath: base) {
            for it in items where it.hasPrefix(".jbroot-") { jb = base + it; break }
        }
        guard let jb else { return }
        let plist = jb + "/Library/LaunchDaemons/com.auxcam.agent.plist"
        let launchctl = "/usr/bin/launchctl"
        let p1 = Process()
        p1.executableURL = URL(fileURLWithPath: launchctl)
        p1.arguments = ["bootstrap", "user/501", plist]
        try? p1.run()
        Thread.sleep(forTimeInterval: 2)
        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: launchctl)
        p2.arguments = ["kickstart", "-k", "user/501/com.auxcam.agent"]
        try? p2.run()
    }
}

// 相机实况预览：不是放文件，是"当下相机正在输出的画面"（前置/后置可切）
final class Cam: ObservableObject {
    let session = AVCaptureSession()
    @Published var denied = false
    @Published var position: AVCaptureDevice.Position = .front

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
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
        position = position == .front ? .back : .front
        begin(restart: true)
    }

    private func markDenied() { denied = true }

    private func begin(restart: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if restart {
                self.session.beginConfiguration()
                for i in self.session.inputs { self.session.removeInput(i) }
                self.session.commitConfiguration()
            }
            guard restart || !self.session.isRunning else { return }
            if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.position),
               let input = try? AVCaptureDeviceInput(device: dev),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.sessionPreset = .high
            if !self.session.isRunning { self.session.startRunning() }
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
    @State private var st: [String: String] = [:]
    @State private var picker: PhotosPickerItem?
    @State private var pickerRequest = false
    @State private var hint = ""
    @State private var deadCount = 0
    @AppStorage("pcIP") private var pcIP = "192.168.31.141"
    @AppStorage("netMode") private var netMode = false   // false=USB直连  true=局域网

    private var isNormal: Bool { (st["playing"] ?? "正常相机") == "正常相机" }
    private var kernelOK: Bool { (st["kernel"] ?? "") == "运行中" }
    private var builtURL: String { "http://\(pcIP):8899/live.m3u8" }

    var body: some View {
        VStack(spacing: 12) {
            // 1) 当下相机画面（真预览）
            ZStack {
                Color.black
                if cam.denied {
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash").font(.largeTitle)
                        Text("没有相机权限，去设置里允许").font(.footnote)
                    }
                    .foregroundStyle(.gray)
                } else {
                    CamPreview(session: cam.session)
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                cam.flip()
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .font(.title3)
                                    .padding(9)
                                    .background(.black.opacity(0.55))
                                    .clipShape(Circle())
                            }
                            .foregroundStyle(.white)
                        }
                        Spacer()
                        Text("当下相机画面").font(.caption2).padding(5)
                            .background(.black.opacity(0.55)).clipShape(Capsule())
                    }
                    .padding(8)
                }
            }
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            HStack {
                Text("画面：\(st["playing"] ?? "正常相机")").font(.subheadline).bold()
                Spacer()
                Circle().fill(kernelOK ? .green : .orange).frame(width: 9, height: 9)
                Text(kernelOK ? "内核在线" : "内核未连接").font(.footnote).foregroundStyle(.secondary)
            }

            // 2) 大开关
            Button {
                Link.send(["cmd": isNormal ? "start" : "stop",
                           "mode": netMode ? "stream" : "file", "url": builtURL])
                hint = isNormal ? "已开始（电脑画面）" : "已切回正常相机"
            } label: {
                Text(isNormal ? "开始直播" : "停止（切回相机）")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(isNormal ? .green : .red)

            // 3) 两个模式，一眼分清
            Picker("", selection: $netMode) {
                Text("USB直连").tag(false)
                Text("局域网").tag(true)
            }
            .pickerStyle(.segmented)
            .onChange(of: netMode) { _, v in
                Link.send(["cmd": "mode", "mode": v ? "stream" : "file", "url": builtURL])
                hint = v ? "局域网：手机直接拉电脑流" : "USB直连：电脑画面走数据线"
            }
            Text(netMode ? "手机直接从电脑拉流（本机不支持时自动退回）"
                         : "电脑处理的画面走数据线进手机（推荐，不掉帧）")
                .font(.caption2)
                .foregroundStyle(.secondary)

            // 4) 短地址：只填 IP
            if netMode {
                HStack {
                    Text("电脑IP").font(.footnote).foregroundStyle(.secondary)
                    TextField("192.168.31.141", text: $pcIP)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textFieldStyle(.roundedBorder)
                        .font(.footnote)
                    Button("用") {
                        Link.send(["cmd": "mode", "mode": "stream", "url": builtURL])
                        hint = "地址已应用"
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                }
            }

            // 5) 保留有用的四个
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()),
                                GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                PB("相册", "photo.on.rectangle") { pickerRequest = true }
                PB("镜像", "arrow.left.arrow.right") { Link.send(["cmd": "mirror"]); hint = "已切镜像" }
                PB("旋转", "rotate.right") { Link.send(["cmd": "rotate"]); hint = "已旋转 90°" }
                PB("恢复", "arrow.counterclockwise", Color(red: 0.90, green: 0.55, blue: 0.15)) {
                    Link.send(["cmd": "reset"]); hint = "已恢复（正常相机）"
                }
            }

            if !hint.isEmpty { Text(hint).font(.footnote).foregroundStyle(.green) }

            HStack {
                Text("来源 \(st["playing"] ?? "-") · 流 \(st["stream"] ?? "-") · 素材 \(st["video"] ?? "-")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
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
                    hint = "已把相册里的视频设为画面"
                }
            }
        }
        .onAppear {
            cam.start()
            Link.send(["cmd": "hello", "mode": netMode ? "stream" : "file", "url": builtURL])
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                st = Link.status()
                if (st["kernel"] ?? "") == "运行中" {
                    deadCount = 0
                } else {
                    deadCount += 1
                    if deadCount == 5 { Link.reviveKernel() }
                }
            }
        }
    }
}
