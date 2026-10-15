// AuxCam 遥控器（手机端 App）
// 面板：相册 / 直连 / 内容 / 镜像 / 旋转 / 恢复 + 一个大开关
// 它不直接碰相机：把指令写进自己的 Documents/auxcam.cmd，
// 手机内核（root 常驻）每秒读一次执行，并把状态写回 Documents/auxcam.stat

import SwiftUI
import AVKit
import PhotosUI

@main
struct AuxCamApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct Link {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var cmdURL: URL { docs.appendingPathComponent("auxcam.cmd") }
    static var statURL: URL { docs.appendingPathComponent("auxcam.stat") }
    static var videoURL: URL { docs.appendingPathComponent("picked.mp4") }

    static func send(_ lines: [String: String]) {
        var t = ""
        for (k, v) in lines { t += "\(k)=\(v)\n" }
        t += "ts=\(Int(Date().timeIntervalSince1970))\n"
        try? t.write(to: cmdURL, atomically: true, encoding: .utf8)
    }
    static func status() -> [String: String] {
        guard let t = try? String(contentsOf: statURL, encoding: .utf8) else { return [:] }
        var d: [String: String] = [:]
        for line in t.split(separator: "\n") {
            if let i = line.firstIndex(of: "=") {
                d[String(line[..<i]).trimmingCharacters(in: .whitespaces)] =
                    String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return d
    }
}

struct PanelButton: View {
    let title: String
    let icon: String
    var color: Color = Color(red: 0.20, green: 0.72, blue: 0.62)
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(color)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct ContentView: View {
    @State private var st: [String: String] = [:]
    @State private var picker: PhotosPickerItem?
    @State private var player: AVPlayer?
    @State private var hint = ""
    @State private var pickerRequest = false
    @AppStorage("streamURL") private var streamURL = "http://192.168.31.141:8899/live.m3u8"
    @AppStorage("direct") private var direct = false

    private var isNormal: Bool { (st["playing"] ?? "正常相机") == "正常相机" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.black)
                        if let p = player {
                            VideoPlayer(player: p).cornerRadius(14)
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "camera.viewfinder").font(.largeTitle).foregroundStyle(.gray)
                                Text("画面预览").font(.footnote).foregroundStyle(.gray)
                            }
                        }
                    }
                    .frame(height: 240)

                    HStack {
                        Text("画面：\(st["playing"] ?? "正常相机")").font(.subheadline).bold()
                        Spacer()
                        Text("内核：\(st["kernel"] ?? "未连接")").font(.subheadline)
                            .foregroundStyle((st["kernel"] ?? "") == "运行中" ? .green : .orange)
                    }

                    Button {
                        Link.send(["cmd": isNormal ? "start" : "stop",
                                   "mode": direct ? "stream" : "file", "url": streamURL])
                        hint = isNormal ? "已切到电脑画面" : "已切回正常相机"
                    } label: {
                        Text(isNormal ? "开始（切到电脑画面）" : "停止（切回正常相机）")
                            .font(.title3.bold()).frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isNormal ? .green : .red)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        PanelButton(title: "相册", icon: "photo.on.rectangle") { pickerRequest = true }
                        PanelButton(title: "直连", icon: "cable.connector",
                                    color: direct ? .green : Color(red: 0.30, green: 0.62, blue: 0.90)) {
                            direct.toggle()
                            Link.send(["cmd": "mode", "mode": direct ? "stream" : "file", "url": streamURL])
                            hint = direct ? "已切到直连（电脑推流）" : "已切到手机里的视频"
                        }
                        PanelButton(title: "内容", icon: "list.bullet.rectangle") {
                            st = Link.status()
                            hint = "当前素材：" + (st["video"] ?? "未知")
                        }
                        PanelButton(title: "镜像", icon: "arrow.left.arrow.right") {
                            Link.send(["cmd": "mirror"]); hint = "已切换镜像"
                        }
                        PanelButton(title: "旋转", icon: "rotate.right") {
                            Link.send(["cmd": "rotate"]); hint = "已旋转 90°"
                        }
                        PanelButton(title: "恢复", icon: "arrow.counterclockwise",
                                    color: Color(red: 0.90, green: 0.55, blue: 0.15)) {
                            Link.send(["cmd": "reset"]); hint = "已恢复默认（正常相机）"
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("电脑地址（WiFi 或 USB 直连）").font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            TextField("192.168.31.141", text: $streamURL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled(true)
                                .keyboardType(.URL).font(.footnote).textFieldStyle(.roundedBorder)
                            Button("用这个") {
                                Link.send(["cmd": "mode", "mode": direct ? "stream" : "file", "url": streamURL])
                                hint = "地址已应用"
                            }.font(.footnote).buttonStyle(.borderedProminent)
                        }
                    }

                    if hint != "" { Text(hint).font(.footnote).foregroundStyle(.green) }

                    GroupBox("状态") {
                        VStack(alignment: .leading, spacing: 4) {
                            row("内核", st["kernel"] ?? "未连接")
                            row("画面来源", st["playing"] ?? "-")
                            row("相机服务", st["camera"] ?? "-")
                            row("电脑流", st["stream"] ?? "-")
                            row("素材", st["video"] ?? "-")
                            row("最近自检", st["lastfix"] ?? "无")
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("AuxCam")
            .photosPicker(isPresented: $pickerRequest, selection: $picker, matching: .videos)
            .onChange(of: picker) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pick.mp4")
                        try? data.write(to: tmp)
                        let p = AVPlayer(url: tmp); p.isMuted = true; p.play(); player = p
                        try? FileManager.default.removeItem(at: Link.videoURL)
                        try? FileManager.default.copyItem(at: tmp, to: Link.videoURL)
                        Link.send(["cmd": "setvideo", "path": Link.videoURL.path])
                        hint = "已把相册里的视频设为画面"
                    }
                }
            }
            .onAppear {
                Link.send(["cmd": "hello"])
                refresh()
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).bold() }.font(.subheadline)
    }

    private func refresh() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            st = Link.status()
        }
    }
}
