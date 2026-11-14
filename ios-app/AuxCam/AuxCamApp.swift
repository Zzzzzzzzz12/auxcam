// AuxCam 手机端（整理版 v5）
//
// 只做一件事：
//   电脑发画面（USB 或 WiFi，端口 28765，VCU1 协议）
//   → 手机解码（视频：硬件能用就用硬件，不能用自动换软件；图片：CPU 两路并行）
//   → 节拍器排队，按固定节奏放出
//   → 写进共享内存 /var/mobile/Media/DCIM/.frame.ring
//   → 相机插件 AuxCamStream（只在系统相机进程里）读取它，把系统相机的画面换掉
//
// 和插件的约定（不能改）：
//   stream.cfg 里 active=1 / 0     打开 / 关闭替换
//
// 日志：/var/mobile/Media/DCIM/.dec.log（每 5 秒一行"状态"，排查问题主要看它）
import SwiftUI
import AVFoundation
import VideoToolbox
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO
import UserNotifications
import Darwin
import os

let kAppVersion = "整理版 v5（2026-11-13）"

@main
struct AuxCamApp: App {
    var body: some Scene {
        WindowGroup { MainView() }
    }
}

// MARK: - 文件位置

enum Paths {
    static let dcim = "/var/mobile/Media/DCIM"
    static let log = dcim + "/.dec.log"
    static let streamCfg = dcim + "/stream.cfg"
    static let pluginBeat = dcim + "/.auxcam-stream-heartbeat"
    static let vcamPlist = dcim + "/vcam.plist"
}

// MARK: - 日志（后台线程写文件，超过 8MB 换新文件，旧的留一份 .dec.log.1）

enum Log {
    private static let queue = DispatchQueue(label: "auxcam.log", qos: .utility)
    private static let runID = String(UUID().uuidString.prefix(8))
    private static var handle: FileHandle?
    private static var written: UInt64 = 0

    static func write(_ text: String) {
        let line = String(format: "%.3f [%@] ", Date().timeIntervalSince1970, runID) + text + "\n"
        queue.async {
            if handle == nil { open() }
            guard let handle, let data = line.data(using: .utf8) else { return }
            do { try handle.write(contentsOf: data) } catch { self.handle = nil; return }
            written += UInt64(data.count)
            if written > 8_000_000 { rotate() }
        }
    }

    private static func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Paths.log) { fm.createFile(atPath: Paths.log, contents: nil) }
        handle = FileHandle(forWritingAtPath: Paths.log)
        written = (try? handle?.seekToEnd()) ?? 0
    }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let old = Paths.log + ".1"
        try? FileManager.default.removeItem(atPath: old)
        try? FileManager.default.moveItem(atPath: Paths.log, toPath: old)
        open()
    }
}

// MARK: - 统计（各线程往里加数，界面每秒取一次）

final class Stats {
    struct Snapshot {
        var recvFrames = 0, recvBytes = 0
        var decoded = 0, decodeErrors = 0, gopDrops = 0
        var decodeMsSum = 0.0, decodeMsMax = 0.0
        var published = 0, publishFail = 0, underflow = 0, overflow = 0

        mutating func merge(_ o: Snapshot) {
            recvFrames += o.recvFrames; recvBytes += o.recvBytes
            decoded += o.decoded; decodeErrors += o.decodeErrors; gopDrops += o.gopDrops
            decodeMsSum += o.decodeMsSum; decodeMsMax = max(decodeMsMax, o.decodeMsMax)
            published += o.published; publishFail += o.publishFail
            underflow += o.underflow; overflow += o.overflow
        }
    }

    private let lock = NSLock()
    private var current = Snapshot()

    func add(_ change: (inout Snapshot) -> Void) {
        lock.lock(); change(&current); lock.unlock()
    }

    func take() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let s = current
        current = Snapshot()
        return s
    }
}

// MARK: - 节拍器（抖动缓冲）
// 解码好的画面先排队，再按固定节奏一张一张写进共享内存。
// 电脑 / 网络送画面时快时慢，直接交出去相机里就一顿一顿；排几张队就能抹平。
// 网络抖得厉害时自动多排一张（最多 8 张，约 0.27 秒），稳定 1 分钟后再慢慢减回来。

final class Pacer {
    private let stats: Stats
    private let lock = NSLock()
    private var queue: [(CVPixelBuffer, Bool)] = []
    private var primed = false
    private var holdTicks = 0
    private var catchUpTicks = 0
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "auxcam.pacer", qos: .userInteractive)

    private(set) var fps: Double = 30
    private var minTarget = 2
    private var target = 2
    /// 现在缓冲几张（界面显示用）
    var bufferCount: Int { lock.lock(); defer { lock.unlock() }; return target }
    private var lastPushAt: Double = 0
    private var emptySince: Double = 0        // 队列空了的时刻；下一张很快又来了才算"供不上"（电脑停推不算）
    private var underflowTimes: [Double] = []
    private var lastUnderflowAt: Double = 0
    private var arrivals = 0
    private var windowStart: Double = 0
    private var windowBroken = false          // 这段时间里断过流（开始/停止/切换），测出来的帧率不算数
    private var avgInterval = 1.0 / 30        // 最近画面到达的平均间隔（平滑过的）
    private var fpsMismatchWindows = 0
    private var latestFrame: (CVPixelBuffer, Bool)?

    init(stats: Stats) { self.stats = stats }

    /// USB 时最少排 2 张，WiFi 时最少排 3 张（WiFi 天生更抖）
    func setMinimumBuffer(_ n: Int) {
        lock.lock()
        minTarget = n
        if target < n { target = n }
        lock.unlock()
    }

    func push(_ buffer: CVPixelBuffer, limitedRange: Bool) {
        let now = CACurrentMediaTime()
        lock.lock()
        queue.append((buffer, limitedRange))
        if lastPushAt > 0 {
            let gap = now - lastPushAt
            if gap > 0.25 { windowBroken = true } else { avgInterval = avgInterval * 0.95 + gap * 0.05 }
        }
        lastPushAt = now
        arrivals += 1
        var underflow = false
        if emptySince > 0 {
            underflow = now - emptySince < 0.5   // 空了一下又马上来了 = 中途断档（相机会重复上一张）
            emptySince = 0
            if underflow { noteUnderflow(now) }
        }
        let needStart = timer == nil
        lock.unlock()
        if underflow { stats.add { $0.underflow += 1 } }
        if needStart { startTimer() }
    }

    func reset() {
        lock.lock()
        queue.removeAll()
        primed = false
        holdTicks = 0
        lock.unlock()
    }

    /// 最近放出去的一张（给界面预览用）
    func latest() -> (CVPixelBuffer, Bool)? {
        lock.lock(); defer { lock.unlock() }
        return latestFrame
    }

    private func startTimer() {
        lock.lock()
        if timer != nil { lock.unlock(); return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / fps)), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        windowStart = CACurrentMediaTime()
        lock.unlock()
        t.resume()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        var out: (CVPixelBuffer, Bool)?
        var dropped = 0
        lock.lock()
        if queue.isEmpty {
            if primed && emptySince == 0 { emptySince = now }
            primed = false
            holdTicks = 0
        } else {
            if !primed {
                if queue.count >= target {
                    primed = true
                } else {
                    holdTicks += 1
                    if holdTicks >= 3 { primed = true }   // 帧率低、凑不齐时，最多扣 3 拍就放
                }
            }
            if primed {
                holdTicks = 0
                // 积压了（网络卡一下之后一下子涌进来一堆）：慢慢追，每 5 拍最多丢 1 张，
                // 画面只是稍微快一点点，不会"跳一下"；积压超过半秒才一次性丢到正常水平。
                if queue.count > target + 15 {
                    while queue.count > target + 2 { queue.removeFirst(); dropped += 1 }
                } else if queue.count > target + 6 {
                    queue.removeFirst(); dropped += 1     // 来得明显比放得快（比如电脑发 60 帧）：每拍匀着丢 1 张
                } else if queue.count > target + 2 {
                    catchUpTicks += 1
                    if catchUpTicks >= 5 { catchUpTicks = 0; queue.removeFirst(); dropped += 1 }
                } else {
                    catchUpTicks = 0
                }
                out = queue.removeFirst()
                latestFrame = out
            }
        }
        if target > minTarget && lastUnderflowAt > 0 && now - lastUnderflowAt > 60 {
            target -= 1
            lastUnderflowAt = now
            Log.write("网络稳定了，缓冲减到 \(target) 张")
        }
        var adaptFPS = now - windowStart >= 2.0
        var measured = 0.0
        if adaptFPS {
            measured = Double(arrivals) / (now - windowStart)
            if windowBroken || now - lastPushAt > 0.25 {
                adaptFPS = false
                fpsMismatchWindows = 0
            }
            windowBroken = false
            arrivals = 0
            windowStart = now
        }
        lock.unlock()

        if dropped > 0 { stats.add { $0.overflow += dropped } }
        if let out {
            let r = auxcam_publish_frame(out.0, out.1 ? 1 : 0)
            stats.add { if r == 1 { $0.published += 1 } else { $0.publishFail += 1 } }
        }
        if adaptFPS && measured > 5 { adaptRate(measured) }
    }

    // 在锁里调用
    private func noteUnderflow(_ now: Double) {
        // 电脑本来就发得比节拍器慢（比如 25 帧）：这是帧率没对上，不是网络抖，不加缓冲（等帧率自动对上）
        if 1 / avgInterval < fps - 2 { return }
        lastUnderflowAt = now
        underflowTimes.append(now)
        underflowTimes.removeAll { now - $0 > 10 }
        if underflowTimes.count >= 2 && target < 8 {
            target += 1
            underflowTimes.removeAll()
            Log.write("画面供不上（网络或解码抖动），缓冲加到 \(target) 张")
        }
    }

    /// 电脑发的少于 30 帧（比如 25）时，节拍器跟着改，避免一直"缺一张补一张"
    private func adaptRate(_ measured: Double) {
        // 最高 30：相机本身就是 30 帧，电脑发 60 帧也只按 30 帧放（多的匀着丢掉）
        let standard: [Double] = [15, 20, 24, 25, 30]
        let nearest = standard.min { abs($0 - measured) < abs($1 - measured) } ?? 30
        lock.lock()
        if abs(nearest - fps) < 0.5 || abs(measured - nearest) > 2.5 {
            fpsMismatchWindows = 0
            lock.unlock()
            return
        }
        fpsMismatchWindows += 1
        guard fpsMismatchWindows >= 2, let timer else { lock.unlock(); return }   // 连续 4 秒都对不上才改
        fpsMismatchWindows = 0
        fps = nearest
        target = minTarget
        underflowTimes.removeAll()
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / nearest)), leeway: .milliseconds(1))
        lock.unlock()
        Log.write("电脑帧率约 \(Int(measured.rounded()))，节拍器改为 \(Int(nearest)) 帧/秒")
    }
}

