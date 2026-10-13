import SwiftUI
import UIKit

/// AuxCam 六键面板：相册 / 直连 / 内录 / 镜像 / 旋转 / 恢复
struct PanelView: View {

    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var player: StreamPlayer
    @ObservedObject var recorder: Recorder

    var onAlbum: () -> Void
    var onDirect: () -> Void
    var onReset: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {

            HStack(spacing: 6) {
                Text("AuxCam")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(UIColor.secondaryLabel))
                Spacer()
                Text("当前：\(settings.mode.title)")
                    .font(.system(size: 12))
                    .foregroundColor(Color(UIColor.secondaryLabel))
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                        .padding(.leading, 4)
                }
            }

            HStack(spacing: 10) {
                KeyButton(
                    title: "相册",
                    icon: "photo.on.rectangle",
                    active: settings.mode == .album,
                    tint: Color(red: 0.29, green: 0.78, blue: 0.68),
                    action: onAlbum)

                KeyButton(
                    title: "直连",
                    icon: "arrow.left.and.right",
                    active: settings.mode == .usb || settings.mode == .lan,
                    tint: Color(red: 0.29, green: 0.78, blue: 0.68),
                    action: onDirect)

                KeyButton(
                    title: "内录",
                    icon: "record.circle",
                    active: recorder.isRecording,
                    tint: Color(red: 0.29, green: 0.78, blue: 0.68),
                    action: {
                        if recorder.isRecording {
                            recorder.stop()
                        } else {
                            recorder.start(player: player.player, size: UIScreen.main.bounds.size)
                        }
                    })
            }

            HStack(spacing: 10) {
                KeyButton(
                    title: "镜像",
                    icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    active: settings.mirror,
                    tint: Color(red: 0.29, green: 0.78, blue: 0.68),
                    action: { settings.mirror.toggle() })

                KeyButton(
                    title: "旋转",
                    icon: "arrow.clockwise",
                    active: settings.rotationDegrees % 360 != 0,
                    tint: Color(red: 0.29, green: 0.78, blue: 0.68),
                    action: { settings.rotationDegrees = (settings.rotationDegrees + 90) % 360 })

                KeyButton(
                    title: "恢复",
                    icon: "arrow.counterclockwise",
                    active: false,
                    tint: Color(red: 0.95, green: 0.60, blue: 0.18),
                    action: onReset)
            }

            if recorder.isRecording {
                Text("内录中 \(timeText(recorder.seconds))")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            } else if !recorder.savedHint.isEmpty {
                Text(recorder.savedHint)
                    .font(.system(size: 11))
                    .foregroundColor(Color(UIColor.secondaryLabel))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 268)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    }

    private func timeText(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct KeyButton: View {

    let title: String
    let icon: String
    let active: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundColor(active ? .white : Color(UIColor.darkGray))
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active ? tint : Color(UIColor.systemGray6))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
