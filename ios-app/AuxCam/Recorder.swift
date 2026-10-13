import AVFoundation
import UIKit
import Photos
import Combine

/// 内录：把当前正在播的画面录成文件，停止时存进相册
final class Recorder: NSObject, ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var seconds: Int = 0
    @Published private(set) var savedHint: String = ""

    private var writer: AVAssetWriter?
    private var vinput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var voutput: AVPlayerItemVideoOutput?
    private var pumpTimer: Timer?
    private var tickTimer: Timer?
    private var fileURL: URL?
    private weak var player: AVPlayer?
    private var frameIndex: Int64 = 0
    private var started = false
    private var size = CGSize(width: 1080, height: 1920)

    func start(player: AVPlayer, size: CGSize) {
        guard !isRecording, let item = player.currentItem else { return }

        self.player = player
        if size.width > 1 && size.height > 1 { self.size = size }

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(self.size.width),
            kCVPixelBufferHeightKey as String: Int(self.size.height)
        ]

        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(out)
        voutput = out

        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("record_\(Int(Date().timeIntervalSince1970)).mp4")
        fileURL = url

        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(self.size.width),
            AVVideoHeightKey: Int(self.size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let a = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attrs)

        guard w.canAdd(input) else { return }
        w.add(input)

        writer = w
        vinput = input
        adaptor = a
        frameIndex = 0
        started = false
        seconds = 0
        savedHint = ""

        w.startWriting()
        w.startSession(atSourceTime: .zero)

        isRecording = true

        pumpTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            self.seconds += 1
        }
    }

    private func pump() {
        guard isRecording,
              let out = voutput,
              let input = vinput,
              let a = adaptor,
              input.isReadyForMoreMediaData,
              let player = player else { return }

        let host = CACurrentMediaTime()
        let itemTime = out.itemTime(forHostTime: host)
        guard out.hasNewPixelBuffer(forItemTime: itemTime),
              let pb = out.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }

        let pts = CMTime(value: frameIndex, timescale: 30)
        if a.append(pb, withPresentationTime: pts) {
            frameIndex += 1
            started = true
        } else if !started {
            NSLog("AuxCam recorder: append failed \(writer?.error?.localizedDescription ?? "")")
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false

        pumpTimer?.invalidate(); pumpTimer = nil
        tickTimer?.invalidate(); tickTimer = nil

        if let item = player?.currentItem, let out = voutput { item.remove(out) }
        voutput = nil

        vinput?.markAsFinished()
        let url = fileURL
        let hadFrames = frameIndex > 0

        writer?.finishWriting { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.writer = nil
                self.vinput = nil
                self.adaptor = nil
                guard hadFrames, let url = url else {
                    self.savedHint = "没录到画面"
                    return
                }
                self.saveToPhotos(url: url)
            }
        }
    }

    private func saveToPhotos(url: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.savedHint = "相册权限没给" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, err in
                DispatchQueue.main.async {
                    self.savedHint = ok ? "已存相册" : (err?.localizedDescription ?? "保存失败")
                }
            }
        }
    }
}
