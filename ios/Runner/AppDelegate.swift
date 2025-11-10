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
      } else {
        result(FlutterMethodNotImplemented)
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
  
  private struct SharedItem: Codable {
    var text: String?
    var url: String?
    var image: String?
    var file: String?
  }
}