// MARK: - H.264 工具

enum H264 {
    /// 把一帧拆成一个个 NAL（返回每个 NAL 内容所在的范围）。支持 Annex-B（00 00 00 01）和 4 字节长度前缀两种格式。
    /// 先按"长度前缀"严格试一遍（长度正好首尾相接、每个 NAL 头都合法才算）；不是再按 Annex-B 拆。
    /// 不能只看开头是不是 00 00 01：长度在 256~511 之间时，长度前缀的开头也恰好是 00 00 01 xx。
    static func nalUnits(_ data: Data) -> [Range<Int>] {
        data.withUnsafeBytes { raw -> [Range<Int>] in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 4 else { return [] }
            let n = raw.count
            var lengthPrefixed: [Range<Int>] = []
            var j = 0
            while j + 4 <= n {
                let len = Int(p[j]) << 24 | Int(p[j + 1]) << 16 | Int(p[j + 2]) << 8 | Int(p[j + 3])
                j += 4
                guard len > 0, j + len <= n, p[j] & 0x80 == 0, (1...23).contains(p[j] & 0x1F) else {
                    lengthPrefixed = []
                    break
                }
                lengthPrefixed.append(j..<(j + len))
                j += len
            }
            if j == n && !lengthPrefixed.isEmpty { return lengthPrefixed }
            let annexB = (p[0] == 0 && p[1] == 0 && p[2] == 1) || (p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1)
            if annexB {
                var starts: [(code: Int, body: Int)] = []
                var i = 0
                while i + 2 < n {
                    if p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 {
                        starts.append((i > 0 && p[i - 1] == 0 ? i - 1 : i, i + 3))
                        i += 3
                    } else {
                        i += 1
                    }
                }
                var out: [Range<Int>] = []
                for k in starts.indices {
                    let body = starts[k].body
                    var end = k + 1 < starts.count ? starts[k + 1].code : n
                    while end > body && p[end - 1] == 0 { end -= 1 }
                    if end > body { out.append(body..<end) }
                }
                return out
            }
            return []
        }
    }

    static func type(_ data: Data, _ r: Range<Int>) -> UInt8 { data[r.lowerBound] & 0x1F }

    static func containsIDR(_ data: Data) -> Bool {
        nalUnits(data).contains { type(data, $0) == 5 }
    }

    /// 这个画面切片是不是 B 帧（slice_type 除以 5 余 1）
    static func isBSlice(_ data: Data, _ r: Range<Int>) -> Bool {
        let t = type(data, r)
        guard t == 1 || t == 5, r.count > 1 else { return false }
        var reader = BitReader(rbsp: data[(r.lowerBound + 1)..<min(r.upperBound, r.lowerBound + 16)])
        guard reader.ue() != nil, let sliceType = reader.ue() else { return false }
        return sliceType % 5 == 1
    }

    /// 读 PPS 里的 entropy_coding_mode_flag：true = CABAC（解码慢一倍多），false = CAVLC（快）
    static func ppsUsesCABAC(_ pps: Data) -> Bool? {
        var reader = BitReader(rbsp: pps.dropFirst())
        guard reader.ue() != nil, reader.ue() != nil, let flag = reader.bit() else { return nil }
        return flag == 1
    }

    struct BitReader {
        private var bytes: [UInt8] = []
        private var pos = 0
        init(rbsp: Data.SubSequence) {
            var zeros = 0
            for b in rbsp {   // 去掉防竞争字节 00 00 03
                if zeros >= 2 && b == 3 { zeros = 0; continue }
                bytes.append(b)
                zeros = b == 0 ? zeros + 1 : 0
            }
        }
        mutating func bit() -> Int? {
            guard pos < bytes.count * 8 else { return nil }
            let v = Int(bytes[pos / 8] >> (7 - UInt8(pos % 8))) & 1
            pos += 1
            return v
        }
        mutating func ue() -> Int? {
            var zeros = 0
            while let b = bit(), b == 0 { zeros += 1; if zeros > 31 { return nil } }
            var v = 0
            for _ in 0..<zeros { guard let b = bit() else { return nil }; v = v << 1 | b }
            return (1 << zeros) - 1 + v
        }
    }
}

// MARK: - 视频解码
// 硬件解码（VideoToolbox）能用就用（又快又省电）；第一次失败就换软件解码（OpenH264），本次运行不再来回切。
// 收到的帧按顺序排队解，不乱丢（H.264 后一帧依赖前一帧）；真积压太多才整段丢到下一个关键帧。

final class VideoDecoder {
    enum Mode: Int { case auto = 0, software = 1, hardware = 2 }
    private enum Item { case config(Data, Data), frame(Data) }

    private let pacer: Pacer
    private let stats: Stats
    private let queue = DispatchQueue(label: "auxcam.h264", qos: .userInitiated)

    // 排队（收数据线程放、解码线程取）
    private let pendingLock = NSLock()
    private var pending: [Item] = []
    private var pendingFrames = 0
    private var draining = false
    private var skipToIDR = false
    private static let maxPending = 45      // 约 1.5 秒
    private static let catchUpAtIDR = 8     // 关键帧到来时还积压这么多帧 = 落后了，直接从这个关键帧追上

    // 以下只在 queue 上用
    private var sps = Data(), pps = Data()
    private var format: CMVideoFormatDescription?
    private var limitedRange = false
    private var mode: Mode
    private var hardwareBrokenThisRun = false
    private var vt: VTDecompressionSession?
    private var soft: UnsafeMutableRawPointer?
    private var softNeedsParams = true
    private var softErrorStreak = 0
    private var hardMissStreak = 0          // 硬件解码"没报错但没出画面"的连续次数
    private var streamHasB = false          // 码流里出现过 B 帧：软件解码就不能"立刻出画面"，要让解码器按顺序排
    private var waitIDR = true

    // 给界面看
    private let infoLock = NSLock()
    private var _backend = "等待画面"
    var backend: String { infoLock.lock(); defer { infoLock.unlock() }; return _backend }

    init(pacer: Pacer, stats: Stats, mode: Mode) {
        self.pacer = pacer
        self.stats = stats
        self.mode = mode
    }

    // ── 收数据线程调用 ──

    func setConfig(sps: Data, pps: Data) {
        pendingLock.lock()
        // 旧参数下排着的帧不能拿新参数去解，全部丢掉
        pending.removeAll()
        pendingFrames = 0
        pending.append(.config(sps, pps))
        skipToIDR = false
        startDrainLocked()
        pendingLock.unlock()
    }

    func feed(_ data: Data) {
        let isIDR = H264.containsIDR(data)
        var dropped = 0
        pendingLock.lock()
        if isIDR {
            if pendingFrames >= Self.catchUpAtIDR {
                dropped = dropFramesLocked()
            }
            skipToIDR = false
            appendFrameLocked(data)
        } else if skipToIDR {
            dropped = 1
        } else if pendingFrames >= Self.maxPending {
            dropped = dropFramesLocked() + 1
            skipToIDR = true
        } else {
            appendFrameLocked(data)
        }
        startDrainLocked()
        pendingLock.unlock()
        if dropped > 1 {
            stats.add { $0.gopDrops += 1 }
            Log.write("解码跟不上，丢掉积压的 \(dropped) 帧，从关键帧接上")
        }
    }

    func setMode(_ m: Mode) {
        queue.async {
            self.mode = m
            self.hardwareBrokenThisRun = false
            Log.write("解码方式改为：\(["自动", "软件", "硬件"][m.rawValue])")
            self.rebuild()
        }
    }

