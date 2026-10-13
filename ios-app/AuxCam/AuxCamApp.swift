import SwiftUI
import AVFoundation
import UIKit

@main
struct AuxCamApp: App {

    @StateObject private var player = StreamPlayer()
    @StateObject private var settings = AppSettings.shared

    init() {
        // 声音走播放通道：切到抖音后本 App 不被系统挂起
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("AuxCam audio session error: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(settings)
                .statusBar(hidden: true)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
