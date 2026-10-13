import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// 相册选视频 → 拷进沙盒 → 交给播放器
struct VideoPicker: UIViewControllerRepresentable {

    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider else { return }
            let typeID = UTType.movie.identifier
            guard provider.hasItemConformingToTypeIdentifier(typeID) else { return }

            provider.loadFileRepresentation(forTypeIdentifier: typeID) { [weak self] tmpURL, _ in
                guard let self = self, let src = tmpURL else { return }
                let ext = src.pathExtension.isEmpty ? "mp4" : src.pathExtension
                let name = "album_\(Int(Date().timeIntervalSince1970)).\(ext)"
                let dst = FileManager.default
                    .urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent(name)

                try? FileManager.default.removeItem(at: dst)
                do {
                    try FileManager.default.copyItem(at: src, to: dst)
                    DispatchQueue.main.async { self.onPick(dst) }
                } catch {
                    NSLog("AuxCam copy video failed: \(error)")
                }
            }
        }
    }
}
