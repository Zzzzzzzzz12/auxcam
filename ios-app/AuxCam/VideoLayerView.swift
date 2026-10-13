import SwiftUI
import AVFoundation
import UIKit

/// AVPlayerLayer 宿主，负责把 layer 交给 StreamPlayer（画中画要用）
final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct VideoLayerView: UIViewRepresentable {

    let mirror: Bool
    let rotationDegrees: Int
    let onLayerReady: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.backgroundColor = .black
        v.playerLayer.videoGravity = .resizeAspectFill
        v.clipsToBounds = true
        onLayerReady(v.playerLayer)
        return v
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.playerLayer.videoGravity = .resizeAspectFill
        applyTransform(uiView)
    }

    private func applyTransform(_ v: PlayerHostView) {
        let deg = ((rotationDegrees % 360) + 360) % 360
        let rad = CGFloat(deg) * .pi / 180

        var t = CGAffineTransform.identity
        if mirror { t = t.scaledBy(x: -1, y: 1) }
        t = t.rotated(by: rad)
        if deg % 180 != 0 {
            let b = v.bounds
            if b.width > 1 {
                let s = b.height / b.width
                t = t.scaledBy(x: s, y: s)
            }
        }
        v.transform = t
    }
}