    private func appendFrameLocked(_ data: Data) {
        pending.append(.frame(data))
        pendingFrames += 1
    }

    private func dropFramesLocked() -> Int {
        let n = pendingFrames
        pending.removeAll { if case .frame = $0 { return true } else { return false } }
        pendingFrames = 0
        return n
    }

    private func startDrainLocked() {
        guard !draining, !pending.isEmpty else { return }
        draining = true
        queue.async { self.drain() }
    }

    private func drain() {
        while true {
            pendingLock.lock()
            guard !pending.isEmpty else {
                draining = false
                pendingLock.unlock()
                return
            }
            let item = pending.removeFirst()
            if case .frame = item { pendingFrames -= 1 }
            pendingLock.unlock()
            switch item {
            case .config(let s, let p): applyConfig(sps: s, pps: p)
            case .frame(let d): decode(d)
            }
        }
    }

    // ── 以下都在解码线程 ──

    private func applyConfig(sps newSPS: Data, pps newPPS: Data) {
        guard newSPS.count > 3, newPPS.count > 1 else { return }
        if newSPS == sps && newPPS == pps && (vt != nil || soft != nil) {
            waitIDR = true
            return
        }
        sps = newSPS
        pps = newPPS
        format = nil
        streamHasB = false
        var fmt: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p -> OSStatus in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        var size = "?"
        if status == noErr, let fmt {
            format = fmt
            let full = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool ?? false
            limitedRange = !full
            let d = CMVideoFormatDescriptionGetDimensions(fmt)
            size = "\(d.width)x\(d.height)"
        } else {
            limitedRange = false
        }
        let profile = sps.count > 1 ? Int(sps[1]) : 0
        let profileName = [66: "Baseline", 77: "Main", 100: "High"][profile] ?? "profile\(profile)"
        let cabac = H264.ppsUsesCABAC(pps)
        let coder = cabac == nil ? "?" : (cabac! ? "CABAC（解码慢）" : "CAVLC（解码快）")
        Log.write("收到视频参数：\(size) \(profileName) 编码=\(coder) 范围=\(limitedRange ? "窄(会自动拉伸)" : "全") 格式状态=\(status)")
        if cabac == true {
            Log.write("提示：电脑端用的是 CABAC 编码，软件解码会慢一倍多。电脑端加 -coder cavlc 可以快很多")
        }
        rebuild()
    }

    private func rebuild() {
        if let vt { VTDecompressionSessionInvalidate(vt) }
        vt = nil
        if let soft { auxh264_destroy(soft) }
        soft = nil
        waitIDR = true
        softErrorStreak = 0
        guard !sps.isEmpty else { return }
        let wantHardware = mode == .hardware || (mode == .auto && !hardwareBrokenThisRun)
        if wantHardware, makeHardware() {
            setInfo("硬件解码")
            Log.write("用硬件解码")
            return
        }
        makeSoftware()
    }

    private func makeHardware() -> Bool {
        guard let format else { return false }
        // 只要求像素格式，不要求 IOSurface（这台越狱机上带 IOSurface 要求会失败）
        let pixelFormat = limitedRange ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat)] as CFDictionary
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                                  decoderSpecification: nil, imageBufferAttributes: attrs,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else {
            Log.write("硬件解码建不起来 status=\(status)")
            return false
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        vt = session
        return true
    }

    private func makeSoftware() {
        soft = auxh264_create()
        softNeedsParams = true
        setInfo(soft != nil ? "软件解码" : "软件解码器建不起来")
        Log.write(soft != nil ? "用软件解码（OpenH264 单线程）" : "软件解码器建不起来")
    }

    private func decode(_ data: Data) {
        let nals = H264.nalUnits(data)
        guard !nals.isEmpty else { return }
        var hasIDR = false, hasVCL = false
        var inlineSPS: Data?, inlinePPS: Data?
        for r in nals {
            switch H264.type(data, r) {
            case 5: hasIDR = true; hasVCL = true
            case 1:
                hasVCL = true
                if !streamHasB && H264.isBSlice(data, r) {
                    streamHasB = true
                    Log.write("提示：电脑端发的视频带 B 帧，软件解码会多一帧延迟。电脑端把 B 帧设成 0 更好")
                }
            case 7: inlineSPS = data.subdata(in: r)
            case 8: inlinePPS = data.subdata(in: r)
            default: break
            }
        }
        // 帧里自带参数，且和当前不同（电脑换了分辨率等）→ 当作新参数
        if let s = inlineSPS, let p = inlinePPS, s != sps || p != pps {
            applyConfig(sps: s, pps: p)
        }
        guard hasVCL else { return }
        if vt == nil && soft == nil {
            if sps.isEmpty { return }   // 还没收到参数
            rebuild()
        }
        if waitIDR {
            guard hasIDR else { return }
            waitIDR = false
        }
        let t0 = CACurrentMediaTime()
        if vt != nil {
            switch decodeHardware(data, nals: nals, isIDR: hasIDR) {
            case .ok:
                hardMissStreak = 0
                noteDecoded(t0)
                return
            case .noImage where hardMissStreak < 2:
                hardMissStreak += 1          // 偶尔一帧没出画面：先忍着，连续 3 次才算硬件不行
                return
            default:
                break
            }
            hardMissStreak = 0
            // 硬件不行了：本次运行换成软件，不再来回切（来回切会反复卡顿）
            hardwareBrokenThisRun = true
            if let vt { VTDecompressionSessionInvalidate(vt) }
            vt = nil
            Log.write("硬件解码失败，换成软件解码（本次运行不再试硬件）")
            makeSoftware()
            if !hasIDR { waitIDR = true; return }
        }
        decodeSoftware(data, nals: nals, isIDR: hasIDR, t0: t0)
    }

    private enum HardResult { case ok, noImage, failed }

    private func decodeHardware(_ data: Data, nals: [Range<Int>], isIDR: Bool) -> HardResult {
        guard let session = vt, let format else { return .failed }
        var avcc = Data()
        for r in nals {
            let t = H264.type(data, r)
            guard t == 1 || t == 5 else { continue }
            var len = UInt32(r.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(data[r])
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return .failed }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return .failed }
        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sample) == noErr, let sample else { return .failed }
        var outStatus: OSStatus = -1
        var outImage: CVImageBuffer?
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
            outStatus = st
            outImage = image
        }
        if status == noErr && outImage == nil && outStatus == -1 {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        guard status == noErr, outStatus == noErr else {
            Log.write("硬件解码这一帧失败 decode=\(status) callback=\(outStatus) 关键帧=\(isIDR)")
            return .failed
        }
        guard let image = outImage else {
            Log.write("硬件解码这一帧没出画面 关键帧=\(isIDR)")
            return .noImage
        }
        pacer.push(image, limitedRange: limitedRange)
        return .ok
    }

    private func decodeSoftware(_ data: Data, nals: [Range<Int>], isIDR: Bool, t0: Double) {
        guard let soft else { return }
        // OpenH264 吃 Annex-B。参数集只在解码器刚建好时补一次（每帧都补它会判坏帧，实测）。
        var input = Data()
        if softNeedsParams {
            let hasParams = nals.contains { H264.type(data, $0) == 7 }
            if !hasParams {
                input.append(contentsOf: [0, 0, 0, 1]); input.append(sps)
                input.append(contentsOf: [0, 0, 0, 1]); input.append(pps)
            }
            softNeedsParams = false
        }
        // 只送到这一帧最后一个画面 NAL 为止：有的电脑端会把"下一个关键帧的参数"粘在这一帧末尾，
        // OpenH264 见到会把这一帧吞掉（实测每个关键帧前丢 1 帧）。参数前面已经处理过，这里不用送。
        let lastVCL = nals.lastIndex { let t = H264.type(data, $0); return t == 1 || t == 5 } ?? (nals.count - 1)
        for r in nals[...lastVCL] {
            input.append(contentsOf: [0, 0, 0, 1])
            input.append(data[r])
        }
        var out: Unmanaged<CVPixelBuffer>?
        let result = input.withUnsafeBytes { raw -> Int32 in
            auxh264_decode(soft, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), streamHasB ? 0 : 1, &out)
        }
        if result < 0 {
            softErrorStreak += 1
            stats.add { $0.decodeErrors += 1 }
            if softErrorStreak == 1 || softErrorStreak % 30 == 0 {
                Log.write("软件解码出错 result=\(result) 连续=\(softErrorStreak)")
            }
            if softErrorStreak >= 30 {   // 连续 1 秒都在错：重建解码器，从下个关键帧重来
                Log.write("软件解码连续出错，重建解码器")
                if let s = self.soft { auxh264_destroy(s) }
                self.soft = nil
                makeSoftware()
                softErrorStreak = 0
                waitIDR = true
            }
            return
        }
        softErrorStreak = 0
        if let image = out?.takeRetainedValue() {
            pacer.push(image, limitedRange: limitedRange)
            noteDecoded(t0)
        }
    }

    private func noteDecoded(_ t0: Double) {
        let ms = (CACurrentMediaTime() - t0) * 1000
        stats.add {
            $0.decoded += 1
            $0.decodeMsSum += ms
            $0.decodeMsMax = max($0.decodeMsMax, ms)
        }
    }

    private func setInfo(_ backend: String) {
        infoLock.lock(); _backend = backend; infoLock.unlock()
    }
}

