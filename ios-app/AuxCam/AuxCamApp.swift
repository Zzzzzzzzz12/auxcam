// AuxCam v4 手机端 —— 万相同款"智能"版
// 人只按一下「开始视频直播」，其余全部手机自动：
//   自动唤醒相机进程 → 自动注入 → 自动进直连 → 断流自动重连 → 卡顿自动换路 → 四态自动显示
import SwiftUI
import AVKit
import AVFoundation
import PhotosUI
import CoreTransferable
import Foundation
import Darwin
import VideoToolbox
import IOSurface
import UniformTypeIdentifiers
import QuartzCore

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
    static var streamCfgURL: URL { URL(fileURLWithPath: "/var/mobile/Media/DCIM/stream.cfg") }
    static var networkModeURL: URL { URL(fileURLWithPath: "/var/mobile/Media/DCIM/auxcam.network") }
    static var vcamURL: URL { URL(fileURLWithPath: "/var/mobile/Media/DCIM/vcam.mp4") }
    static var videoURL: URL { docs.appendingPathComponent("picked.mp4") }

    static func savedNetworkMode() -> Bool? {
        guard let value = try? String(contentsOf: networkModeURL, encoding: .utf8) else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wifi", "1": return true
        case "usb", "0": return false
        default: return nil
        }
    }

    static func saveNetworkMode(_ enabled: Bool) {
        try? (enabled ? "wifi\n" : "usb\n").write(to: networkModeURL, atomically: true, encoding: .utf8)
    }

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

    static func streamEnabled() -> Bool {
        guard let t = try? String(contentsOf: streamCfgURL, encoding: .utf8) else { return false }
        return t.components(separatedBy: .newlines).contains { line in
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "active" else { return false }
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            return value == "1" || value == "on" || value == "yes"
        }
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

// PhotosPicker 的视频以文件方式导入，避免把整段视频读进 Data 占用大量内存。
private struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            let destination = Link.videoURL
            let incoming = destination.appendingPathExtension("incoming")
            return try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try? fm.removeItem(at: incoming)
                try fm.copyItem(at: source, to: incoming)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: incoming)
                } else {
                    try fm.moveItem(at: incoming, to: destination)
                }
                return PickedVideo(url: destination)
            }.value
        }
    }
}

// ───────────────────────── 相机预览层 ─────────────────────────
final class Cam: ObservableObject {
    @Published var denied = false
    @Published var diag = "启动中…"
    @Published var sessionReady = false
    @Published var position: AVCaptureDevice.Position = .front
    private var _session: AVCaptureSession?
    var session: AVCaptureSession? { _session }
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
            // 后台建 session（这里的同步 XPC 等待不卡主线程）
            var s = self._session
            if s == nil {
                s = AVCaptureSession()
                self._session = s
                DispatchQueue.main.async { self.sessionReady = true }
            }
            guard let sess = s else { self.busy = false; return }
            if restart {
                sess.beginConfiguration()
                for i in sess.inputs { sess.removeInput(i) }
                sess.commitConfiguration()
            }
            guard restart || !sess.isRunning else { self.busy = false; return }
            var dev: AVCaptureDevice? = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.position)
            if dev == nil { dev = AVCaptureDevice.default(for: .video) }
            guard let d = dev else { self.log("找不到相机"); self.busy = false; return }
            do {
                let input = try AVCaptureDeviceInput(device: d)
                if sess.canAddInput(input) {
                    sess.addInput(input)
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
            if !sess.isRunning {
                sess.sessionPreset = .high
                sess.startRunning()
            }
            self.log("会话运行中=" + String(sess.isRunning))
            self.busy = false
        }
    }
}

struct CamPreview: UIViewRepresentable {
    let session: AVCaptureSession?

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

    func updateUIView(_ uiView: V, context: Context) {
        if let s = session, uiView.pl.session !== s {
            uiView.pl.session = s
        }
    }
}

// ───────────────────────── 解码层（App 里解，画面贴公共画布） ─────────────────────────
// App 解码 H264 → 得到画面帧 → 把帧挂的共享画布编号写进 .frame.surface
// 相机进程里的插件每秒盯这个文件，有画布就用画布画面替换相机帧（= 相机采集被换成想要的画面）
final class StreamDecoder {
    static let surfacePath = "/var/mobile/Media/DCIM/.frame.surface"
    static let logPath = "/var/mobile/Media/DCIM/.dec.log"
    private var session: VTDecompressionSession?
    private var fmt: CMVideoFormatDescription?
    private var sps = Data()
    private var pps = Data()
    private var frameIndex: Int64 = 0
    private let queue = DispatchQueue(label: "auxcam.dec", qos: .userInitiated)
    private let outputLock = NSLock()
    private var retainedFrame: CVPixelBuffer?
    private var surfaceFD: Int32 = -1
    private var callbackCount = 0
    private var lastCallbackStatus: OSStatus = noErr
    private var waitingForKeyframe = true
    private var decodeCallCount: Int64 = 0
    private var activeDecodeCall: Int64 = 0
    private var sessionGeneration: Int64 = 0
    private var goldenTestStarted = false
    private let goldenTestLock = NSLock()
    private let goldenDiffLock = NSLock()
    private var goldenFormatFields: [String: String]?
    private var goldenSampleFields: [String: String]?
    private static var buildCount: Int = 0
    private static var feedCount: Int = 0
    private static let runID = String(UUID().uuidString.prefix(8))

    deinit {
        if surfaceFD >= 0 { close(surfaceFD) }
    }

    static func dlog(_ s: String) {
        let line = String(format: "%.6f [%@] %@\n", Date().timeIntervalSince1970, runID, s)
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    // 解码出一帧：保留最新像素缓冲区，避免插件读取 ID 时 IOSurface 已被回收。
    static let frameCallback: VTDecompressionOutputCallback = { outputRefCon, sourceFrameRefCon, status, _, imageBuffer, _, _ in
        guard let outputRefCon else { return }
        let decoder = Unmanaged<StreamDecoder>.fromOpaque(outputRefCon).takeUnretainedValue()
        let sourceFrameID = sourceFrameRefCon.map { Int64(Int(bitPattern: $0)) } ?? 0
        decoder.publish(status: status, imageBuffer: imageBuffer, sourceFrameID: sourceFrameID)
    }

    func setConfig(sps: Data, pps: Data) {
        queue.sync {
            self.sps = sps
            self.pps = pps
            self.frameIndex = 0
            self.setWaitingForKeyframe(true)
            self.build()
        }
        testGoldenPath()
    }

    // 用系统 AVAssetReader 提供的原生压缩 CMSampleBuffer 做一次独立基线。
    // 这条路径不改 sample、不使用实时 session，也不把测试帧发布给相机插件。
    // 收到首个 VCU1 配置后自动在 utility 队列运行一次，避免影响主线程和实时解码队列。
    func testGoldenPath() {
        let url = URL(fileURLWithPath: "/var/mobile/Media/DCIM/vcam.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else {
            StreamDecoder.dlog("golden skipped: vcam.mp4 not found")
            return
        }
        goldenTestLock.lock()
        guard !goldenTestStarted else {
            goldenTestLock.unlock()
            return
        }
        goldenTestStarted = true
        goldenTestLock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runGoldenPath(url: url)
        }
    }

