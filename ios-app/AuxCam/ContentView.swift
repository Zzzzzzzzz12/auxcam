import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {

    @EnvironmentObject var player: StreamPlayer
    @EnvironmentObject var settings: AppSettings

    @StateObject private var recorder = Recorder()

    @State private var showPanel = true
    @State private var showSettings = false
    @State private var showPicker = false
    @State private var hud = ""
    @State private var hudWork: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 画面层
            VideoLayerView(mirror: settings.mirror,
                           rotationDegrees: settings.rotationDegrees) { layer in
                player.attach(layer: layer)
            }
            .ignoresSafeArea()

            // 左上角状态
            VStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(player.phase.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    if player.phase == .retrying {
                        Text("第 \(player.retryCount) 次")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(8)
                            .background(Color.black.opacity(0.35))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                // 底部地址
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 10))
                    Text(settings.urlText)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // 面板 / 唤出键
            VStack {
                Spacer()
                if showPanel {
                    PanelView(recorder: recorder,
                              onAlbum: { showPicker = true },
                              onDirect: { startDirect() },
                              onReset: { resetAll() },
                              onClose: { withAnimation(.easeOut(duration: 0.18)) { showPanel = false } })
                        .padding(.bottom, 46)
                        .transition(.opacity)
                } else {
                    Button(action: { withAnimation(.easeIn(duration: 0.18)) { showPanel = true } }) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .padding(.bottom, 46)
                }
            }

            // 提示气泡
            if !hud.isEmpty {
                VStack {
                    Text(hud)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                        .padding(.top, 60)
                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .environmentObject(settings)
                .environmentObject(player)
        }
        .sheet(isPresented: $showPicker) {
            VideoPicker { url in
                settings.albumPath = url.lastPathComponent
                settings.mode = .album
                player.start(url: url, album: true)
                toast("相册片源已载入")
            }
        }
        .onAppear {
            player.setMuted(settings.muted)
            autoStart()
        }
        .onChange(of: settings.mirror) { _ in }
        .onChange(of: settings.muted) { value in player.setMuted(value) }
    }

    private var statusColor: Color {
        switch player.phase {
        case .playing:    return Color(red: 0.20, green: 0.80, blue: 0.45)
        case .connecting: return .yellow
        case .retrying:   return .orange
        case .idle:       return .gray
        }
    }

    private func autoStart() {
        guard settings.autoStart, let url = settings.currentURL else { return }
        player.start(url: url, album: settings.mode == .album)
    }

    /// 直连：先 USB 优先地址，失败可用局域网地址
    private func startDirect() {
        if settings.mode != .usb { settings.mode = .usb }
        guard let url = settings.currentURL else {
            toast("先在设置里填电脑地址")
            showSettings = true
            return
        }
        player.start(url: url, album: false)
        toast("直连中：\(url.absoluteString)")
    }

    private func resetAll() {
        settings.mirror = false
        settings.rotationDegrees = 0
        recorder.stop()
        toast("已恢复默认")
    }

    private func toast(_ text: String) {
        hudWork?.cancel()
        hud = text
        let work = DispatchWorkItem { hud = "" }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}

// MARK: - 设置页

struct SettingsSheet: View {

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: StreamPlayer
    @Environment(\.presentationMode) var presentation

    @State private var host = ""
    @State private var port = ""
    @State private var path = ""
    @State private var paste = ""
    @State private var loaded = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("一行粘贴（推荐）")) {
                    TextField("例：192.168.31.141:8899/live.m3u8", text: $paste)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("解析并填入") {
                        settings.applyAddress(paste)
                        syncFromSettings()
                    }
                }

                Section(header: Text("手动填")) {
                    TextField("电脑 IP", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("端口", text: $port)
                        .keyboardType(.numberPad)
                    TextField("路径", text: $path)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Section(header: Text("小抄")) {
                    Text("USB 直连：172.20.10.2:8899/live.m3u8")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("局域网：电脑的 WiFi 地址:8899/live.m3u8")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("两种都要在同一 Wi-Fi / 同一根线的前提下。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Section(header: Text("开关")) {
                    Toggle("静音", isOn: $settings.muted)
                    Toggle("打开就自动播", isOn: $settings.autoStart)
                }

                Section {
                    Button("保存并开播") {
                        settings.host = host.trimmingCharacters(in: .whitespaces)
                        if let p = Int(port.trimmingCharacters(in: .whitespaces)) { settings.port = p }
                        let cleanPath = path.trimmingCharacters(in: .whitespaces)
                        if !cleanPath.isEmpty { settings.path = cleanPath }
                        presentation.wrappedValue.dismiss()
                        if let url = settings.currentURL {
                            player.start(url: url, album: settings.mode == .album)
                        }
                    }
                    .foregroundColor(.blue)
                }
            }
            .navigationTitle("电脑端地址")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if !loaded { syncFromSettings(); loaded = true }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func syncFromSettings() {
        host = settings.host
        port = String(settings.port)
        path = settings.path
    }
}