// MARK: - 图片（MJPEG）解码：兼容旧的电脑端
// 本机硬件 JPEG 解码一直用不了，全靠 CPU：两个工人同时解，来不及时只解最新的。

final class JPEGWorker {
    let queue: DispatchQueue
    private var pool: CVPixelBufferPool?
    private var poolW = 0, poolH = 0
    private var bgra: CVPixelBuffer?
    private var transfer: VTPixelTransferSession?
    private lazy var softwareContext = CIContext(options: [.useSoftwareRenderer: true])
    private var failCount = 0

    init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    deinit { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }

    private func outputBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolW != w || poolH != h {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                kCVPixelBufferWidthKey as String: NSNumber(value: w),
                kCVPixelBufferHeightKey as String: NSNumber(value: h)
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                    [kCVPixelBufferPoolMinimumBufferCountKey as String: NSNumber(value: 8)] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p; poolW = w; poolH = h
        }
        var out: CVPixelBuffer?
        if let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess { return out }
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &out)
        return out
    }

    /// 只能在自己的 queue 上调用。返回一张新的 NV12（全范围）画面。
    func convert(_ data: Data) -> CVPixelBuffer? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            failCount += 1
            if failCount <= 3 || failCount % 90 == 0 { Log.write("图片解不开 bytes=\(data.count) 累计=\(failCount)") }
            return nil
        }
        let w = image.width & ~1, h = image.height & ~1
        guard w > 0, h > 0 else { return nil }
        if bgra == nil || CVPixelBufferGetWidth(bgra!) != w || CVPixelBufferGetHeight(bgra!) != h {
            var b: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &b)
            bgra = b
        }
        guard let bgra, let out = outputBuffer(w, h) else { return nil }
        CVPixelBufferLockBaseAddress(bgra, [])
        if let base = CVPixelBufferGetBaseAddress(bgra),
           let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(bgra), space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        CVPixelBufferUnlockBaseAddress(bgra, [])
        if transfer == nil { VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer) }
        var st: OSStatus = -1
        if let transfer { st = VTPixelTransferSessionTransferImage(transfer, from: bgra, to: out) }
        if st != noErr {
            softwareContext.render(CIImage(cvPixelBuffer: bgra), to: out,
                                   bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return out
    }
}

final class JPEGDecoder {
    private let pacer: Pacer
    private let stats: Stats
    private let workers = [JPEGWorker(label: "auxcam.jpeg.0"), JPEGWorker(label: "auxcam.jpeg.1")]
    private let lock = NSLock()
    private var busy = [false, false]
    private var waiting: (Data, Int64)?
    private var seqIn: Int64 = 0
    private var lastOut: Int64 = 0
    private var announced = false

    init(pacer: Pacer, stats: Stats) {
        self.pacer = pacer
        self.stats = stats
    }

    /// 最近 2 秒内收到过图片 = 现在是图片模式
    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return CACurrentMediaTime() - lastFeedAt < 2
    }
    private var lastFeedAt: Double = 0

    func feed(_ data: Data) {
        lock.lock()
        lastFeedAt = CACurrentMediaTime()
        if !announced { announced = true; Log.write("收到图片（MJPEG）画面，用 CPU 两路解码") }
        seqIn += 1
        let job = (data, seqIn)
        if let idle = busy.firstIndex(of: false) {
            busy[idle] = true
            lock.unlock()
            run(idle, job)
        } else {
            waiting = job   // 两个工人都在忙：只留最新一张，旧的丢掉
            lock.unlock()
        }
    }

    private func run(_ index: Int, _ first: (Data, Int64)) {
        let worker = workers[index]
        worker.queue.async {
            var job: (Data, Int64)? = first
            while let current = job {
                let (data, seq) = current
                let t0 = CACurrentMediaTime()
                let image = worker.convert(data)
                self.lock.lock()
                let fresh = seq > self.lastOut
                if image != nil && fresh { self.lastOut = seq }
                job = self.waiting
                self.waiting = nil
                if job == nil { self.busy[index] = false }
                self.lock.unlock()
                if let image, fresh {   // 两路并行，晚解完的旧图丢掉，保证顺序
                    self.pacer.push(image, limitedRange: false)
                    let ms = (CACurrentMediaTime() - t0) * 1000
                    self.stats.add { $0.decoded += 1; $0.decodeMsSum += ms; $0.decodeMsMax = max($0.decodeMsMax, ms) }
                } else if image == nil {
                    self.stats.add { $0.decodeErrors += 1 }
                }
            }
        }
    }
}

// MARK: - 手机的网络地址

enum Net {
    /// 手机在局域网里的地址：en0 = WiFi，其它 en* = 插的有线网卡（通过转换器）
    static func addresses() -> [(kind: String, ip: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [(kind: String, ip: String)] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (p.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }   // 没拿到正常地址
            result.append((name == "en0" ? "WiFi" : "有线", ip))
        }
        return result.sorted { $0.kind == "有线" && $1.kind != "有线" }   // 有线排前面（更稳）
    }
}

// MARK: - 接收电脑数据（端口 28765，VCU1 协议，和以前完全一样）
// 包 = 24 字节头 + 内容。头："VCU1" + 版本(1) + 类型(1) + flags(2) + 长度(4) + 序号(4) + 时间戳(8)，大端。
// 类型：1 = 视频参数（AVCC） 2 = 视频帧（flags bit0 = 关键帧） 5 = 心跳 10 = 图片（整张 JPEG）
// 8 秒收不到任何数据就当断开。新连接来了会顶掉旧连接。

final class Receiver {
    static let port: UInt16 = 28765

    var onConfig: ((Data, Data) -> Void)?
    var onVideo: ((Data) -> Void)?
    var onJPEG: ((Data) -> Void)?
    var onState: ((Bool, String) -> Void)?

    private let stats: Stats
    private let lock = NSLock()
    private var generation = 0
    private var clientFD: Int32 = -1
    private var clientIP = ""

    init(stats: Stats) { self.stats = stats }

    /// 开始（或重新开始）监听。allowWiFi=false 时只接受 USB（本机 127.0.0.1）。
    func start(allowWiFi: Bool) {
        lock.lock()
        generation += 1
        let gen = generation
        if !allowWiFi && clientFD >= 0 && clientIP != "127.0.0.1" {
            shutdown(clientFD, SHUT_RDWR)   // 关掉 WiFi 时把正在用 WiFi 的连接断开
        }
        lock.unlock()
        let t = Thread { [weak self] in self?.acceptLoop(gen, allowWiFi) }
        t.name = "auxcam.accept"
        t.qualityOfService = .userInitiated
        t.start()
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    private func makeListener(_ allowWiFi: Bool) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Receiver.port.bigEndian
        addr.sin_addr.s_addr = allowWiFi ? 0 : inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private func acceptLoop(_ gen: Int, _ allowWiFi: Bool) {
        var fd: Int32 = -1
        for _ in 0..<100 {   // 上一个监听可能还没完全关掉，最多重试 10 秒
            guard isCurrent(gen) else { return }
            fd = makeListener(allowWiFi)
            if fd >= 0 { break }
            usleep(100_000)
        }
        guard fd >= 0 else {
            Log.write("端口 28765 打不开 errno=\(errno)")
            onState?(false, "端口打不开")
            return
        }
        Log.write("开始等电脑连接：端口 28765（\(allowWiFi ? "USB + WiFi" : "只接受 USB")）")
        defer { close(fd) }
        while isCurrent(gen) {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 500) > 0 else { continue }
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let c = withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) }
            }
            guard c >= 0 else { continue }
            let ip = String(cString: inet_ntoa(addr.sin_addr))
            lock.lock()
            let old = clientFD
            clientFD = c
            clientIP = ip
            lock.unlock()
            if old >= 0 { shutdown(old, SHUT_RDWR) }   // 新连接顶掉旧连接
            let t = Thread { [weak self] in self?.serve(c, ip) }
            t.name = "auxcam.recv"
            t.qualityOfService = .userInteractive
            t.start()
        }
    }

    private func recvAll(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) -> Bool {
        var got = 0
        while got < n {
            let r = recv(fd, p + got, n - got, 0)
            if r > 0 { got += r; continue }
            if r < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    private func serve(_ fd: Int32, _ ip: String) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var rcvbuf: Int32 = 4 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let peer = ip == "127.0.0.1" ? "USB" : "\(Receiver.linkKind(fd)) \(ip)"
        Log.write("电脑连上了：\(peer)")
        onState?(true, peer)

        var header = [UInt8](repeating: 0, count: 24)
        var reason = "电脑断开，或 8 秒没收到数据"
        while true {
            guard header.withUnsafeMutableBytes({ recvAll(fd, $0.baseAddress!, 24) }) else { break }
            guard header[0] == 0x56, header[1] == 0x43, header[2] == 0x55, header[3] == 0x31, header[4] == 1 else {
                reason = "数据格式不对（不是 VCU1）"
                break
            }
            let type = header[5]   // 头里的 flags（关键帧标记）不用：直接看数据里有没有关键帧，更可靠
            let len = Int(header[8]) << 24 | Int(header[9]) << 16 | Int(header[10]) << 8 | Int(header[11])
            guard len >= 0, len <= 16 << 20 else { reason = "包太大 len=\(len)"; break }
            var payload = Data(count: len)
            if len > 0 {
                guard payload.withUnsafeMutableBytes({ recvAll(fd, $0.baseAddress!, len) }) else { break }
            }
            stats.add { $0.recvBytes += 24 + len }
            switch type {
            case 1:
                if let params = Receiver.parseAVCC(payload) { onConfig?(params.0, params.1) }
            case 2:
                stats.add { $0.recvFrames += 1 }
                onVideo?(payload)
            case 10:
                stats.add { $0.recvFrames += 1 }
                onJPEG?(payload)
            default:
                break   // 5 = 心跳；其它类型忽略
            }
        }
        lock.lock()
        let wasCurrent = clientFD == fd
        if wasCurrent { clientFD = -1; clientIP = "" }
        lock.unlock()
        close(fd)
        Log.write("电脑断开（\(peer)）：\(reason)")
        if wasCurrent { onState?(false, "") }
    }

    /// 这条连接是从手机哪个网口进来的：WiFi 还是有线网卡
    static func linkKind(_ fd: Int32) -> String {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard ok == 0 else { return "网络" }
        let local = String(cString: inet_ntoa(addr.sin_addr))
        return Net.addresses().first { $0.ip == local }?.kind ?? "网络"
    }

    /// AVCDecoderConfigurationRecord → (SPS, PPS)
    static func parseAVCC(_ d: Data) -> (Data, Data)? {
        let b = [UInt8](d)
        guard b.count > 7, b[0] == 1 else { return nil }
        var i = 5
        var sps = Data(), pps = Data()
        let numSPS = Int(b[i] & 0x1F); i += 1
        for _ in 0..<numSPS {
            guard i + 2 <= b.count else { return nil }
            let l = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
            guard i + l <= b.count else { return nil }
            if sps.isEmpty { sps = Data(b[i..<(i + l)]) }
            i += l
        }
        guard i < b.count else { return nil }
        let numPPS = Int(b[i] & 0x1F); i += 1
        for _ in 0..<numPPS {
            guard i + 2 <= b.count else { return nil }
            let l = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
            guard i + l <= b.count else { return nil }
            if pps.isEmpty { pps = Data(b[i..<(i + l)]) }
            i += l
        }
        return sps.isEmpty || pps.isEmpty ? nil : (sps, pps)
    }
}

