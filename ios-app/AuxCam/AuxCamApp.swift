// AuxCam 遥控器 —— 手机端 App
// 作用：给用户一个能点的界面（开始/停止、模式切换、选视频、状态、预览）
// 它不直接碰相机，而是把指令写进自己的 Documents/auxcam.cmd，
// 手机里的内核（root 权限的常驻代理）每 3 秒读一次并执行，然后把状态写回 Documents/auxcam.stat。
// 这样 App 完全不用越狱权限，也不会因为权限问题失败。

import SwiftUI
import AVKit
import PhotosUI

@main
struct AuxCamApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

// ---------- 与内核的通道 ----------
struct Link {
    static let cmdName  = "auxcam.cmd"
    static let statName = "auxcam.stat"
    static let videoName = "picked.mp4"

    static var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var cmdURL: URL  { docs.appendingPathComponent(cmdName) }
    static var statURL: URL { docs.appendingPathComponent(statName) }
    static var videoURL: URL { docs.appendingPathComponent(videoName) }

    /// 下发指令（内核每 3 秒读一次）
    static func send(_ lines: [String: String]) {
        var text = ""
        for (k, v) in lines { text += "\(k)=\(v)\n" }
        text += "ts=\(Int(Date().timeIntervalSince1970))\n"
        try? text.write(to: cmdURL, atomically: true, encoding: .utf8)
    }

    /// 读内核写的状态
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

    /// 让内核把某个视频设为相机画面
    static func applyPickedVideo(_ url: URL) {
        let dest = videoURL
        try? FileManager.default.removeItem(at: dest)
        if url.startAccessingSecurityScopedResource() {
            try? FileManager.default.copyItem(at: url, to: dest)
            url.stopAccessingSecurityScopedResource()
        } else {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        send(["cmd": "setvideo", "path": dest.path])
    }
}

// ---------- 界面 ----------
struct ContentView: View {
    @State private var running = false
    @State private var mode = "file"          // file / stream
    @State private var st: [String: String] = [:]
    @State private var picker: PhotosPickerItem?
    @State private var pickedName = ""
    @State private var player: AVPlayer?
    @AppStorage("streamURL") private var streamURL = "http://192.168.31.141:8899/live.m3u8"

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // 预览小窗
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(Color.black)
                    if let p = player {
                        VideoPlayer(player: p).cornerRadius(14)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(.gray)
                            Text("预览（选好视频后显示）").font(.footnote).foregroundStyle(.gray)
                        }
                    }
                }
                .frame(height: 220)

                // 开始/停止
                Button {
                    running.toggle()
                    Link.send(["cmd": running ? "start" : "stop", "mode": mode])
                } label: {
                    Text(running ? "停止" : "开始")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(running ? .red : .green)

                // 模式
                Picker("画面来源", selection: $mode) {
                    Text("手机里的视频").tag("file")
                    Text("电脑推流").tag("stream")
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, m in Link.send(["cmd": "mode", "mode": m]) }

                // 流地址（局域网）：输入框 + 一键应用
                VStack(alignment: .leading, spacing: 6) {
                    Text("电脑推流地址（局域网）").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        TextField("http://192.168.31.141:8899/live.m3u8", text: $streamURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.URL)
                            .font(.footnote)
                            .textFieldStyle(.roundedBorder)
                        Button("用这个") {
                            Link.send(["cmd": "mode", "mode": mode, "url": streamURL])
                        }
                        .font(.footnote)
                        .buttonStyle(.borderedProminent)
                    }
                    Text("填电脑的 IP（可以只填 192.168.31.141，路径自动补）")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                // 选视频
                PhotosPicker(selection: $picker, matching: .videos) {
                    Label("从相册选视频（当相机画面）", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .onChange(of: picker) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pick.mp4")
                            try? data.write(to: tmp)
                            let p = AVPlayer(url: tmp)
                            p.isMuted = true; p.play()
                            player = p
                            pickedName = "已选择"
                            Link.applyPickedVideo(tmp)
                        }
                    }
                }

                // 状态
                GroupBox("状态") {
                    VStack(alignment: .leading, spacing: 4) {
                        row("内核", st["kernel"] ?? "未连接")
                        row("当前模式", st["mode"] ?? "-")
                        row("画面", st["playing"] ?? "-")
                        row("相机服务", st["camera"] ?? "-")
                        row("电脑流", st["stream"] ?? "-")
                        row("最近一次修复", st["lastfix"] ?? "无")
                        if pickedName != "" { row("已选视频", pickedName) }
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("AuxCam 遥控器")
            .onAppear {
                Link.send(["cmd": "hello"])
                refresh()
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).bold() }
            .font(.subheadline)
    }

    private func refresh() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            st = Link.status()
        }
    }
}
