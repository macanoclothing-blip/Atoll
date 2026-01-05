import Foundation
import AppKit

struct MessageNotification: Identifiable, Equatable {
    let id: String
    let appBundleId: String
    let sender: String
    let content: String
    let timestamp: Date
    var profilePicture: NSImage?
    let stickerImage: NSImage?
    let senderIdentifier: String?
    let isGroup: Bool
    let groupName: String?
    let attachmentImage: NSImage?
    let audioPath: String?
    
    // Discord specific
    var serverIcon: NSImage?
    var serverName: String?
    var channelName: String?
    var guildId: String?
    
    var appIcon: NSImage? {
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleId)?.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }
    
    var filteredContent: String {
        let hasMedia = stickerImage != nil || attachmentImage != nil || audioPath != nil
        
        if hasMedia {
            let lowerContent = content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Extract only letters to detect labels regardless of emojis
            let lettersOnly = lowerContent.components(separatedBy: CharacterSet.letters.inverted).joined()
            
            // If the message is JUST a media label
            let mediaLabels = ["sticker", "adesivo", "photo", "foto", "vocal", "audio", "messaggiovocale", "voice", "voicemessage"]
            if mediaLabels.contains(lettersOnly) {
                return ""
            }
            
            // Explicitly remove common patterns with emojis
            var final = content
            let patterns = [
                "💟 sticker", "💟 adesivo", "🎨 sticker", "🖼️ sticker",
                "📷 foto", "📷 photo", "📸 photo", "📸 foto",
                "🎤 messaggio vocale", "🎤 voice message", "🎤 audio", "🎤 vocal"
            ]
            for pattern in patterns {
                final = final.replacingOccurrences(of: pattern, with: "", options: [.caseInsensitive, .regularExpression]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            // Fallback: if the content is very short and contains a media keyword, it's likely just a label
            if content.count < 25 {
                for label in mediaLabels {
                    if lowerContent.contains(label) {
                        return ""
                    }
                }
            }
            
            return final
        }
        return content
    }
    
    static func == (lhs: MessageNotification, rhs: MessageNotification) -> Bool {
        lhs.id == rhs.id
    }
}