// MARK: - 总控：把上面几块接起来，并给界面提供状态

final class Engine: ObservableObject {
    static let shared = Engine()

    // 界面显示
    @Published var connected = false
    @Published var peer = ""
    @Published var inFPS = 0.0
    @Published var mbps = 0.0
    @Published var decoderName = "等待画面"
    @Published var decodeMs = 0.0
    @Published var outFPS = 0.0
    @Published var bufferTarget = 2
    @Published var pluginWorking = false
    @Published var pluginText = "—"
    @Published var preview: CGImage?
    @Published var phoneAddresses: [String] = []           // 例如 ["有线 192.168.1.50", "WiFi 192.168.1.23"]
    @Published var keepAliveOK = true                      // 后台保活（静音循环播放）是否正常
    @Published var phoneWarning: String?                   // 低电量模式 / 手机过热 / 存储快满 的提醒（没问题时为空）
    @Published var alertMessage: String?                   // 需要马上让用户知道的错误（弹窗）
    @Published var notifyAllowed = true                    // 通知权限（断流提醒靠它）

    // 设置（会保存）
    @Published var replaceOn = false
    @Published var mirror = UserDefaults.standard.bool(forKey: "mirror")
    @Published var rotation = UserDefaults.standard.integer(forKey: "rotation")
    @Published var allowWiFi = UserDefaults.standard.bool(forKey: "allowWiFi")
    @Published var decoderMode = UserDefaults.standard.integer(forKey: "decoderMode")

    let stats = Stats()
    private(set) lazy var pacer = Pacer(stats: stats)
    private(set) lazy var video = VideoDecoder(pacer: pacer, stats: stats, mode: VideoDecoder.Mode(rawValue: decoderMode) ?? .auto)
    private(set) lazy var jpeg = JPEGDecoder(pacer: pacer, stats: stats)
    private(set) lazy var receiver = Receiver(stats: stats)

    private var booted = false
    private var keepAlivePlayer: AVAudioPlayer?
    private var keepAliveFailures = 0                       // 静音连续几秒没在播
    private var backgroundGrace: UIBackgroundTaskIdentifier = .invalid   // 向系统多要的后台时间（保活出问题时用来争取恢复时间）
    private var ticks = 0
    private var logAcc = Stats.Snapshot()
    private var lastCPU = 0.0, lastWall = 0.0
    private var appActive = true
    // 断流提醒：直播中电脑画面断了，发一条带声音的通知（直播 App 在前台时也能看到）
    private var lastFrameAt: Double?        // 最近一次有画面送给相机的时间（开机后的秒数，不受改手机时间影响）
    private var outageAlerted = false       // 这次断流已经提醒过了
    private var cameraInUse = false         // 相机正在被用（插件心跳 15 秒内更新过）
    private var lastWarning: String?
    private var lastPublishFail = 0
    private var lastFreeMB = Int.max

    func boot() {
        guard !booted else { return }
        booted = true
        Log.write("========== AuxCam 启动 \(kAppVersion) ==========")
        Log.write("设置：WiFi=\(allowWiFi) 解码方式=\(["自动", "软件", "硬件"][min(2, max(0, decoderMode))]) 镜像=\(mirror) 旋转=\(rotation)")
        selfTest()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Log.write("通知权限：\(ok ? "已允许（断流时会提醒）" : "没允许（断流时没法提醒）")")
        }
        replaceOn = Engine.readActive()
        auxcam_set_transform(mirror ? 1 : 0, Int32(rotation))
        pacer.setMinimumBuffer(2)

        receiver.onConfig = { [weak self] s, p in self?.video.setConfig(sps: s, pps: p) }
        receiver.onVideo = { [weak self] d in self?.video.feed(d) }
        receiver.onJPEG = { [weak self] d in self?.jpeg.feed(d) }
        receiver.onState = { [weak self] ok, peer in
            guard let self else { return }
            self.pacer.setMinimumBuffer(peer.hasPrefix("WiFi") || peer.hasPrefix("网络") ? 3 : 2)   // USB、有线都很稳，WiFi 多排一张
            DispatchQueue.main.async {
                self.connected = ok
                self.peer = peer
            }
        }
        receiver.start(allowWiFi: allowWiFi)
        if allowWiFi { Engine.askLocalNetworkPermission() }

