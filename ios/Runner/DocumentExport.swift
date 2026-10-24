import Flutter
import UIKit

/// Native folder grant + one coordinated, bounded stream. No security-scoped
/// bookmark, provider URL, or plaintext archive is saved in the app container.
final class DocumentExport: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private var pending: FlutterResult?
  private var name = ""
  private var session: CoordinatedExportSession?
  private var token: String?
  private var disposed = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "xveil/document_export", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        guard let self else { Self.fail(result, "closed"); return }
        self.handle(call, result: result)
      }
    }
  }

  deinit { session?.abort() }

  private static func fail(_ result: @escaping FlutterResult, _ stage: String) {
    result(FlutterError(code: "document_export_\(stage)",
      message: "Could not save the document.", details: nil))
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard !disposed else { Self.fail(result, "closed"); return }
    let args = call.arguments as? [String: Any] ?? [:]
    if call.method == "open" {
      guard pending == nil && session == nil else { Self.fail(result, "busy"); return }
      guard let requested = args["name"] as? String, !requested.isEmpty,
        requested.count <= 200,
        requested != ".", requested != "..",
        !requested.contains(where: { "/\\\0\n\r".contains($0) }) else {
        Self.fail(result, "open"); return
      }
      guard var presenter = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })?.rootViewController else {
        Self.fail(result, "open"); return
      }
      while let next = presenter.presentedViewController { presenter = next }
      name = requested
      pending = result
      // Folder picking is supported from iOS 13 (the app's minimum). The
      // completed-file export initializer would require a plaintext temp file.
      let picker = UIDocumentPickerViewController(documentTypes: ["public.folder"], in: .open)
      picker.delegate = self
      picker.allowsMultipleSelection = false
      picker.title = requested
      presenter.present(picker, animated: true)
      return
    }
    guard let writer = session, args["id"] as? String == token else {
      if call.method == "abort" { result(nil) } else { Self.fail(result, "closed") }
      return
    }
    let reply: CoordinatedExportSession.Reply = { error in
      DispatchQueue.main.async {
        if let error { Self.fail(result, String(describing: error)) } else { result(nil) }
      }
    }
    switch call.method {
    case "write":
      guard let bytes = args["bytes"] as? FlutterStandardTypedData else {
        Self.fail(result, "write"); return
      }
      writer.write(bytes.data, reply: reply)
    case "finish": writer.finish(reply: reply)
    case "abort": writer.abort(reply: reply)
    default: result(FlutterMethodNotImplemented)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pending; pending = nil
    result?(nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController,
    didPickDocumentsAt urls: [URL]) {
    guard let result = pending, let folder = urls.first else { return }
    let scoped = folder.startAccessingSecurityScopedResource()
    let id = UUID().uuidString
    token = id
    let writer = CoordinatedExportSession(
      destination: folder.appendingPathComponent(name),
      closed: { [weak self] in
        if scoped { folder.stopAccessingSecurityScopedResource() }
        DispatchQueue.main.async {
          guard let self, self.token == id else { return }
          self.session = nil; self.token = nil
        }
      })
    session = writer
    writer.start { [weak self] error in
      DispatchQueue.main.async {
        guard let self, !self.disposed, self.pending != nil else {
          writer.abort(); return
        }
        self.pending = nil
        if let error { Self.fail(result, String(describing: error)) }
        else { result(["id": id]) }
      }
    }
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    channel.setMethodCallHandler(nil)
    if let pending { Self.fail(pending, "closed") }
    pending = nil
    session?.abort()
  }
}