    private final class GoldenProbe {
        private let lock = NSLock()
        private var callbackCount = 0
        private var callbackStatus: OSStatus?
        private var gotImage = false
        private var retainedImage: CVImageBuffer?

        func record(status: OSStatus, imageBuffer: CVImageBuffer?) {
            lock.lock()
            callbackCount += 1
            callbackStatus = status
            gotImage = imageBuffer != nil
            retainedImage = imageBuffer
            lock.unlock()
        }

        func summary() -> String {
            lock.lock()
            defer { lock.unlock() }
            return "callbacks=\(callbackCount) callbackStatus=\(callbackStatus.map { String($0) } ?? "none") image=\(gotImage)"
        }
    }

    private static let goldenCallback: VTDecompressionOutputCallback = { outputRefCon, _, status, _, imageBuffer, _, _ in
        guard let outputRefCon else { return }
        let probe = Unmanaged<GoldenProbe>.fromOpaque(outputRefCon).takeUnretainedValue()
        probe.record(status: status, imageBuffer: imageBuffer)
        StreamDecoder.dlog("golden callback status=\(status) image=\(imageBuffer != nil)")
    }

    private func runGoldenPath(url: URL) {
        StreamDecoder.dlog("golden begin path=\(url.path)")
        var reader: AVAssetReader?
        var decoderSession: VTDecompressionSession?
        defer {
            if let decoderSession { VTDecompressionSessionInvalidate(decoderSession) }
            reader?.cancelReading()
        }

        do {
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .video).first else {
                StreamDecoder.dlog("golden failed: no video track")
                return
            }
            let r = try AVAssetReader(asset: asset)
            reader = r
            // nil 表示读取 MP4 中原始压缩样本；不让 AVAssetReader 先解码/转码。
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard r.canAdd(output) else {
                StreamDecoder.dlog("golden failed: reader cannot add track output")
                return
            }
            r.add(output)
            guard r.startReading() else {
                StreamDecoder.dlog("golden failed: startReading status=\(String(describing: r.status)) error=\(String(describing: r.error))")
                return
            }
            guard let sample = output.copyNextSampleBuffer() else {
                StreamDecoder.dlog("golden failed: no first sample readerStatus=\(String(describing: r.status)) error=\(String(describing: r.error))")
                return
            }
            guard let format = CMSampleBufferGetFormatDescription(sample) else {
                StreamDecoder.dlog("golden failed: sample has no video format description")
                return
            }

            StreamDecoder.dlog("golden format \(Self.formatSummary(format))")
            StreamDecoder.dlog("golden sample \(Self.sampleSummary(sample))")
            goldenDiffLock.lock()
            goldenFormatFields = Self.formatFields(format)
            goldenSampleFields = Self.sampleFields(sample)
            goldenDiffLock.unlock()
            let probe = GoldenProbe()
            var callback = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: StreamDecoder.goldenCallback,
                decompressionOutputRefCon: Unmanaged.passUnretained(probe).toOpaque())
            let imageAttributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let createStatus = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: format,
                decoderSpecification: nil, imageBufferAttributes: imageAttributes as CFDictionary,
                outputCallback: &callback, decompressionSessionOut: &decoderSession)
            guard createStatus == noErr, let session = decoderSession else {
                StreamDecoder.dlog("golden create failed status=\(createStatus) session=\(decoderSession != nil)")
                return
            }
            VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

            var info = VTDecodeInfoFlags()
            StreamDecoder.dlog("golden DecodeFrame begin sample=\(Self.sampleSummary(sample))")
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: &info)
            StreamDecoder.dlog("golden DecodeFrame returned status=\(decodeStatus) info=\(info.rawValue)")
            let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
            StreamDecoder.dlog("golden result create=\(createStatus) decode=\(decodeStatus) wait=\(waitStatus) \(probe.summary())")
        } catch {
            StreamDecoder.dlog("golden failed: \(error.localizedDescription)")
        }
    }

    private static func formatSummary(_ format: CMVideoFormatDescription) -> String {
        formatFields(format).keys.sorted().map { "\($0)=\(formatFields(format)[$0] ?? "nil")" }.joined(separator: " ")
    }

    private static func formatFields(_ format: CMVideoFormatDescription) -> [String: String] {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize = 0
        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        let parameterSetStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength)
        let subtype = CMFormatDescriptionGetMediaSubType(format)
        return [
            "subtype": "0x\(String(subtype, radix: 16))",
            "dimensions": "\(dimensions.width)x\(dimensions.height)",
            "parameterSetStatus": String(parameterSetStatus),
            "parameterSetCount": String(parameterSetCount),
            "firstParameterSetSize": String(parameterSetSize),
            "nalUnitHeaderLength": String(nalUnitHeaderLength),
        ]
    }

    private static func sampleSummary(_ sample: CMSampleBuffer) -> String {
        sampleFields(sample).keys.sorted().map { "\($0)=\(sampleFields(sample)[$0] ?? "nil")" }.joined(separator: " ")
    }

    private static func sampleFields(_ sample: CMSampleBuffer) -> [String: String] {
        let sampleCount = CMSampleBufferGetNumSamples(sample)
        let sampleSize = sampleCount > 0 ? CMSampleBufferGetSampleSize(sample, at: 0) : 0
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
        let attachmentsText = attachments.map { String(describing: $0) } ?? "nil"
        var blockText = "none"
        if let block = CMSampleBufferGetDataBuffer(sample) {
            let length = CMBlockBufferGetDataLength(block)
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let pointerStatus = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
            let isReady = pointerStatus == noErr && dataPointer != nil
            blockText = "len:\(length)|ptrStatus:\(pointerStatus)|contiguousAtZero:\(lengthAtOffset)|total:\(totalLength)|ready:\(isReady)"
        }
        var sampleTiming = CMSampleTimingInfo()
        let timingStatus = sampleCount > 0 ? CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &sampleTiming) : -1
        return [
            "sampleCount": String(sampleCount),
            "sampleSize[0]": String(sampleSize),
            "block": blockText,
            "bufferPTS": String(describing: CMSampleBufferGetPresentationTimeStamp(sample)),
            "bufferDTS": String(describing: CMSampleBufferGetDecodeTimeStamp(sample)),
            "bufferDuration": String(describing: CMSampleBufferGetDuration(sample)),
            "timingStatus": String(timingStatus),
            "timing.duration": String(describing: sampleTiming.duration),
            "timing.pts": String(describing: sampleTiming.presentationTimeStamp),
            "timing.dts": String(describing: sampleTiming.decodeTimeStamp),
            "attachments": attachmentsText,
        ]
    }

    private static func fieldDiff(reference: [String: String], candidate: [String: String]) -> String {
        let keys = Set(reference.keys).union(candidate.keys).sorted()
        let differences = keys.compactMap { key -> String? in
            let left = reference[key] ?? "<missing>"
            let right = candidate[key] ?? "<missing>"
            guard left != right else { return nil }
            return "\(key){golden=\(left),manual=\(right)}"
        }
        return differences.isEmpty ? "no differences" : differences.joined(separator: " ")
    }

    private func logGoldenDiff(kind: String, candidate: [String: String]) {
        goldenDiffLock.lock()
        let reference = kind == "format" ? goldenFormatFields : goldenSampleFields
        goldenDiffLock.unlock()
        guard let reference else {
            StreamDecoder.dlog("golden diff \(kind): baseline not ready")
            return
        }
        StreamDecoder.dlog("golden diff \(kind): \(Self.fieldDiff(reference: reference, candidate: candidate))")
    }

    func feed(_ raw: Data, keyframe: Bool) {
        // VCU1 的接收循环也在后台队列。让 TCP 自然背压，避免 VT 变慢时
        // 把整段旧帧无限堆进 GCD 队列，造成延迟和内存持续增长。
        queue.sync {
            self.decode(raw, keyframe: keyframe)
        }
    }

    private func setWaitingForKeyframe(_ value: Bool) {
        outputLock.lock()
        waitingForKeyframe = value
        outputLock.unlock()
    }

    private func isWaitingForKeyframe() -> Bool {
        outputLock.lock()
        let value = waitingForKeyframe
        outputLock.unlock()
        return value
    }

    private func callbackStatus() -> OSStatus {
        outputLock.lock()
        let value = lastCallbackStatus
        outputLock.unlock()
        return value
    }

    private func publish(status: OSStatus, imageBuffer: CVImageBuffer?, sourceFrameID: Int64) {
        outputLock.lock()
        callbackCount += 1
        let count = callbackCount
        lastCallbackStatus = status
        let activeCall = activeDecodeCall
        if status != noErr { waitingForKeyframe = true }
        guard status == noErr, let imageBuffer else {
            outputLock.unlock()
            if count <= 3 || count % 90 == 0 {
                StreamDecoder.dlog("callback #\(count) sourceFrame=\(sourceFrameID) activeCall=\(activeCall) status=\(status)")
            }
            return
        }
        retainedFrame = imageBuffer
        outputLock.unlock()

        guard let surface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else {
            StreamDecoder.dlog("decoded frame has no IOSurface")
            return
        }
        let surfaceID = IOSurfaceGetID(surface)
        // 插件 15ms 轮询这个小文件。复用 fd 用一次 pwrite 更新固定宽度编号，
        // 避免每帧创建临时文件再 rename 的元数据开销。
        if surfaceFD < 0 {
            surfaceFD = open(StreamDecoder.surfacePath, O_CREAT | O_WRONLY, mode_t(0o666))
            if surfaceFD >= 0 { _ = ftruncate(surfaceFD, 0) }
        }
        let contents = String(format: "id=%010u\n", surfaceID)
        let written = contents.withCString { pwrite(surfaceFD, $0, 14, 0) }
        if surfaceFD < 0 || written != 14 {
            if count <= 3 || count % 90 == 0 {
                StreamDecoder.dlog("surface publish failed errno=\(errno)")
            }
            return
        }
        if count <= 3 || count % 90 == 0 {
            StreamDecoder.dlog("callback #\(count) sourceFrame=\(sourceFrameID) activeCall=\(activeCall) status=0 surface=\(surfaceID)")
        }
    }

    private func build() {
        guard sps.count > 3, pps.count > 3 else {
            StreamDecoder.dlog("build: sps/pps too small")
            return
        }
        if let s = session {
            VTDecompressionSessionInvalidate(s)
            session = nil
            fmt = nil
        }
        // 全程锁在 withUnsafeBytes 闭包内（Data 指针不能逃逸，逃逸就悬垂 → -12712）
        sps.withUnsafeBytes { sp in
            pps.withUnsafeBytes { pp in
                guard let spb = sp.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppb = pp.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    StreamDecoder.dlog("build: no base address")
                    return
                }
                let ps: [UnsafePointer<UInt8>] = [spb, ppb]
                var sizes = [sps.count, pps.count]
                var f: CMVideoFormatDescription?
                let fmtSt = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: ps, parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &f)
                StreamDecoder.buildCount += 1
                StreamDecoder.dlog("build #\(StreamDecoder.buildCount) fmtSt=\(fmtSt) sps=\(sps.count) pps=\(pps.count)")
                guard let f else {
                    StreamDecoder.dlog("build: no format description")
                    return
                }
                fmt = f
                StreamDecoder.dlog("manual format \(Self.formatSummary(f))")
                var cb = VTDecompressionOutputCallbackRecord(
                    decompressionOutputCallback: StreamDecoder.frameCallback,
                    decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
                // 明确要求 IOSurface backing；不限制像素格式，让 VideoToolbox
                // 选择设备原生的解码输出格式。
                let imageAttributes: [String: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
                ]
                let vtSt = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault, formatDescription: f,
                    decoderSpecification: nil, imageBufferAttributes: imageAttributes as CFDictionary,
                    outputCallback: &cb, decompressionSessionOut: &session)
                if vtSt == noErr, let session {
                    sessionGeneration += 1
                    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                }
                StreamDecoder.dlog("build: VT session st=\(vtSt) ok=\(session != nil) generation=\(sessionGeneration)")
            }
        }
    }

    private func decode(_ raw: Data, keyframe: Bool) {
        // 直接扫描 Data 的底层指针，只保留 NALU 范围，避免先复制整帧到 [UInt8]
        // 再为每个 NALU 各复制一次。
        let nalRanges = Self.splitAnnexBRanges(raw)
        StreamDecoder.feedCount += 1
        guard let session, let fmt else {
            if StreamDecoder.feedCount <= 3 || StreamDecoder.feedCount % 90 == 0 {
                StreamDecoder.dlog("decode #\(StreamDecoder.feedCount) waiting for config; input=\(raw.count)")
            }
            return
        }

        // SPS/PPS 已经放在 CMVideoFormatDescription 里。sample 只提交 VCL
        // NALU（一个或多个 slice），不能再把 SPS/PPS 当作画面 sample 重复提交。
        let slices = nalRanges.filter { range in
            guard range.lowerBound < raw.count else { return false }
            let type = raw[range.lowerBound] & 0x1F
            return type == 1 || type == 5
        }
        guard !slices.isEmpty else {
            if StreamDecoder.feedCount <= 5 || StreamDecoder.feedCount % 90 == 0 {
                StreamDecoder.dlog("decode #\(StreamDecoder.feedCount) skip non-VCL NALs=\(nalRanges.count)")
            }
            return
        }
        let hasIDR = slices.contains { (raw[$0.lowerBound] & 0x1F) == 5 }
        if keyframe != hasIDR {
            StreamDecoder.dlog("keyframe flag mismatch flag=\(keyframe) IDR=\(hasIDR)")
        }
        if isWaitingForKeyframe() && !hasIDR { return }
        if hasIDR { setWaitingForKeyframe(false) }

        var au = Data()
        for range in slices {
            var l = UInt32(range.count).bigEndian
            withUnsafeBytes(of: &l) { au.append(contentsOf: $0) }
            au.append(contentsOf: raw[range])
        }
        let total = au.count
        guard total > 0 else { return }
        // 自己 malloc 内存（memoryBlock:nil 时 CMBlockBuffer 不会自动分配 → -12707）
        guard let mem = malloc(total) else { return }
        let mp = mem.assumingMemoryBound(to: UInt8.self)
        let copied = au.withUnsafeBytes { b -> Bool in
            guard let base = b.bindMemory(to: UInt8.self).baseAddress else { return false }
            mp.update(from: base, count: total)
            return true
        }
        guard copied else { free(mem); return }
        var block: CMBlockBuffer?
        var src = CMBlockBufferCustomBlockSource(
            version: 0,
            AllocateBlock: nil,
            // FreeBlock 参数顺序是 (refCon, memoryBlock, size)。释放第二个参数，
            // 否则每帧的 malloc 缓冲都会泄漏，长时间运行会拖慢甚至杀掉 App。
            FreeBlock: { _, memoryBlock, _ in free(memoryBlock) },
            refCon: nil)
        let bSt = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: total,
            blockAllocator: kCFAllocatorDefault, customBlockSource: &src,
            offsetToData: 0, dataLength: total,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else {
            if StreamDecoder.feedCount <= 5 || StreamDecoder.feedCount % 30 == 0 {
                StreamDecoder.dlog("decode #\(StreamDecoder.feedCount) block fail \(bSt)")
            }
            free(mem)
            return
        }
        var sb: CMSampleBuffer?
        // 带有效 timing（iOS 解码器无 timing 也判坏数据）
        var tsIdx = Int64(frameIndex)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: tsIdx, timescale: 30),
            decodeTimeStamp: CMTime.invalid)
        var sampleSize = total
        let sbSt = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sb)
        frameIndex += 1
        if let sb {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? NSMutableArray,
               attachments.count > 0,
               let attachment = attachments[0] as? NSMutableDictionary {
                attachment[kCMSampleAttachmentKey_NotSync as String] = NSNumber(value: !hasIDR)
            }
            decodeCallCount += 1
            let callIndex = decodeCallCount
            let shouldTraceCall = callIndex <= 3 || callIndex % 90 == 0
            if shouldTraceCall {
                StreamDecoder.dlog("manual sample #\(callIndex) \(Self.sampleSummary(sb))")
                StreamDecoder.dlog("manual DecodeFrame begin #\(callIndex) sessionGeneration=\(sessionGeneration)")
            }
            // flags=[] 保持同步解码，确保 block/sample 在 VT 使用期间有效。
            outputLock.lock()
            lastCallbackStatus = noErr
            activeDecodeCall = callIndex
            outputLock.unlock()
            var decodeInfo = VTDecodeInfoFlags()
            let decodeStatus = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sb, flags: [],
                frameRefcon: UnsafeMutableRawPointer(bitPattern: Int(callIndex)),
                infoFlagsOut: &decodeInfo)
            let outputStatus = callbackStatus()
            outputLock.lock()
            activeDecodeCall = 0
            outputLock.unlock()
            if shouldTraceCall {
                StreamDecoder.dlog("manual DecodeFrame returned #\(callIndex) vt=\(decodeStatus) callback=\(outputStatus) info=\(decodeInfo.rawValue)")
            }
            if decodeStatus != noErr || outputStatus != noErr {
                setWaitingForKeyframe(true)
                // VT 报坏帧后丢弃增量帧，重建会话；收到下一个 IDR 再恢复。
                build()
            }
            if shouldTraceCall {
                StreamDecoder.dlog("decode #\(StreamDecoder.feedCount) sample=\(sbSt) vt=\(decodeStatus) callback=\(outputStatus) bytes=\(total) idr=\(hasIDR)")
            }
        } else {
            if StreamDecoder.feedCount <= 5 || StreamDecoder.feedCount % 30 == 0 {
                StreamDecoder.dlog("decode #\(StreamDecoder.feedCount) sample fail \(sbSt)")
            }
        }
    }

    private static func splitAnnexBRanges(_ data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return [] }
            let count = rawBuffer.count
            var starts: [(start: Int, payload: Int)] = []
            var i = 0
            while i + 3 <= count {
                if i + 4 <= count,
                   bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, i + 4))
                    i += 4
                } else if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                    starts.append((i, i + 3))
                    i += 3
                } else {
                    i += 1
                }
            }
            guard !starts.isEmpty else { return count == 0 ? [] : [0..<count] }

            var result: [Range<Int>] = []
            for index in starts.indices {
                let payloadStart = starts[index].payload
                var end = index + 1 < starts.count ? starts[index + 1].start : count
                while end > payloadStart && bytes[end - 1] == 0 { end -= 1 }
                if end > payloadStart { result.append(payloadStart..<end) }
            }
            return result
        }
    }
}

