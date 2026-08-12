import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let CHANNEL = "com.github.kkspeed/share"
  private let appGroupId = "group.com.github.kkspeed.note-synapse"
  private let sharedKey = "shared"
  
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    let methodChannel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)
    
    methodChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "getSharedContent" {
        result(self?.getSharedContent())
      } else if call.method == "requestMicrophonePermission" {
        self?.requestMicrophonePermission(result: result)
      } else if call.method == "getClipboardText" {
        self?.getClipboardText(result: result)
      } else if call.method == "saveFileToExternalStorage" {
        self?.saveFileToExternalStorage(call: call, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    
    let captureChannel = FlutterMethodChannel(
      name: "note_synapse/native_capture",
      binaryMessenger: controller.binaryMessenger
    )
    
    captureChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "captureRegion" {
        self?.handleCaptureRegion(call: call, result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    let videoFramesChannel = FlutterMethodChannel(
      name: "note_synapse/video_frames",
      binaryMessenger: controller.binaryMessenger
    )
    videoFramesChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing video path", details: nil))
        return
      }
      switch call.method {
      case "getDuration":
        self?.getVideoDuration(path: path, result: result)
      case "extractFrame":
        let timeMs = args["timeMs"] as? Int ?? 0
        let maxWidth = args["maxWidth"] as? Int ?? 0
        self?.extractVideoFrame(path: path, timeMs: timeMs, maxWidth: maxWidth, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let protocolStudyChannel = FlutterMethodChannel(
      name: "note_synapse/protocol_study",
      binaryMessenger: controller.binaryMessenger
    )
    protocolStudyChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard call.method == "excludeFromBackup",
            let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      var url = URL(fileURLWithPath: path, isDirectory: true)
      do {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        result(nil)
      } catch {
        result(FlutterError(
          code: "BACKUP_EXCLUSION_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // Handle notesynapse://share URL scheme
    if url.scheme == "notesynapse" && url.host == "share" {
      // Notify the Flutter app that new content is available
      if let controller = window?.rootViewController as? FlutterViewController {
        let methodChannel = FlutterMethodChannel(name: CHANNEL, binaryMessenger: controller.binaryMessenger)
        methodChannel.invokeMethod("newSharedContent", arguments: nil)
      }
      return true
    }
    return super.application(app, open: url, options: options)
  }
  
  private func getSharedContent() -> [String: Any]? {
    guard let userDefaults = UserDefaults(suiteName: appGroupId) else {
      return nil
    }
    
    // Try to get shared data from the new format (array of SharedItem)
    if let encodedData = userDefaults.data(forKey: sharedKey) {
      let decoder = JSONDecoder()
      if let sharedItems = try? decoder.decode([SharedItem].self, from: encodedData) {
        // Clear the data after reading
        userDefaults.removeObject(forKey: sharedKey)
        userDefaults.synchronize()
        
        // Convert SharedItem array to the format expected by ShareService
        return convertSharedItemsToMap(sharedItems)
      }
    }
    
    // Fallback: try old format (direct dictionary)
    if let sharedData = userDefaults.dictionary(forKey: "shared_data") {
      userDefaults.removeObject(forKey: "shared_data")
      userDefaults.synchronize()
      return sharedData as? [String: Any]
    }
    
    return nil
  }
  
  private func convertSharedItemsToMap(_ items: [SharedItem]) -> [String: Any]? {
    guard let firstItem = items.first else {
      return nil
    }
    
    var result: [String: Any] = [
      "action": "SEND"
    ]
    
    // Handle text
    if let text = firstItem.text {
      result["type"] = "text/plain"
      result["text"] = text
      
      // Check if text is a URL
      if let url = URL(string: text), url.scheme != nil && (url.scheme == "http" || url.scheme == "https") {
        result["contentType"] = "url"
        result["url"] = text
      }
      return result
    }
    
    // Handle URL
    if let urlString = firstItem.url {
      result["type"] = "text/plain"
      result["text"] = urlString
      result["contentType"] = "url"
      result["url"] = urlString
      return result
    }
    
    // Handle image
    if let imageFileName = firstItem.image {
      if let filePath = getFilePathFromAppGroup(fileName: imageFileName) {
        result["type"] = "image/png"
        result["filePath"] = filePath
        result["fileName"] = imageFileName
        return result
      }
    }
    
    // Handle file
    if let fileName = firstItem.file {
      if let filePath = getFilePathFromAppGroup(fileName: fileName) {
        // Determine MIME type from file extension
        let mimeType = getMimeTypeFromFileName(fileName)
        result["type"] = mimeType
        result["filePath"] = filePath
        result["fileName"] = fileName
        return result
      }
    }
    
    return nil
  }
  
  private func getFilePathFromAppGroup(fileName: String) -> String? {
    guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
      return nil
    }
    let fileURL = containerURL.appendingPathComponent(fileName)
    return fileURL.path
  }
  
  private func getMimeTypeFromFileName(_ fileName: String) -> String {
    let ext = (fileName as NSString).pathExtension.lowercased()
    switch ext {
    case "pdf":
      return "application/pdf"
    case "jpg", "jpeg":
      return "image/jpeg"
    case "png":
      return "image/png"
    case "gif":
      return "image/gif"
    case "txt":
      return "text/plain"
    default:
      return "application/octet-stream"
    }
  }
  
  private func requestMicrophonePermission(result: @escaping FlutterResult) {
    // Just request permission - don't configure audio session
    // The record package will handle audio session configuration
    AVAudioSession.sharedInstance().requestRecordPermission { granted in
      DispatchQueue.main.async {
        result(granted)
      }
    }
  }
  
  private func getClipboardText(result: @escaping FlutterResult) {
    // Access clipboard on the main thread
    DispatchQueue.main.async {
      let pasteboard = UIPasteboard.general
      
      // Check if pasteboard has string content
      if pasteboard.hasStrings {
        result(pasteboard.string)
      } else {
        result(nil)
      }
    }
  }
  
  private func saveFileToExternalStorage(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      result(FlutterError(code: "NO_CONTROLLER", message: "Unable to access FlutterViewController", details: nil))
      return
    }

    guard let arguments = call.arguments as? [String: Any],
          let filePath = arguments["filePath"] as? String else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing filePath argument", details: nil))
      return
    }

    let fileURL = URL(fileURLWithPath: filePath)
    if !FileManager.default.fileExists(atPath: filePath) {
      result(FlutterError(code: "FILE_NOT_FOUND", message: "File does not exist at path: \(filePath)", details: nil))
      return
    }

    let documentPicker: UIDocumentPickerViewController
    if #available(iOS 14.0, *) {
      documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
    } else {
      documentPicker = UIDocumentPickerViewController(url: fileURL, in: .exportToService)
    }
    documentPicker.modalPresentationStyle = .formSheet
    controller.present(documentPicker, animated: true, completion: nil)
    
    // We confirm success immediately as the picker handles the rest asynchronously.
    // Ideally we would wait for delegate callbacks, but for simplicity of this one-way export, this suffices for now.
    // If we need result confirmation, we'd implement UIDocumentPickerDelegate.
    result(true)
  }

  private func handleCaptureRegion(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      result(FlutterError(code: "NO_CONTROLLER", message: "Unable to access FlutterViewController", details: nil))
      return
    }
    
    guard let arguments = call.arguments as? [String: Any],
          let x = arguments["x"] as? Double,
          let y = arguments["y"] as? Double,
          let width = arguments["width"] as? Double,
          let height = arguments["height"] as? Double,
          let devicePixelRatio = arguments["devicePixelRatio"] as? Double else {
      result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments for captureRegion", details: nil))
      return
    }
    
    DispatchQueue.main.async {
      guard let flutterView = controller.view else {
        result(FlutterError(code: "NO_VIEW", message: "Flutter view unavailable for capture", details: nil))
        return
      }
      
      flutterView.layoutIfNeeded()
      
      let screenScale = CGFloat(devicePixelRatio)
      let captureRect = CGRect(x: x, y: y, width: width, height: height)
      
      guard captureRect.width > 0, captureRect.height > 0 else {
        result(FlutterError(code: "INVALID_SIZE", message: "Capture region size must be positive", details: nil))
        return
      }
      
      let targetView: UIView
      let captureRectInTarget: CGRect
      
      if let window = flutterView.window {
        targetView = window
        captureRectInTarget = flutterView.convert(captureRect, to: window)
      } else {
        targetView = flutterView
        captureRectInTarget = captureRect
      }
      
      let boundedCaptureRect = captureRectInTarget.intersection(targetView.bounds)
      guard !boundedCaptureRect.isNull,
            boundedCaptureRect.width > 0,
            boundedCaptureRect.height > 0 else {
        result(FlutterError(code: "INVALID_BOUNDS", message: "Capture region lies outside of view bounds", details: nil))
        return
      }
      
      targetView.layoutIfNeeded()
      
      let rendererFormat = UIGraphicsImageRendererFormat()
      rendererFormat.scale = screenScale
      rendererFormat.opaque = false
      let renderer = UIGraphicsImageRenderer(size: boundedCaptureRect.size, format: rendererFormat)
      
      let image = renderer.image { context in
        let drawRect = CGRect(
          origin: CGPoint(
            x: -boundedCaptureRect.origin.x,
            y: -boundedCaptureRect.origin.y
          ),
          size: targetView.bounds.size
        )
        
        if !targetView.drawHierarchy(in: drawRect, afterScreenUpdates: false) {
          let cgContext = context.cgContext
          cgContext.saveGState()
          cgContext.translateBy(
            x: -boundedCaptureRect.origin.x,
            y: -boundedCaptureRect.origin.y
          )
          targetView.layer.render(in: cgContext)
          cgContext.restoreGState()
        }
      }
      
      guard let data = image.pngData() else {
        result(FlutterError(code: "ENCODE_ERROR", message: "Failed to encode captured image", details: nil))
        return
      }
      
      result(FlutterStandardTypedData(bytes: data))
    }
  }
  
  private func getVideoDuration(path: String, result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let seconds = CMTimeGetSeconds(asset.duration)
    let ms = seconds.isFinite ? Int(seconds * 1000) : 0
    result(ms)
  }

  /// Decodes the frame nearest `timeMs` as PNG bytes, scaled to `maxWidth`
  /// when > 0. Runs off the main thread (image generation can be slow).
  private func extractVideoFrame(path: String, timeMs: Int, maxWidth: Int, result: @escaping FlutterResult) {
    DispatchQueue.global(qos: .userInitiated).async {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      if maxWidth > 0 {
        generator.maximumSize = CGSize(width: CGFloat(maxWidth), height: CGFloat.greatestFiniteMagnitude)
      }
      let time = CMTime(value: CMTimeValue(timeMs), timescale: 1000)
      do {
        let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
        let data = UIImage(cgImage: cgImage).pngData()
        DispatchQueue.main.async {
          if let data = data {
            result(FlutterStandardTypedData(bytes: data))
          } else {
            result(nil)
          }
        }
      } catch {
        DispatchQueue.main.async { result(nil) }
      }
    }
  }

  private struct SharedItem: Codable {
    var text: String?
    var url: String?
    var image: String?
    var file: String?
  }
}
