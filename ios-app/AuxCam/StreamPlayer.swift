import AVKit
import AVFoundation
import Combine
import UIKit

/// 播放核心：拉流 / 播放 / 断线自愈 / 保活
final class StreamPlayer: NSObject, ObservableObject {

    enum Phase: Equatable {
        case idle
        case connecting
        case playing
        case retrying

        var text: String {
            switch self {
            case .idle:       return "待机"
            case .connecting: return "连接中"
            case .playing:    return "播放中"
            case .retrying:   return "重连中"
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var retryCount: Int = 0
    @Published private(set) var sourceText: String = "未选择来源"
    @Published private(set) var lastError: String = ""
    @Published var pipActive: Bool = false

    let player = AVPlayer()

    private(set) weak var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?

    private var targetURL: URL?
    private var albumMode = false
    private var wantPlay = false

    private var statusObs: NSKeyValueObservation?
    private var retryWork: DispatchWorkItem?
    private var tokens: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var lastSeenTime: Double = -1

    override init() {
        super.init()
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
    }

    // MARK: - 对外控制

    func attach(layer: AVPlayerLayer) {
        playerLayer = layer
        layer.player = player
        layer.videoGravity = .resizeAspectFill
        setupPiP()
    }

    func start(url: URL, album: Bool) {
        targetURL = url
        albumMode = album
        wantPlay = true
        retryCount = 0
        lastSeenTime = -1
        sourceText = album ? url.lastPathComponent : url.absoluteString
        prepare(url: url)
    }

    func stop() {
        wantPlay = false
        retryWork?.cancel(); retryWork = nil
        watchdog?.invalidate(); watchdog = nil
        detach()
        player.pause()
        player.replaceCurrentItem(with: nil)
        phase = .idle
        sourceText = "已停止"
    }

    func pause()  { player.pause() }
    func resume() { if wantPlay { player.play() } }

    func setMuted(_ muted: Bool) { player.isMuted = muted }

    // MARK: - 播放准备

    private func prepare(url: URL) {
        detach()
        phase = .connecting
        lastError = ""

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1.0

        statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch it.status {
                case .readyToPlay:
                    self.phase = .playing
                    self.retryCount = 0
                    self.player.play()
                case .failed:
                    self.scheduleRetry(reason: it.error?.localizedDescription ?? "连接失败")
                default:
                    break
                }
            }
        }

        tokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.kick() }
            })

        tokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
                let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                DispatchQueue.main.async {
                    self?.scheduleRetry(reason: err?.localizedDescription ?? "播放中断")
                }
            })

        tokens.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.onEnd() }
            })

        player.replaceCurrentItem(with: item)
        player.play()
        startWatchdog()
    }

    private func onEnd() {
        if albumMode {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                DispatchQueue.main.async { self?.player.play() }
            }
        } else {
            scheduleRetry(reason: "流已结束")
        }
    }

    private func scheduleRetry(reason: String) {
        guard wantPlay, let url = targetURL else { return }
        retryWork?.cancel()
        phase = .retrying
        lastError = reason
        retryCount += 1
        let delay = min(6.0, 0.8 * Double(retryCount))
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.wantPlay else { return }
                self.prepare(url: url)
            }
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 卡死自愈

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    private func tick() {
        guard wantPlay, !albumMode, let item = player.currentItem else { return }
        let t = item.currentTime().seconds
        guard t.isFinite else { return }
        if abs(t - lastSeenTime) < 0.02 {
            kick()
        } else {
            lastSeenTime = t
        }
    }

    private func kick() {
        guard wantPlay else { return }
        if player.rate == 0 { player.play() }
    }

    private func detach() {
        statusObs?.invalidate(); statusObs = nil
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
        tokens.removeAll()
    }

    // MARK: - 画中画

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let layer = playerLayer else { return }
        let c = AVPictureInPictureController(playerLayer: layer)
        c?.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = c
    }

    func togglePiP() {
        guard let c = pipController else { return }
        if c.isPictureInPictureActive {
            c.stopPictureInPicture()
            pipActive = false
        } else {
            c.startPictureInPicture()
            pipActive = true
        }
    }
}