        keepAlive()
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.appActive = false
            let playing = self.keepAlivePlayer?.isPlaying == true
            Log.write("App 进入后台（保活\(playing ? "正常" : "没在播，先向系统多要一点后台时间，同时重试")）")
            if !playing {
                self.beginBackgroundGrace()
                self.keepAlive()
            }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appActive = true
            self?.endBackgroundGrace()
            Log.write("App 回到前台")
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            Log.write("保活声音被打断 type=\(type == .began ? "开始" : "结束")")
            if type == .ended { self?.keepAlive() }
        }
        // 系统的媒体服务重启了（媒体进程崩溃后被系统拉起）：原来的播放器已经失效，必须整个重建
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Log.write("系统媒体服务重启了：重建保活播放器")
            self.keepAlivePlayer?.stop()
            self.keepAlivePlayer = nil
            if !self.appActive { self.beginBackgroundGrace() }
            self.keepAlive()
        }

        let ui = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ui, forMode: .common)
    }

    /// 启动自检：测一下这台手机能不能建"硬件友好"的画面缓冲（建不了的话硬件解码也用不了）
    private func selfTest() {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary
        let st = CVPixelBufferCreate(kCFAllocatorDefault, 1080, 1920, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &pb)
        Log.write("自检：IOSurface 画面缓冲 status=\(st)\(st == kCVReturnSuccess ? "（正常）" : "（建不了，硬件解码大概率也用不了）")")
    }

    // ── 用户操作 ──

    func setReplace(_ on: Bool) {
        let ok = Engine.writeActive(on)
        replaceOn = Engine.readActive()          // 界面以文件里真实的状态为准，绝不"假装"已经打开
        if ok {
            Log.write(on ? "打开替换（相机画面换成电脑画面）" : "关闭替换（恢复真相机）")
        } else {
            Log.write("开关写入失败：想\(on ? "打开" : "关闭")替换，但 stream.cfg 没写进去")
            alertMessage = on ? "替换没能打开：开关文件写不进去（手机存储可能满了）。现在相机还是真实画面，先别开播。"
                              : "替换没能关闭：开关文件写不进去（手机存储可能满了）。"
        }
    }

    func setMirror(_ on: Bool) {
        mirror = on
        UserDefaults.standard.set(on, forKey: "mirror")
        auxcam_set_transform(mirror ? 1 : 0, Int32(rotation))
        Log.write("镜像 \(on ? "开" : "关")")
    }

    func setRotation(_ degrees: Int) {
        rotation = degrees
        UserDefaults.standard.set(degrees, forKey: "rotation")
        auxcam_set_transform(mirror ? 1 : 0, Int32(rotation))
        Log.write("旋转 \(degrees)°")
    }

    func setWiFi(_ on: Bool) {
        allowWiFi = on
        UserDefaults.standard.set(on, forKey: "allowWiFi")
        Log.write("WiFi 连接 \(on ? "允许" : "关闭")")
        receiver.start(allowWiFi: on)
        if on { Engine.askLocalNetworkPermission() }
    }

    func setDecoderMode(_ m: Int) {
        decoderMode = m
        UserDefaults.standard.set(m, forKey: "decoderMode")
        video.setMode(VideoDecoder.Mode(rawValue: m) ?? .auto)
    }

    // ── 每秒一次：刷新界面，每 5 秒写一行状态日志 ──

    private func tick() {
        ticks += 1
        let s = stats.take()
        logAcc.merge(s)
        inFPS = Double(s.recvFrames)
        mbps = Double(s.recvBytes) * 8 / 1_000_000
        outFPS = Double(s.published)
        decoderName = currentDecoderName
        if s.decoded > 0 { decodeMs = s.decodeMsSum / Double(s.decoded) }
        bufferTarget = pacer.bufferCount
        let addrs = Net.addresses().map { "\($0.kind) \($0.ip)" }
        if addrs != phoneAddresses { phoneAddresses = addrs }
        if s.published > 0 { lastFrameAt = CACurrentMediaTime() }
        if ticks % 10 == 1 {
            UNUserNotificationCenter.current().getNotificationSettings { st in
                let allowed = st.authorizationStatus == .authorized || st.authorizationStatus == .provisional
                DispatchQueue.main.async { if self.notifyAllowed != allowed { self.notifyAllowed = allowed } }
            }
        }
        // 每秒核对一次开关文件：被删了、被别的东西改了，界面马上如实显示
        let actual = Engine.readActive()
        if actual != replaceOn {
            Log.write("开关文件和界面不一致（文件里是 \(actual ? "开" : "关")），以文件为准")
            replaceOn = actual
        }
        lastPublishFail = s.publishFail
        updatePluginStatus()
        checkKeepAlive()
        checkOutage()
        checkPhoneHealth()
        if appActive, let latest = pacer.latest() {
            preview = Engine.makePreview(latest.0, limited: latest.1)
        }
        if ticks % 5 == 0 { writeStatusLog() }
    }

    private var currentDecoderName: String {
        jpeg.isActive ? "图片（CPU 两路解码）" : video.backend
    }

    private func writeStatusLog() {
        let a = logAcc
        logAcc = Stats.Snapshot()
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let wall = CACurrentMediaTime()
        let cpuText = lastWall > 0 ? String(format: "%.0f%%", (cpu - lastCPU) / (wall - lastWall) * 100) : "-"
        lastCPU = cpu
        lastWall = wall
        let avg = a.decoded > 0 ? a.decodeMsSum / Double(a.decoded) : 0
        let memMB = Int(os_proc_available_memory() / 1_048_576)
        Log.write(String(format: "状态 连接=%@ 收=%.1f帧/秒 %.1fMbps 解码=%@ %.1f帧/秒 平均%.1fms 最慢%.0fms 错=%d 丢段=%d 出=%.1f帧/秒 缓冲=%d张 供不上=%d 丢旧=%d 写失败=%d CPU=%@ 剩余内存=%dMB 保活=%d 替换=%d 插件=%@",
                         connected ? peer : "无", Double(a.recvFrames) / 5, Double(a.recvBytes) * 8 / 5_000_000,
                         currentDecoderName, Double(a.decoded) / 5, avg, a.decodeMsMax, a.decodeErrors, a.gopDrops,
                         Double(a.published) / 5, pacer.bufferCount, a.underflow, a.overflow, a.publishFail, cpuText, memMB,
                         keepAlivePlayer?.isPlaying == true ? 1 : 0, replaceOn ? 1 : 0, pluginWorking ? "工作中" : (cameraInUse ? "相机开着没画面" : "没在用"))
                  + " 低电量=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0) 温度=\(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    /// 插件每 150 个相机帧写一次心跳："camera=相机出了几帧 replaced=其中换成电脑画面的几帧"
    private func updatePluginStatus() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.pluginBeat)
        let age = (attrs?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) } ?? 9999
        // 心跳是一行用空格隔开的 key=value
        var replaced = 0
        if let text = try? String(contentsOfFile: Paths.pluginBeat, encoding: .utf8) {
            for token in text.split(whereSeparator: { $0 == " " || $0.isNewline }) where token.hasPrefix("replaced=") {
                replaced = Int(token.dropFirst("replaced=".count)) ?? 0
            }
        }
        let cameraOn = replaceOn && age < 15
        cameraInUse = cameraOn
        pluginWorking = cameraOn && replaced > 0
        if !replaceOn {
            pluginText = "替换已关闭，相机是真实画面"
        } else if pluginWorking {
            pluginText = "工作中：相机画面已换成电脑画面"
        } else if cameraOn {
            pluginText = "相机开着，还没收到电脑画面：相机现在是黑屏（不会露出真实画面）"
        } else {
            pluginText = "等待中：任何 App 打开相机后，会自动开始替换"
        }
    }

    // ── 断流提醒 ──
    // 相机正在用、替换开着，可是 3 秒没有新的电脑画面了：发一条带声音的通知。
    // 之前有过画面 → 直播停在最后一张；从来没有 → 直播是黑屏。恢复后再通知一次。

    private func checkOutage() {
        guard replaceOn, cameraInUse else { outageAlerted = false; return }
        let silent = lastFrameAt.map { CACurrentMediaTime() - $0 } ?? .infinity
        if silent >= 3 && !outageAlerted {
            outageAlerted = true
            let hadFrames = lastFrameAt != nil
            let body = hadFrames ? "直播画面现在停在最后一张。检查电脑推流软件和连接线 / 网络。"
                                 : "直播现在是黑屏。请在电脑上开始推流。"
            Log.write("断流提醒：\(hadFrames ? "电脑画面断了" : "还没收到电脑画面")")
            Engine.notify(title: hadFrames ? "电脑画面断了" : "还没收到电脑画面", body: body)
        } else if silent < 1 && outageAlerted {
            outageAlerted = false
            Log.write("断流提醒：电脑画面恢复了")
            Engine.notify(title: "电脑画面恢复了", body: "直播画面已经恢复正常。")
        }
    }

    static func freeSpaceMB() -> Int? {
        let values = try? URL(fileURLWithPath: Paths.dcim).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0 / 1_048_576) }
    }

    static func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "auxcam.outage", content: c, trigger: nil))
    }

    // ── 手机状态：低电量模式会让手机变慢，过热会降频，都可能让画面卡 ──

    private func checkPhoneHealth() {
        var items: [String] = []
        if ProcessInfo.processInfo.isLowPowerModeEnabled { items.append("低电量模式开着（会让手机变慢），请到 设置 → 电池 关掉") }
        switch ProcessInfo.processInfo.thermalState {
        case .serious: items.append("手机很热，可能会降速卡顿：拿掉手机壳、别边充边捂着，给手机散散热")
        case .critical: items.append("手机过热，马上会明显卡顿：请尽快给手机降温")
        default: break
        }
        if ticks % 10 == 1, let free = Engine.freeSpaceMB() { lastFreeMB = free }
        if lastFreeMB < 1024 { items.append("手机存储只剩 \(lastFreeMB)MB，快满了：请删掉一些照片、视频") }
        if lastPublishFail > 0 { items.append("电脑画面写不进去（每秒失败 \(lastPublishFail) 次）：手机存储可能满了") }
        if !notifyAllowed { items.append("通知被关掉了：电脑画面断了也没法提醒你。请到 设置 → 通知 → AuxCam 打开") }
        let w = items.isEmpty ? nil : items.joined(separator: "\n")
        if w != lastWarning {
            lastWarning = w
            Log.write("手机状态：\(w ?? "正常")")
        }
        if w != phoneWarning { phoneWarning = w }
    }

    // ── 保活：循环播放静音，退到后台也继续收画面 ──
    // 实测（旧日志约 98 小时后台）：静音一直在播，App 在后台就一直活着，一次都没被暂停过。
    // 这里再加三道保险：每秒检查、连续 3 秒没播就整个重建、媒体服务重启后重建；
    // 保活出问题且在后台时，向系统多要一段后台时间（约 30 秒），够恢复用。

    /// 每秒检查一次静音是不是还在播
    private func checkKeepAlive() {
        let playing = keepAlivePlayer?.isPlaying == true
        if playing {
            if keepAliveFailures > 0 { Log.write("保活：恢复正常（之前断了 \(keepAliveFailures) 秒）") }
            keepAliveFailures = 0
            endBackgroundGrace()
        } else {
            keepAliveFailures += 1
            if keepAliveFailures == 1 || keepAliveFailures % 10 == 0 {
                Log.write("保活：静音没在播（第 \(keepAliveFailures) 秒），正在恢复\(appActive ? "" : "（App 在后台）")")
            }
            if !appActive { beginBackgroundGrace() }
            if keepAliveFailures % 3 == 0 {      // 连着 3 秒都播不起来：把播放器整个重建
                keepAlivePlayer?.stop()
                keepAlivePlayer = nil
            }
            keepAlive()
        }
        let ok = keepAlivePlayer?.isPlaying == true
        if ok != keepAliveOK { keepAliveOK = ok }
    }

    private func beginBackgroundGrace() {
        guard backgroundGrace == .invalid else { return }
        backgroundGrace = UIApplication.shared.beginBackgroundTask(withName: "auxcam.keepalive") { [weak self] in
            Log.write("保活：系统给的额外后台时间用完了")
            self?.endBackgroundGrace()
        }
    }

    private func endBackgroundGrace() {
        guard backgroundGrace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundGrace)
        backgroundGrace = .invalid
    }

    private func keepAlive() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            Log.write("保活：声音通道打不开 \(error.localizedDescription)")
        }
        if let p = keepAlivePlayer {
            if !p.isPlaying { p.play() }
            return
        }
        let rate = 8000
        var wav = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        let dataLen = UInt32(rate * 2)
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataLen)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(dataLen)
        wav.append(Data(count: Int(dataLen)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence.wav")
        try? wav.write(to: url)
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1
        player?.volume = 0.01
        keepAlivePlayer = player
        Log.write("保活：静音播放 \(player?.play() == true ? "已开始" : "失败")")
    }

    // ── 小工具 ──

    static func parseKV(_ text: String) -> [String: String] {
        var d: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let i = line.firstIndex(of: "=") else { continue }
            d[line[..<i].trimmingCharacters(in: .whitespaces)] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return d
    }

    static func readActive() -> Bool {
        guard let t = try? String(contentsOfFile: Paths.streamCfg, encoding: .utf8) else { return false }
        let v = (parseKV(t)["active"] ?? "").lowercased()
        return v == "1" || v == "on" || v == "yes"
    }

    /// 改 stream.cfg 的 active 那一行（插件每秒读一次），其它行原样保留
    /// 写完会读回来核对，写不进去返回 false
    @discardableResult
    static func writeActive(_ on: Bool) -> Bool {
        let existing = (try? String(contentsOfFile: Paths.streamCfg, encoding: .utf8)) ?? ""
        var lines = existing.components(separatedBy: .newlines).filter {
            !$0.isEmpty && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("active")
        }
        lines.insert("active=\(on ? 1 : 0)", at: 0)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: Paths.streamCfg, atomically: true, encoding: .utf8)
        let ok = readActive() == on
        // 另一个虚拟相机插件（VCam）的开关始终保持关闭，免得两个插件抢画面
        if let data = FileManager.default.contents(atPath: Paths.vcamPlist),
           var p = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           (p["masterEnabled"] as? Bool ?? false) || (p["enabled"] as? Bool ?? false) {
            p["masterEnabled"] = false
            p["enabled"] = false
            p["generation"] = (p["generation"] as? Int ?? 0) + 1
            if let out = try? PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0) {
                try? out.write(to: URL(fileURLWithPath: Paths.vcamPlist), options: .atomic)
                Log.write("已关闭另一个虚拟相机插件（VCam）的开关")
            }
        }
        return ok
    }

    /// 苹果的"本地网络"权限：没触发过的话，WiFi 连进来可能被系统悄悄挡掉。
    /// 往局域网发一个小广播包就会触发弹窗（只第一次弹，点"允许"）。
    static func askLocalNetworkPermission() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Receiver.port.bigEndian
        addr.sin_addr.s_addr = 0xFFFF_FFFF
        let msg = Array("AuxCam".utf8)
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        Log.write("本地网络权限：已触发（发送结果 \(sent)，<0 多半是还没允许）")
    }

    /// 把 NV12 画面缩小成预览图（纯 CPU，约 480 高，不碰 GPU）
    static func makePreview(_ pb: CVPixelBuffer, limited: Bool) -> CGImage? {
        guard CVPixelBufferGetPlaneCount(pb) >= 2,
              CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let step = max(1, max(w, h) / 480)
        let ow = w / step, oh = h / step
        guard ow > 0, oh > 0 else { return nil }
        var rgba = [UInt8](repeating: 255, count: ow * oh * 4)
        rgba.withUnsafeMutableBufferPointer { out in
            for oy in 0..<oh {
                let sy = oy * step
                let yRow = yBase + sy * yStride, uvRow = uvBase + (sy / 2) * uvStride
                for ox in 0..<ow {
                    let sx = ox * step
                    var y = Float(yRow[sx]), u = Float(uvRow[sx & ~1]) - 128, v = Float(uvRow[(sx & ~1) + 1]) - 128
                    if limited { y = (y - 16) * 1.164; u *= 1.138; v *= 1.138 }
                    let r = y + 1.5748 * v, g = y - 0.1873 * u - 0.4681 * v, b = y + 1.8556 * u
                    let o = (oy * ow + ox) * 4
                    out[o] = UInt8(max(0, min(255, r)))
                    out[o + 1] = UInt8(max(0, min(255, g)))
                    out[o + 2] = UInt8(max(0, min(255, b)))
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - 界面
// 一眼看懂：最上面一句话说清楚现在好不好；中间是电脑画面；三步检查，每步好了就打勾；一个大按钮；设置收在最下面。

struct MainView: View {
    @ObservedObject private var e = Engine.shared
    @State private var showSettings: Bool
    @State private var confirmStop = false
    @State private var showCameraCheck = false

    init(showSettings: Bool = false) {
        _showSettings = State(initialValue: showSettings)
    }

    private enum Overall { case good, waitPC, waitCamera, slow, off }

    private var overall: Overall {
        if !e.replaceOn { return .off }
        if !e.connected { return .waitPC }
        if e.outFPS < 24 { return .slow }
        if !e.pluginWorking { return .waitCamera }
        return .good
    }

    private var banner: (title: String, detail: String, color: Color, icon: String) {
        switch overall {
        case .good:
            return ("一切正常", "相机里显示的是电脑画面", .green, "checkmark.circle.fill")
        case .waitPC:
            return ("等待电脑连接",
                    e.allowWiFi ? "插上 USB 线，或在电脑端填手机地址走网络" : "用 USB 线连电脑，然后在电脑上开始推流",
                    .orange, "cable.connector")
        case .slow:
            return (e.outFPS > 0 ? "画面不够流畅" : "电脑已连上，还没有画面",
                    e.outFPS > 0 ? String(format: "现在每秒只有 %.0f 张，看下面哪一步没打勾", e.outFPS) : "请在电脑上开始推流",
                    .orange, "exclamationmark.triangle.fill")
        case .waitCamera:
            return ("画面已准备好", "打开相机（开播或预览），就会自动换成电脑画面", .blue, "camera.viewfinder")
        case .off:
            return ("替换已关闭", "现在相机是真实画面", .gray, "pause.circle.fill")
        }
    }

    var body: some View {
        ScrollView { content }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .onAppear { e.boot() }
            .alert("确定恢复真相机吗？", isPresented: $confirmStop) {
                Button("恢复真相机", role: .destructive) { e.setReplace(false) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("如果正在直播，观众会马上看到手机摄像头的真实画面。")
            }
            .sheet(isPresented: $showCameraCheck) { CameraCheckView() }
            .alert("出问题了", isPresented: Binding(get: { e.alertMessage != nil }, set: { if !$0 { e.alertMessage = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(e.alertMessage ?? "")
            }
    }

    var content: some View {
        VStack(spacing: 16) {
            header
            statusBanner
            previewBox
            checklist
            if let w = e.phoneWarning { warningRow(w) }
            keepAliveRow
            mainButton
            if e.replaceOn {
                Text("替换开着时，手机上所有 App 的相机（拍照、扫码、视频通话）都会被换掉。不直播时记得停止替换。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, -8)
            }
            quickControls
            cameraCheckButton
            settings
            Text("日志：DCIM/.dec.log  ·  \(kAppVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // ── 顶部 ──

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.teal))
            Text("AuxCam").font(.title2.bold())
            Spacer()
            if e.connected {
                Label(e.peer.hasPrefix("WiFi") ? "WiFi" : (e.peer.hasPrefix("有线") ? "有线" : (e.peer == "USB" ? "USB" : "网络")),
                      systemImage: e.peer.hasPrefix("WiFi") ? "wifi" : (e.peer == "USB" ? "cable.connector" : "network"))
                    .font(.footnote.bold())
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                    .foregroundStyle(.green)
            }
        }
    }

    private var statusBanner: some View {
        let b = banner
        return HStack(spacing: 14) {
            Image(systemName: b.icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(b.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(b.title).font(.title3.bold())
                Text(b.detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18).fill(b.color.opacity(0.13)))
    }

    // ── 电脑画面预览 ──

    private var previewBox: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 16).fill(Color.black)
            if let img = e.preview {
                // 顺序必须和写给相机的一样：先顺时针旋转，再左右镜像（旋转 90°/270° 时顺序反了画面会上下颠倒）
                // 转 90°/270° 时先在"横着的框"里缩放好，转过来正好竖着放得下，整张画面都看得到
                let sideways = e.rotation == 90 || e.rotation == 270
                Image(decorative: img, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: sideways ? 356 : 200, height: sideways ? 200 : 356)
                    .rotationEffect(.degrees(Double(e.rotation)))
                    .scaleEffect(x: e.mirror ? -1 : 1, y: 1)
                    .frame(width: 200, height: 356)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "display").font(.system(size: 34))
                    Text("电脑画面会显示在这里").font(.footnote)
                }
                .foregroundStyle(.gray)
                .frame(maxHeight: .infinity)
            }
            Text(e.preview == nil ? "预览" : String(format: "电脑画面 · %.0f 帧/秒", e.outFPS))
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(10)
        }
        .frame(width: 200, height: 356)
    }

    // ── 三步检查 ──

    private var checklist: some View {
        VStack(spacing: 0) {
            step(1, done: e.connected,
                 title: e.connected ? "电脑已连接" : "电脑没连接",
                 detail: e.connected
                    ? String(format: "%@ · 每秒收到 %.0f 张 · %.1f M", e.peer, e.inFPS, e.mbps)
                    : (e.allowWiFi ? "USB 线、WiFi、有线网卡都可以" : "请插好 USB 线"))
            Divider().padding(.leading, 52)
            step(2, done: e.outFPS >= 24,
                 title: e.outFPS >= 24 ? "画面解码正常"
                    : (e.outFPS <= 0 ? "还没有画面"
                       : (e.inFPS < 24 ? "电脑发得太少" : "解码跟不上")),
                 detail: e.outFPS <= 0 ? "电脑开始推流后就会有"
                    : (e.outFPS < 24 && e.inFPS < 24
                       ? String(format: "电脑每秒只发了 %.0f 张，检查电脑端设置（应为 30 帧）", e.inFPS)
                       : String(format: "%@ · 每张 %.0f 毫秒 · 每秒 %.0f 张", e.decoderName, e.decodeMs, e.outFPS)))
            Divider().padding(.leading, 52)
            step(3, done: e.pluginWorking,
                 title: e.pluginWorking ? "相机已替换" : (e.replaceOn ? "等待打开相机" : "替换已关闭"),
                 detail: e.pluginText)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    private func step(_ n: Int, done: Bool, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color(UIColor.tertiarySystemFill)).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.footnote.bold()).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // ── 手机状态提醒（低电量模式 / 过热） ──

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "thermometer.sun.fill").foregroundStyle(.orange)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.15)))
    }

    // ── 开播前检查 ──

    private var cameraCheckButton: some View {
        Button { showCameraCheck = true } label: {
            HStack {
                Image(systemName: "camera.viewfinder")
                VStack(alignment: .leading, spacing: 2) {
                    Text("开播前检查").font(.body.weight(.semibold))
                    Text("打开相机，看看直播 App 实际会拿到什么画面").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    // ── 后台保活 ──

    private var keepAliveRow: some View {
        HStack(spacing: 10) {
            Image(systemName: e.keepAliveOK ? "moon.zzz.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(e.keepAliveOK ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.keepAliveOK ? "后台运行：正常" : "后台运行：正在恢复")
                    .font(.subheadline.bold())
                Text(e.keepAliveOK ? "切到别的 App、按 Home 键都会继续工作。不要在多任务里把 AuxCam 划掉"
                                   : "正在自动恢复，几秒内没好的话请重新打开 AuxCam")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    // ── 大按钮 ──

    private var mainButton: some View {
        Button {
            if e.replaceOn { confirmStop = true } else { e.setReplace(true) }   // 停止要再确认一次，防止直播中误碰
        } label: {
            HStack(spacing: 8) {
                Image(systemName: e.replaceOn ? "stop.fill" : "play.fill")
                Text(e.replaceOn ? "停止替换（恢复真相机）" : "开始替换相机画面")
            }
            .font(.title3.bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: 16).fill(e.replaceOn ? Color.red : Color.green))
        }
        .buttonStyle(.plain)
    }

    // ── 镜像 / 旋转：常用，放主界面，点一下就生效 ──

    private var quickControls: some View {
        HStack(spacing: 12) {
            quickButton(title: e.mirror ? "镜像：开" : "镜像：关",
                        icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                        on: e.mirror) { e.setMirror(!e.mirror) }
            quickButton(title: "旋转：\(e.rotation)°",
                        icon: "rotate.right",
                        on: e.rotation != 0) { e.setRotation((e.rotation + 90) % 360) }
        }
    }

    private func quickButton(title: String, icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 16).fill(on ? Color.teal : Color(UIColor.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    // ── 设置 ──

    private var settings: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() }
            } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                    Text("设置").font(.body.weight(.semibold))
                    Spacer()
                    Text(settingsSummary).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: showSettings ? "chevron.up" : "chevron.down").font(.footnote)
                }
                .foregroundStyle(.primary)
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showSettings {
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("允许网络连接（WiFi / 有线网卡）", isOn: Binding(get: { e.allowWiFi }, set: { e.setWiFi($0) }))
                        if e.allowWiFi {
                            if e.phoneAddresses.isEmpty {
                                Text("手机还没连上网络（WiFi 或有线网卡）").font(.callout).foregroundStyle(.orange)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("电脑端「手机 IP」填：").font(.caption).foregroundStyle(.secondary)
                                    ForEach(e.phoneAddresses, id: \.self) { line in
                                        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(parts.first ?? "").font(.caption.bold()).foregroundStyle(.secondary)
                                                .frame(width: 34, alignment: .leading)
                                            Text(parts.count > 1 ? parts[1] : line)
                                                .font(.title2.monospaced().bold())
                                                .foregroundStyle(.blue)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    Text("端口 28765（一般不用改）。有线和 WiFi 都有时，填有线那个更稳").font(.caption).foregroundStyle(.secondary)
                                    Text("电脑一直连不上：到 设置 → 隐私与安全性 → 本地网络，把 AuxCam 打开").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.08)))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("解码方式")
                        Picker("解码方式", selection: Binding(get: { e.decoderMode }, set: { e.setDecoderMode($0) })) {
                            Text("自动").tag(0)
                            Text("软件").tag(1)
                            Text("硬件").tag(2)
                        }
                        .pickerStyle(.segmented)
                        Text("一般选\"自动\"：硬件能用就用硬件，不能用自动换软件。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }

    private var settingsSummary: String {
        e.allowWiFi ? "网络已开" : "仅 USB"
    }
}

// MARK: - 开播前检查：在 App 里打开相机，看相机实际输出的画面
// 相机画面经过插件替换后才到这里，和直播 App 拿到的是同一份：
// 看到电脑画面 = 一切正常；看到黑屏 = 替换开着但电脑画面还没到；看到真实画面 = 替换没开或插件没生效。

final class CameraCheck: ObservableObject {
    let session = AVCaptureSession()
    @Published var status = "正在打开相机…"
    @Published var front = true
    private let queue = DispatchQueue(label: "auxcam.cameracheck")

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { ok in
            guard ok else {
                DispatchQueue.main.async { self.status = "没有相机权限：请到 设置 → AuxCam 打开相机" }
                return
            }
            self.configure()
        }
    }

    func flip() {
        front.toggle()
        configure()
    }

    private func configure() {
        let position: AVCaptureDevice.Position = front ? .front : .back
        queue.async {
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
               let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if self.session.canSetSessionPreset(.hd1920x1080) { self.session.sessionPreset = .hd1920x1080 }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            Log.write("开播前检查：打开\(position == .front ? "前" : "后")摄像头 running=\(running)")
            DispatchQueue.main.async { self.status = running ? "" : "相机打不开（可能正被别的 App 使用）" }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
            Log.write("开播前检查：关闭相机")
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let front: Bool

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        // 不做自动镜像：显示相机原样输出的画面（系统相机预览默认会把前摄像头左右翻过来，那样就看不准了）
        if let c = v.previewLayer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }
    }
}

struct CameraCheckView: View {
    @StateObject private var cam = CameraCheck()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CameraCheckContent(cam: cam) { CameraPreview(session: cam.session, front: cam.front) }
                .navigationTitle("开播前检查")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }
}

/// 开播前检查页的内容（相机预览 + 说明 + 换摄像头按钮）
struct CameraCheckContent<Preview: View>: View {
    @ObservedObject var cam: CameraCheck
    @ViewBuilder var preview: () -> Preview

    var body: some View {
            VStack(spacing: 12) {
                ZStack {
                    Color.black
                    preview()
                    if !cam.status.isEmpty {
                        Text(cam.status).foregroundStyle(.white).padding()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 8) {
                    explain("checkmark.circle.fill", .green, "看到电脑画面", "一切正常，开播吧")
                    explain("moon.fill", .gray, "看到黑屏", "替换开着，但电脑画面还没到：在电脑上开始推流")
                    explain("exclamationmark.triangle.fill", .red, "看到你自己 / 真实画面", "替换没打开，或插件没生效：先别开播")
                    Text("文字左右反了就点主界面的\"镜像\"，方向不对就点\"旋转\"。直播中不要打开这个页面。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(UIColor.secondarySystemGroupedBackground)))

                Button { cam.flip() } label: {
                    Label(cam.front ? "现在是前摄像头（点这里换后摄像头）" : "现在是后摄像头（点这里换前摄像头）",
                          systemImage: "arrow.triangle.2.circlepath.camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Spacer(minLength: 0)
            }
            .padding(16)
    }

    private func explain(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