// ───────────────────────── Wi-Fi/HLS 拉流层 ─────────────────────────
// AVPlayer 负责网络视频解码；这里每次只取最新一帧，把 IOSurface 编号交给相机插件。
// 这样 Wi-Fi 模式不需要再走容易出错的手工 VideoToolbox 解码路径。
final class HLSFrameSource: NSObject, ObservableObject, AVPlayerItemOutputPullDelegate {
    @Published private(set) var frameCount: Int64 = 0
    @Published private(set) var fps: Double = 0
    @Published private(set) var status = "待机"
    @Published private(set) var previewPlayer: AVPlayer?

    private static let surfacePath = "/var/mobile/Media/DCIM/.frame.surface"
    private static let logPath = "/var/mobile/Media/DCIM/.hls.log"
    private let queue = DispatchQueue(label: "auxcam.hls.frames", qos: .userInitiated)
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var retainedFrame: CVPixelBuffer?
    private var surfaceFD: Int32 = -1
    private var deliveredFrames: Int64 = 0
    private var reportFrames: Int64 = 0
    private var lastReport = Date()
    private var lastFrameAt = Date.distantPast
    private var lastNoFrameReport = Date.distantPast
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastPlaybackRecoveryAt = Date.distantPast

    deinit {
        if surfaceFD >= 0 { close(surfaceFD) }
    }

