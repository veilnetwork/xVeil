// macOS-only test fixture: decode the pixels the production QR widget painted.
// The capability is returned only to the owning test, never logged here.
import AppKit
import Vision

guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { exit(2) }

let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
do {
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
    let offers = (request.results ?? []).compactMap(\.payloadStringValue)
        .filter { $0.hasPrefix("veil:pair?") }
    guard offers.count == 1 else { exit(3) }
    FileHandle.standardOutput.write(Data(offers[0].utf8))
} catch {
    exit(4)
}
