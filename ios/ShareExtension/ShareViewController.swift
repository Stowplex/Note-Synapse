import UIKit
import Social
import MobileCoreServices

@objc(ShareViewController)
class ShareViewController: SLComposeServiceViewController {

    let appGroupId = "group.com.github.kkspeed.note-synapse"
    let urlScheme = "notesynapse"
    let sharedKey = "shared"

    struct SharedItem: Codable {
        var text: String?
        var url: String?
        var image: String?
        var file: String?
    }

    override func isContentValid() -> Bool {
        return true
    }

    override func didSelectPost() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
            return
        }

        var sharedItems: [SharedItem] = []
        let group = DispatchGroup()

        for attachment in attachments {
            group.enter()
            if attachment.hasItemConformingToTypeIdentifier(kUTTypeURL as String) {
                attachment.loadItem(forTypeIdentifier: kUTTypeURL as String, options: nil) { (data, error) in
                    if let url = data as? URL {
                        sharedItems.append(SharedItem(url: url.absoluteString))
                    }
                    group.leave()
                }
            } else if attachment.hasItemConformingToTypeIdentifier(kUTTypeText as String) {
                attachment.loadItem(forTypeIdentifier: kUTTypeText as String, options: nil) { (data, error) in
                    if let text = data as? String {
                        sharedItems.append(SharedItem(text: text))
                    }
                    group.leave()
                }
            } else if attachment.hasItemConformingToTypeIdentifier(kUTTypeImage as String) {
                attachment.loadItem(forTypeIdentifier: kUTTypeImage as String, options: nil) { (data, error) in
                    if let url = data as? URL,
                       let imageData = try? Data(contentsOf: url) {
                        let fileName = self.saveData(imageData, "image.png")
                        sharedItems.append(SharedItem(image: fileName))
                    }
                    group.leave()
                }
            } else if attachment.hasItemConformingToTypeIdentifier(kUTTypePDF as String) {
                // Handle PDF files specifically
                attachment.loadItem(forTypeIdentifier: kUTTypePDF as String, options: nil) { (data, error) in
                    if let url = data as? URL,
                       let fileData = try? Data(contentsOf: url) {
                        let originalFileName = url.lastPathComponent.isEmpty ? "shared.pdf" : url.lastPathComponent
                        let fileName = self.saveData(fileData, originalFileName)
                        sharedItems.append(SharedItem(file: fileName))
                    }
                    group.leave()
                }
            } else if attachment.hasItemConformingToTypeIdentifier(kUTTypeItem as String) {
                // Handle other file types
                attachment.loadItem(forTypeIdentifier: kUTTypeItem as String, options: nil) { (data, error) in
                    if let url = data as? URL,
                       let fileData = try? Data(contentsOf: url) {
                        let originalFileName = url.lastPathComponent.isEmpty ? "shared_file" : url.lastPathComponent
                        let fileName = self.saveData(fileData, originalFileName)
                        sharedItems.append(SharedItem(file: fileName))
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }

        group.notify(queue: .main) {
            self.saveSharedItems(sharedItems)
            self.redirectToHostApp()
            self.extensionContext!.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    override func configurationItems() -> [Any]! {
        return []
    }

    private func saveData(_ data: Data, _ defaultName: String) -> String {
        let fileName = UUID().uuidString + "_" + defaultName
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let fileURL = containerURL.appendingPathComponent(fileName)
            try? data.write(to: fileURL)
        }
        return fileName
    }

    private func saveSharedItems(_ items: [SharedItem]) {
        if let userDefaults = UserDefaults(suiteName: appGroupId) {
            let encoder = JSONEncoder()
            if let encoded = try? encoder.encode(items) {
                userDefaults.set(encoded, forKey: sharedKey)
            }
        }
    }

    private func redirectToHostApp() {
        let url = URL(string: "\(urlScheme)://share")!
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                break
            }
            responder = responder?.next
        }
    }
}