    func start(url: URL) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.lastFrameAt = .distantPast
            self.lastNoFrameReport = .distantPast
            self.log("start url=\(url.absoluteString)")
            self.setStatus("正在连接电脑")

            let item = AVPlayerItem(url: url)
            // 交给 AVPlayer 根据网络情况管理缓冲，过短的缓冲会让长 GOP 的 HLS 卡在段尾。
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let output = AVPlayerItemVideoOutput(outputSettings: attributes)

            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            self.output = output
            DispatchQueue.main.async { self.previewPlayer = player }
            self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let value: String
                switch item.status {
                case .readyToPlay: value = "已连接，等待画面"
                case .failed: value = "拉流失败：\(item.error?.localizedDescription ?? "未知错误")"
                default: value = "正在连接电脑"
                }
                self?.log("item status=\(item.status.rawValue) error=\(item.error?.localizedDescription ?? "none")")
                self?.setStatus(value)
                guard item.status == .readyToPlay else { return }
                DispatchQueue.main.async { [weak self, weak player] in
                    guard let self, let player, self.player === player else { return }
                    // Attach the video output only after HLS has prepared the item.
                    item.add(output)
                    output.setDelegate(self, queue: self.queue)
                    self.displayLink?.invalidate()
                    let link = CADisplayLink(target: self, selector: #selector(self.displayLinkDidRefresh(_:)))
                    self.displayLink = link
                    link.add(to: .main, forMode: .common)
                    player.playImmediately(atRate: 1.0)
                    output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
                }
            }
            self.timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                guard let self else { return }
                let itemTime = player.currentItem?.currentTime().seconds ?? -1
                self.log("player state timeControl=\(player.timeControlStatus.rawValue) rate=\(player.rate) itemTime=\(itemTime) waiting=\(String(describing: player.reasonForWaitingToPlay))")
            }
            self.notificationTokens.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled, object: item, queue: nil) { [weak self] _ in
                    guard let self else { return }
                    self.log("playback stalled")
                    self.setStatus("网络卡顿，正在恢复")
                    self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) {
                        self.player?.play()
                    }
                })
            self.notificationTokens.append(NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: nil) { [weak self] _ in
                    guard let event = item.accessLog()?.events.last else { return }
                    self?.log("access bytes=\(event.numberOfBytesTransferred) bitrate=\(event.observedBitrate) stalls=\(event.numberOfStalls)")
                })

        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func setStatus(_ value: String) {
        DispatchQueue.main.async { self.status = value }
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        log("video output media data available")
    }

    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) {
        log("video output sequence flushed")
    }

    private func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        StreamDecoder.dlog("HLS \(message)")
        let fd = open(Self.logPath, O_CREAT | O_WRONLY | O_APPEND, mode_t(0o666))
        guard fd >= 0 else { return }
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        close(fd)
    }

    private func stopOnQueue() {
        DispatchQueue.main.sync {
            displayLink?.invalidate()
            displayLink = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        notificationTokens.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        output = nil
        retainedFrame = nil
        deliveredFrames = 0
        reportFrames = 0
        lastReport = Date()
        DispatchQueue.main.async {
            self.previewPlayer = nil
            self.frameCount = 0
            self.fps = 0
            self.status = "待机"
        }
    }

    @objc private func displayLinkDidRefresh(_ link: CADisplayLink) {
        copyLatestFrame(hostTime: CACurrentMediaTime())
    }

    private func copyLatestFrame(hostTime: CFTimeInterval) {
        recoverIfPlaybackStopped()
        guard let output else { return }
        var itemTime = output.itemTime(forHostTime: hostTime)
        var hasFrame = output.hasNewPixelBuffer(forItemTime: itemTime)
        if !hasFrame, let current = player?.currentItem?.currentTime(), current.isValid {
            itemTime = current
            hasFrame = output.hasNewPixelBuffer(forItemTime: current)
        }
        guard hasFrame else {
            reportNoFrame("no new pixel buffer", itemTime: itemTime)
            return
        }
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            reportNoFrame("pixel buffer copy returned nil", itemTime: itemTime)
            return
        }
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
            reportNoFrame("pixel buffer has no IOSurface", itemTime: itemTime)
            return
        }

        retainedFrame = pixelBuffer
        if surfaceFD < 0 {
            surfaceFD = open(Self.surfacePath, O_CREAT | O_WRONLY, mode_t(0o666))
            if surfaceFD >= 0 {
                _ = ftruncate(surfaceFD, 0)
                log("surface file opened")
            } else {
                log("surface open failed errno=\(errno)")
            }
        }
        guard surfaceFD >= 0 else {
            setStatus("无法发布相机画面")
            return
        }
        let contents = String(format: "id=%010u\n", IOSurfaceGetID(surface))
        let written = contents.withCString { pwrite(surfaceFD, $0, 14, 0) }
        guard written == 14 else {
            setStatus("发布相机画面失败")
            return
        }

        deliveredFrames += 1
        lastFrameAt = Date()
        if deliveredFrames == 1 { log("first decoded frame width=\(CVPixelBufferGetWidth(pixelBuffer)) height=\(CVPixelBufferGetHeight(pixelBuffer))") }
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 1 {
            let elapsed = now.timeIntervalSince(lastReport)
            let rate = Double(deliveredFrames - reportFrames) / elapsed
            let currentFrameCount = deliveredFrames
            reportFrames = deliveredFrames
            lastReport = now
            DispatchQueue.main.async {
                self.frameCount = currentFrameCount
                self.fps = rate
                self.status = rate > 0 ? "电脑画面已接入" : "等待电脑画面"
            }
        }
    }

    // HLS 的直播清单会持续滚动；iOS 偶尔会在旧分段末尾进入 paused，主动追到最新可播位置。
    private func recoverIfPlaybackStopped() {
        guard let player, let item = player.currentItem, item.status == .readyToPlay,
              player.timeControlStatus == .paused,
              Date().timeIntervalSince(lastPlaybackRecoveryAt) >= 2 else { return }
        lastPlaybackRecoveryAt = Date()

        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let end = CMTimeRangeGetEnd(range)
            let target = CMTimeSubtract(end, CMTime(seconds: 1, preferredTimescale: 600))
            if end.isValid, target.isValid, CMTimeCompare(target, range.start) >= 0 {
                log("player recovery seek live edge target=\(target.seconds) end=\(end.seconds)")
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak player] finished in
                    if finished { player?.playImmediately(atRate: 1.0) }
                }
                return
            }
        }

        log("player recovery resume currentTime=\(player.currentTime().seconds)")
        player.playImmediately(atRate: 1.0)
    }

    private func reportNoFrame(_ reason: String, itemTime: CMTime) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) > 5 && now.timeIntervalSince(lastNoFrameReport) > 5 else { return }
        lastNoFrameReport = now
        let item = player?.currentItem
        let error = item?.error?.localizedDescription ?? "none"
        let access = item?.accessLog()?.events.last
        log("no frame reason=\(reason) itemStatus=\(item?.status.rawValue ?? -1) playerStatus=\(player?.status.rawValue ?? -1) timeControl=\(player?.timeControlStatus.rawValue ?? -1) rate=\(player?.rate ?? -1) itemTime=\(itemTime.seconds) bytes=\(access?.numberOfBytesTransferred ?? -1) error=\(error)")
        if item?.status == .failed {
            setStatus("拉流失败：\(error)")
        } else if item?.status == .readyToPlay {
            setStatus("已连接，暂时没有画面")
        }
    }
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
    let decoder = StreamDecoder()
    private var listenFd: Int32 = -1
    private var shouldRun = false
    private var frameCount: Int32 = 0
    private var lastCountAt = Date()
    private var totalVideoBytes: Int64 = 0
    private let lock = NSLock()
    private let maxFile: Int64 = 8 * 1024 * 1024
    private var sps: Data = Data()
    private var pps: Data = Data()
    private var ringHandle: FileHandle?
    private var ringSize: Int64 = 0
    private var ringNeedsKeyframe = false

    func start() {
        if shouldRun { return }
        shouldRun = true
        lock.lock()
        sps = Data(); pps = Data(); totalVideoBytes = 0; frameCount = 0
        lock.unlock()
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
            slog("socket failed")
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
            slog("bind failed errno=\(errno)")
            close(listenFd); listenFd = -1
            return
        }
        listen(listenFd, 128)
        slog("listening 28765")
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
            // 读超时 5 秒：对端不送数据就别占着连接（防重连风暴拖死）
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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

    // 诊断日志（写到 DCIM，电脑随时能拉）
    private func slog(_ s: String) {
        let line = "\(Int(Date().timeIntervalSince1970)) \(s)\n"
        let path = "/var/mobile/Media/DCIM/.vcu1.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func handleConnection(_ fd: Int32) {
        var lastHb = Date()
        slog("conn accepted")
        while shouldRun {
            guard let head = readFull(fd, 24) else { slog("conn closed by peer"); return }
            let magic = String(bytes: head[0..<4], encoding: .ascii) ?? ""
            guard magic == "VCU1" else { slog("bad magic: " + magic); return }
            let version = Int(head[4])
            let type = Int(head[5])
            let flags = Int(head[6]) << 8 | Int(head[7])
            let len = Int(head[8]) << 24 | Int(head[9]) << 16 | Int(head[10]) << 8 | Int(head[11])
            guard version == 1, len >= 0, len <= 4 * 1024 * 1024 else {
                slog("bad ver/len: v=\(version) len=\(len)"); return
            }
            let payload = len > 0 ? (readFull(fd, len) ?? Data()) : Data()
            if len > 0 && payload.count < len { slog("payload short"); return }
            switch type {
            case 1:
                parseAVCC(payload)
                decoder.setConfig(sps: sps, pps: pps)
                slog("type1 config, sps=\(sps.count) pps=\(pps.count)")
            case 2:
                // 先把最新帧送进 VideoToolbox 并发布 IOSurface，兼容环形文件写入放后面。
                decoder.feed(payload, keyframe: (flags & 1) != 0)
                appendVideo(payload, keyframe: (flags & 1) != 0)
                countFrame(payload.count)
                if (flags & 1) != 0 { slog("type2 KEYFRAME len=\(payload.count)") }
            case 5: lastHb = Date()
            default: break
            }
            if Date().timeIntervalSince(lastHb) > 8 { slog("heartbeat timeout"); return }
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

    // type2: H264 NALU → 转 Annex-B 追加写 stream.h264（8MB 环形缓存）
    private func appendVideo(_ d: Data, keyframe: Bool) {
        var nalu = d
        let sc4 = Data([UInt8(0), UInt8(0), UInt8(0), UInt8(1)])
        let sc3 = Data([UInt8(0), UInt8(0), UInt8(1)])
        if nalu.starts(with: sc4) { nalu = nalu.subdata(in: 4..<nalu.count) }
        else if nalu.starts(with: sc3) { nalu = nalu.subdata(in: 3..<nalu.count) }
        guard !nalu.isEmpty else { return }

        let fm = FileManager.default
        if ringHandle == nil {
            if !fm.fileExists(atPath: VCU1Receiver.outPath) {
                fm.createFile(atPath: VCU1Receiver.outPath, contents: nil)
            }
            ringHandle = FileHandle(forWritingAtPath: VCU1Receiver.outPath)
            if let attributes = try? fm.attributesOfItem(atPath: VCU1Receiver.outPath) {
                ringSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            }
            try? ringHandle?.seekToEnd()
        }
        guard let fh = ringHandle else { return }

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

        if ringNeedsKeyframe && !keyframe { return }
        if ringSize + Int64(head.count) > maxFile {
            try? fh.truncate(atOffset: 0)
            try? fh.seek(toOffset: 0)
            ringSize = 0
            ringNeedsKeyframe = true
            // 环形缓存从完整 GOP 起步，避免绕回后以 P 帧开头。
            if !keyframe { return }
        }
        try? fh.write(contentsOf: head)
        ringSize += Int64(head.count)
        if keyframe { ringNeedsKeyframe = false }
    }

    func videoByteCount() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return totalVideoBytes
    }

    private func countFrame(_ payloadBytes: Int) {
        lock.lock()
        frameCount += 1
        totalVideoBytes += Int64(payloadBytes)
        let now = Date()
        var measuredFPS: Double?
        if now.timeIntervalSince(lastCountAt) >= 1 {
            let f = Double(frameCount) / now.timeIntervalSince(lastCountAt)
            frameCount = 0
            lastCountAt = now
            measuredFPS = f
        }
        lock.unlock()
        if let measuredFPS {
            DispatchQueue.main.async { self.fps = measuredFPS }
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
    @StateObject private var hlsSource = HLSFrameSource()
    @State private var st: [String: String] = [:]
    @State private var state: LiveState = .idle
    @State private var picker: PhotosPickerItem?
    @State private var pickerRequest = false
    @State private var hint = ""
    @State private var fakeCameraOn = false
    @State private var usingStreamSource = false
    @State private var usingHLSSource = false
    @State private var hasPickedVideo = false
    @State private var cameraCommandAt = Date.distantPast
    @State private var deadCount = 0
    @State private var revived = false
    @State private var mirrorOn = false
    @State private var recordOn = false
    @State private var aiOn = true
    @State private var showDiag = false
    @AppStorage("pcIP") private var pcIP = "192.168.31.141"
    @AppStorage("streamURL") private var streamURL = ""
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
    private var cameraOutputText: String {
        guard fakeCameraOn else { return st["playing"] ?? "正常相机" }
        return usingStreamSource ? "电脑实时流" : "素材视频"
    }
    private var builtURL: String {
        streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var streamURLBinding: Binding<String> {
        Binding(get: { streamURL }, set: { streamURL = $0 })
    }

    private var sigText: String {
        if usingHLSSource {
            return hlsSource.fps > 0 ? "Wi-Fi · \(Int(hlsSource.fps)) 帧/秒" : hlsSource.status
        }
        if kbps <= 0 { return "—" }
        if kbps > 800 { return "好 · \(String(format: "%.1f", kbps / 1000))M" }
        if kbps > 200 { return "中 · \(Int(kbps))K" }
        return "差 · \(Int(kbps))K"
    }

    private var sigColor: Color {
        if usingHLSSource {
            if hlsSource.fps >= 24 { return .green }
            return hlsSource.fps > 0 ? .orange : .secondary
        }
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
            if !hint.isEmpty {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(hint.contains("失败") ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            Task { @MainActor in
                hint = "正在导入相册视频…"
                do {
                    guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
                        hint = "无法读取所选视频，请重试"
                        return
                    }
                    try setStreamMode(false)
                    hlsSource.stop()
                    netMode = false
                    usingStreamSource = false
                    usingHLSSource = false
                    hasPickedVideo = true
                    lastES = -1; lastTick = Date(); kbps = 0
                    Link.send(["cmd": "setvideo", "path": video.url.path])
                    fakeCameraOn = true
                    cameraCommandAt = Date()
                    hint = "视频已导入，正在切换画面"
                } catch {
                    hint = "视频导入失败，请重试"
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
            if fakeCameraOn && usingHLSSource, let player = hlsSource.previewPlayer {
                VideoPlayer(player: player)
                    .allowsHitTesting(false)
            } else if fakeCameraOn {
                VStack(spacing: 10) {
                    Image(systemName: usingStreamSource ? "cable.connector" : "play.rectangle.fill")
                        .font(.system(size: 38))
                    Text(usingStreamSource ? "电脑实时流已启用" : "素材视频已启用")
                        .font(.headline)
                    Text("切换到相机或直播 App 查看输出")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
            } else if cam.denied {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash").font(.largeTitle)
                    Text(cam.diag).font(.footnote)
                    Button("重试") { cam.start() }.font(.footnote).buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
            } else {
                CamPreview(session: cam.session)
                    .id(cam.sessionReady)   // session 后台建好后重建视图挂上去
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
            Text("画面：\(cameraOutputText)").font(.footnote).bold()
            Spacer()
            Text(sigText).font(.caption2).bold().foregroundStyle(sigColor)
        }
    }

    private var infoRow: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: netMode ? "wifi" : "cable.connector")
                    .font(.caption2).foregroundStyle(.teal)
                Text(netMode ? "局域网推流" : "USB 直连")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(netMode ? "Wi-Fi" : "端口 28765")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Text("电脑直播地址").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                TextField("http://电脑IP:8899/obs/live.m3u8", text: streamURLBinding)
                    .font(.caption2)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 250)
            }
            HStack {
                Image(systemName: usingHLSSource ? "wifi" : "cable.connector")
                    .font(.caption2).foregroundStyle(usingHLSSource ? .green : (vcu.alive ? .green : .teal))
                Text("源：" + (usingHLSSource ? hlsSource.status : vcu.status))
                    .font(.caption2).foregroundStyle(.secondary)
                if usingHLSSource && hlsSource.fps > 0 {
                    Text(String(format: "%.0f 帧/秒", hlsSource.fps)).font(.caption2).bold().foregroundStyle(.green)
                } else if !usingHLSSource && vcu.fps > 0 {
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
                PB(netMode ? "局域网已选" : "Wi-Fi", "wifi") { tapNetwork() }
                PB("内录", "record.circle", recordOn ? .red : Color(red: 0.20, green: 0.72, blue: 0.62)) { tapRecord() }
                PB("镜像", "arrow.left.arrow.right", mirrorOn ? .teal : Color(red: 0.35, green: 0.55, blue: 0.75)) { tapMirror() }
                PB(fakeCameraOn ? "切回真镜头" : ((!netMode && (vcu.alive || !hasPickedVideo)) ? "放电脑画面" : "放视频"),
                   fakeCameraOn ? "camera.fill" : "play.rectangle.fill",
                   fakeCameraOn ? Color(red: 0.90, green: 0.55, blue: 0.15) : Color(red: 0.55, green: 0.35, blue: 0.75)) {
                    vcamControl(!fakeCameraOn)
                }
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
        // 老版本保存的是电脑 IP；首次升级时把它带到新的完整直播地址设置里。
        if UserDefaults.standard.object(forKey: "streamURL") == nil {
            streamURL = "http://\(pcIP):8899/obs/live.m3u8"
        }
        if let savedMode = Link.savedNetworkMode() {
            netMode = savedMode
        }
        StreamDecoder.dlog("boot netMode=\(netMode) streamCfg=\(Link.streamEnabled()) url=\(builtURL)")
        usingStreamSource = Link.streamEnabled() || netMode
        fakeCameraOn = usingStreamSource
        // 重活全扔后台，主线程只发指令（不然启动超时会被系统掐死）
        DispatchQueue.global(qos: .userInitiated).async {
            self.cam.start()   // 一打开就唤醒相机进程，内核跟着自动注入
            self.keepAliveAudio()   // 静音保活：退后台也继续收画面
        }
        vcu.start()   // 开门 28765，等万相电脑端连
        if fakeCameraOn { vcamControl(true) }
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
        if Date().timeIntervalSince(cameraCommandAt) > 2 && !usingStreamSource {
            fakeCameraOn = playingFake
        }
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
        let previousBytes = lastES
        let cur = usingHLSSource ? hlsSource.frameCount : (usingStreamSource ? vcu.videoByteCount() : Link.vcamStamp())
        let progressing = previousBytes >= 0 && cur > previousBytes
        if lastTick.timeIntervalSince(now) > 0.7, cur >= 0, lastES >= 0 {
            let dt = now.timeIntervalSince(lastTick)
            kbps = max(0, Double(cur - lastES) * 8.0 / dt / 1000.0)
        }
        lastES = cur
        lastTick = now

        guard state == .starting || state == .live || state == .broken else { return }
        if fakeCameraOn && cur > 0 {
            if progressing || st["stream"] == "帧模式" || st["stream"] == "文件模式" {
                state = .live
                stuckCount = 0
            } else {
                stuckCount += 1
                if stuckCount >= 8 {
                    stuckCount = 0
                    state = .broken
                    autoRetry()
                }
            }
        } else if cur <= 0 || (!fakeCameraOn && state == .live) {
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
            if fakeCameraOn { vcamControl(true) }
        } else {
            retryCount += 1
        }
        startLive()
    }

    private func startLive() {
        state = .starting
        stuckCount = 0
        vcamControl(true)
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
        case .starting: return netMode ? "正在连接局域网…" : "正在启动 USB…"
        case .live: return netMode ? "停止局域网接收" : "停止直连"
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
        Link.saveNetworkMode(false)
        hasPickedVideo = false
        hint = "USB直连：电脑画面走数据线"
        if state == .live || state == .starting { startLive() } else {
            Link.send(["cmd": "mode", "mode": "file", "url": builtURL])
        }
        vcamControl(true)
    }

    private func tapNetwork() {
        netMode = true
        Link.saveNetworkMode(true)
        hasPickedVideo = false
        hint = "局域网：电脑需开启 OBS 或其他直播软件，地址为 \(builtURL)"
        if state == .live || state == .starting { startLive() } else {
            Link.send(["cmd": "mode", "mode": "stream", "url": builtURL])
        }
        vcamControl(true)
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
        vcamControl(false)   // 真正切回真镜头
        Link.send(["cmd": "reset"])
    }

    private func setStreamMode(_ enabled: Bool) throws {
        let url = Link.streamCfgURL
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let activeLine = "active=\(enabled ? 1 : 0)"
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("active=") }) {
            lines[index] = activeLine
        } else {
            lines.insert(activeLine, at: 0)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // USB 直连用 VCU1 解码帧；局域网用 AVPlayer 拉 HLS 并发布 IOSurface；相册仍走文件模式。
    private func vcamControl(_ on: Bool) {
        let path = "/var/mobile/Media/DCIM/vcam.mp4"
        let plistPath = "/var/mobile/Media/DCIM/vcam.plist"
        let useUSBStream = on && !netMode && !hasPickedVideo
        let useHLS = on && netMode
        let useStream = useUSBStream || useHLS
        Link.saveNetworkMode(netMode)
        StreamDecoder.dlog("vcamControl on=\(on) netMode=\(netMode) useUSB=\(useUSBStream) useHLS=\(useHLS) url=\(builtURL)")
        if useHLS {
            let scheme = URL(string: builtURL)?.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else {
                hint = "请先填写完整的电脑直播地址（http://...）"
                return
            }
        }
        if on && !useStream && !FileManager.default.fileExists(atPath: path) {
            fakeCameraOn = false
            hint = "没有可播放视频，请先选视频或推送素材"
            return
        }
        var p: [String: Any] = [
            "masterEnabled": false, "enabled": false,
            "flipHorizontal": false, "flipVertical": false,
            "rotation": 0,
            "sourcePath": path,
            "generation": 1,
        ]
        if let d = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
           let loaded = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] {
            p = loaded
        }
        p["masterEnabled"] = on && !useStream
        p["enabled"] = on && !useStream
        p["generation"] = (p["generation"] as? Int ?? 0) + 1
        p["sourcePath"] = path
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
            if useStream {
                try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
                try setStreamMode(true)
                if useHLS, let url = URL(string: builtURL) {
                    StreamDecoder.dlog("HLS start requested \(url.absoluteString)")
                    hlsSource.start(url: url)
                } else {
                    hlsSource.stop()
                }
            } else {
                hlsSource.stop()
                try setStreamMode(false)
                try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            }
            let activeStreamSource = useStream
            if usingStreamSource != activeStreamSource || usingHLSSource != useHLS {
                lastES = -1; lastTick = Date(); kbps = 0
            }
            fakeCameraOn = on
            usingStreamSource = activeStreamSource
            usingHLSSource = useHLS
            cameraCommandAt = Date()
            if !on {
                hint = "已切回真镜头"
            } else if useHLS {
                hint = "正在连接电脑画面：\(builtURL)"
            } else if useUSBStream {
                hint = vcu.alive ? "电脑实时流已启用" : "实时流已启用，等待电脑推流"
            } else {
                hint = "已切换：相机放视频"
            }
        } catch {
            hint = "切换失败，请检查 AuxCam 文件权限"
        }
    }
}
