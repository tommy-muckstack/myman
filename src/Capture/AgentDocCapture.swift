import AppKit
import Foundation

/// Turns a region capture into the pieces a Paper doc needs: OCR lines with boxes, a doc-sized PNG,
/// one sentence of alt text, and a change-log entry marked ready for a doc. Markup is not part of this step.
@MainActor
enum AgentDocCapture {
    static func finish(image: NSImage, id: String, path: String, capturedAt: Date, scale: Double,
                       window: CaptureWindowSnapshot.Window?) async throws -> [String: Any] {
        let analysis = await ImageAnalysis.analyze(image)
        let size = AgentImages.size(image)
        let regions = AgentMarkup.regions(analysis.observations, size: size)
        let folder = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let stamp = AgentActions.date(capturedAt)

        let document = AgentOCRSidecar.document(text: analysis.text, regions: regions, size: size, scale: scale, capturedAt: stamp,
                                                app: window?.app, bundleID: window?.bundleID, windowTitle: window?.title, url: window?.url)
        let textData = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .prettyPrinted])
        let textFile = try AgentMediaStore.shared.sidecar(textData, folder: folder, name: "text.json", mime: "application/json", maximum: AgentOCRSidecar.maximumBytes)

        guard let fitted = AgentDocImage.fit(width: Int(size.width), height: Int(size.height), encode: { width in
            AgentImages.resized(image, width: width).flatMap { try? AgentImages.png($0) }
        }) else { throw AgentError("TOO_LARGE", "The capture could not be fitted under 4 MB. Capture a smaller area.") }
        let docFile = try AgentMediaStore.shared.sidecar(fitted.data, folder: folder, name: "doc.png", mime: "image/png", maximum: AgentDocImage.maximumBytes)

        let alt = AgentAltText.make(app: window?.app, windowTitle: window?.title, text: analysis.text)
        let altFile = try AgentMediaStore.shared.sidecar(Data((alt + "\n").utf8), folder: folder, name: "alt.txt", mime: "text/plain", maximum: 4096)

        let paths = ["image": path, "text": textFile["path"] as? String ?? "", "doc": docFile["path"] as? String ?? "", "alt": altFile["path"] as? String ?? ""]
        try AgentChangeLog.append(kind: "screenshot", id: id, readyFor: "paper-doc", paths: paths, at: stamp)
        return ["id": id, "ready_for": "paper-doc", "alt": alt, "doc_width": fitted.width, "ocr_lines": regions.count, "paths": paths]
    }
}
