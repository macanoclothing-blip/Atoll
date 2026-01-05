import Foundation
import AppKit
import SQLite3
import Combine
import Defaults
import SwiftUI

@MainActor
class NotificationManager: ObservableObject {
    static let shared = NotificationManager()
    
    @Published var notifications: [MessageNotification] = []
    @Published var currentIndex: Int = 0
    @Published var isMonitoring = false
    @Published var hasAccess = false
    
    var activeNotification: MessageNotification? {
        guard !notifications.isEmpty && currentIndex < notifications.count else { return nil }
        return notifications[currentIndex]
    }
    
    // Look back 5 minutes on startup to catch things sent during build/restart
    private var lastProcessedTimestamp: Double = Date().timeIntervalSince1970 - 300
    private var dbSources: [DispatchSourceFileSystemObject] = []
    private var dbFileDescriptors: [Int32] = []
    private let dbPath = "/Users/\(NSUserName())/Library/Group Containers/group.com.apple.usernoted/db2/db"
    private let tempDbPath = "/tmp/atoll_notifications.db"
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        if Defaults[.enableMessageNotifications] {
            startMonitoring()
        }
        
        Defaults.publisher(.enableMessageNotifications)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                if change.newValue {
                    self?.startMonitoring()
                } else {
                    self?.stopMonitoring()
                }
            }
            .store(in: &cancellables)
    }
    
    func startMonitoring() {
        guard !isMonitoring else { return }
        print("NotificationManager: Starting event-driven monitoring...")
        isMonitoring = true
        
        // Initial check
        checkDatabase()
        
        // Monitor both the main DB and the WAL file
        let pathsToWatch = [dbPath, dbPath + "-wal"]
        for path in pathsToWatch {
            let fd = open(path, O_EVTONLY)
            guard fd != -1 else { continue }
            
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in
                print("NotificationManager: ⚡️ File system event detected on \(path.components(separatedBy: "/").last ?? "")")
                self?.checkDatabase()
            }
            
            source.setCancelHandler {
                close(fd)
            }
            
            dbFileDescriptors.append(fd)
            dbSources.append(source)
            source.resume()
        }
    }
    
    func stopMonitoring() {
        print("NotificationManager: Stopping monitoring...")
        isMonitoring = false
        
        for source in dbSources {
            source.cancel()
        }
        dbSources.removeAll()
        dbFileDescriptors.removeAll()
    }
    
    private func checkDatabase() {
        let fileManager = FileManager.default
        
        let isReadable = fileManager.isReadableFile(atPath: dbPath)
        if isReadable != hasAccess {
            hasAccess = isReadable
            print("NotificationManager: Access status changed to \(isReadable)")
        }
        
        guard isReadable else { return }
        
        // Copy DB and its sidecars (WAL/SHM) to ensure we get real-time updates
        let filesToCopy = ["", "-wal", "-shm"]
        for suffix in filesToCopy {
            let src = dbPath + suffix
            let dst = tempDbPath + suffix
            
            if fileManager.fileExists(atPath: src) {
                do {
                    if fileManager.fileExists(atPath: dst) {
                        try fileManager.removeItem(atPath: dst)
                    }
                    try fileManager.copyItem(atPath: src, toPath: dst)
                } catch {
                    print("NotificationManager: Failed to copy \(suffix) file: \(error)")
                }
            }
        }
        
        var db: OpaquePointer?
        if sqlite3_open_v2(tempDbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            // Resolve app_id to bundle identifier
            var resolvedAppId: [Int: String] = [:]
            let appQuery = "SELECT rowid, identifier FROM app"
            var appStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, appQuery, -1, &appStmt, nil) == SQLITE_OK {
                while sqlite3_step(appStmt) == SQLITE_ROW {
                    let rowid = Int(sqlite3_column_int(appStmt, 0))
                    let identifier = String(cString: sqlite3_column_text(appStmt, 1))
                    resolvedAppId[rowid] = identifier
                }
                sqlite3_finalize(appStmt)
            }

            let macAbsoluteTimeOffset = 978307200.0
            let adjustedLastTimestamp = lastProcessedTimestamp - macAbsoluteTimeOffset
            
            // Try common column names for the timestamp
            let possibleDateColumns = ["delivered_date", "presented", "date", "time"]
            var foundColumnName: String?
            for col in possibleDateColumns {
                let checkQuery = "SELECT \(col) FROM record LIMIT 1"
                var checkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, checkQuery, -1, &checkStmt, nil) == SQLITE_OK {
                    foundColumnName = col
                    sqlite3_finalize(checkStmt)
                    break
                }
                sqlite3_finalize(checkStmt)
            }
            
            guard let dateColumn = foundColumnName else {
                sqlite3_close(db)
                return
            }
            
            // Query all NEW notifications since last check
            let query = "SELECT uuid, app_id, data, \(dateColumn) FROM record WHERE \(dateColumn) > ? ORDER BY \(dateColumn) ASC"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_double(statement, 1, adjustedLastTimestamp)
                
                var maxTimestampFound: Double = lastProcessedTimestamp
                var foundAny = false
                
                while sqlite3_step(statement) == SQLITE_ROW {
                    foundAny = true
                    let uuid = String(cString: sqlite3_column_text(statement, 0))
                    let appIdRaw = String(cString: sqlite3_column_text(statement, 1))
                    let blob = sqlite3_column_blob(statement, 2)
                    let blobSize = sqlite3_column_bytes(statement, 2)
                    let colDate = sqlite3_column_double(statement, 3)
                    let date = colDate + macAbsoluteTimeOffset
                    
                    var finalAppId = appIdRaw
                    if let rowid = Int(appIdRaw), let mapped = resolvedAppId[rowid] {
                        finalAppId = mapped
                    }
                    
                    // Update the timestamp to the latest one we've seen
                    maxTimestampFound = max(maxTimestampFound, date)
                    
                    if let blob = blob, let data = Data(bytes: blob, count: Int(blobSize)) as Data? {
                        parseNotification(data: data, uuid: uuid, appId: finalAppId, date: date)
                    }
                }
                
                // Crucial fix: add an epsilon to prevent the same notification from appearing in the next tick
                if foundAny {
                    self.lastProcessedTimestamp = maxTimestampFound + 0.0001
                }
                
                sqlite3_finalize(statement)
            }
            sqlite3_close(db)
        }
    }
    
    private func recursiveScanForImages(in container: Any, ignoreSize: Bool = false, blockedKeys: Set<String> = []) -> [NSImage] {
        var images: [NSImage] = []
        
        if let data = container as? Data {
            if let image = NSImage(data: data) {
                let sizeText = "\(Int(image.size.width))x\(Int(image.size.height))"
                if ignoreSize || (image.size.width >= 10 && image.size.width <= 2048) {
                    images.append(image)
                } else {
                    print("NotificationManager: ⚠️ Image rejected due to size: \(sizeText)")
                }
            }
        } else if let string = container as? String {
            if string.hasPrefix("/") && (string.hasSuffix(".jpg") || string.hasSuffix(".png") || string.hasSuffix(".jpeg") || string.hasSuffix(".tiff") || string.hasSuffix(".heic") || string.hasSuffix(".webp") || string.hasSuffix(".gif")) {
                if FileManager.default.fileExists(atPath: string), let image = NSImage(contentsOfFile: string) {
                     if ignoreSize || image.size.width >= 10 {
                         images.append(image)
                     }
                }
            }
        } else if let dict = container as? [String: Any] {
            for (key, value) in dict {
                if blockedKeys.contains(key) {
                    print("NotificationManager: 🚫 Skipping blocked key: \(key)")
                    continue 
                }
                images.append(contentsOf: recursiveScanForImages(in: value, ignoreSize: ignoreSize, blockedKeys: blockedKeys))
            }
        } else if let array = container as? [Any] {
            for value in array {
                images.append(contentsOf: recursiveScanForImages(in: value, ignoreSize: ignoreSize, blockedKeys: blockedKeys))
            }
        }
        
        return images
    }
    
    private func recursiveScanForStrings(in container: Any) -> [String] {
        var strings: [String] = []
        if let string = container as? String {
            strings.append(string)
        } else if let data = container as? Data {
            if let string = String(data: data, encoding: .utf8) {
                strings.append(string)
            }
            // Also try to find snowflakes in the raw bytes if they are stored as strings
            let pattern = "[0-9]{17,20}"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let text = String(decoding: data, as: UTF8.self)
                let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches {
                    if let range = Range(match.range, in: text) {
                        strings.append(String(text[range]))
                    }
                }
            }
        } else if let dict = container as? [String: Any] {
            for (_, value) in dict {
                strings.append(contentsOf: recursiveScanForStrings(in: value))
            }
        } else if let array = container as? [Any] {
            for value in array {
                strings.append(contentsOf: recursiveScanForStrings(in: value))
            }
        }
        return strings
    }
    
    private func findBestProfilePicture(in plist: [String: Any]) -> NSImage? {
        // Collect all potential "content" image paths/data to EXCLUDE them from profile pic search
        var contentPaths: Set<String> = []
        if let req = plist["req"] as? [String: Any],
           let attachments = req["attachments"] as? [[String: Any]] {
            for att in attachments {
                if let p = att["path"] as? String { contentPaths.insert(p) }
                if let p = att["maximize_path"] as? String { contentPaths.insert(p) }
            }
        }
        
        // Broad search for profile pictures
        let profileKeys = [
            "person-image", "sender-image-data", "profile-image", "avatar", 
            "large-icon", "imageData", "image-data", "sender-photo", 
            "PHS-sender-image", "PHS-sender-image-data", "sender-image",
            "sender_image", "user_image", "user_photo", "contact_image"
        ]
        
        // Keys to ALWAYS ignore when looking for a profile picture
        let blockedMetaKeys: Set<String> = ["body_artwork_data", "sticker_thumbnail", "preview_image_data", "sticker", "attachments", "body-image", "maximize_path", "path"]
        
        for key in profileKeys {
            if let value = plist[key] {
                // If it's a string path and it's in our "content" set, skip it!
                if let path = value as? String, contentPaths.contains(path) { continue }
                
                let images = recursiveScanForImages(in: value, ignoreSize: false, blockedKeys: blockedMetaKeys)
                if let first = images.first { 
                    print("NotificationManager: 👤 Found profile pic in specific key: \(key)")
                    return first 
                }
            }
        }
        
        // iMessage specific: usually in req -> content -> person-image
        if let req = plist["req"] as? [String: Any],
           let content = req["content"] as? [String: Any],
           let personImage = content["person-image"] {
            let images = recursiveScanForImages(in: personImage, ignoreSize: false, blockedKeys: blockedMetaKeys)
            if let first = images.first { 
                print("NotificationManager: 👤 Found profile pic in req.content.person-image")
                return first 
            }
        }
        
        // WhatsApp specific check for 'icn' but verify it's not the same as a known attachment
        if let icn = plist["icn"] {
            if let path = icn as? String, contentPaths.contains(path) { 
                print("NotificationManager: 👤 'icn' matches attachment path, skipping...")
            } else {
                let images = recursiveScanForImages(in: icn, ignoreSize: false, blockedKeys: blockedMetaKeys)
                if let first = images.first, first.size.width >= 10 {
                    print("NotificationManager: 👤 Found profile pic in 'icn' key")
                    return first
                }
            }
        }
        
        // FINAL SAFETY: If we have an identified sticker or attachment, DO NOT fallback to global scan
        // because global scan will almost certainly pick up the sticker/photo.
        let body = (plist["req"] as? [String: Any])?["content"] as? [String: Any]? ?? [:]
        let bodyText = (body?["body"] as? String)?.lowercased() ?? ""
        let likelyHasMedia = !contentPaths.isEmpty || bodyText.contains("photo") || bodyText.contains("foto") || bodyText.contains("sticker") || bodyText.contains("adesivo")
        
        if !likelyHasMedia {
            let allImages = recursiveScanForImages(in: plist, ignoreSize: false, blockedKeys: blockedMetaKeys)
            for img in allImages {
                // Profile pics are usually square and reasonably small icons
                if abs(img.size.width - img.size.height) < 2 && img.size.width < 120 {
                    print("NotificationManager: 👤 Found profile pic via global square scan (\(Int(img.size.width)) px)")
                    return img
                }
            }
        }

        return nil
    }
    
    private func findValue(for key: String, in dict: [String: Any]) -> Any? {
        if let val = dict[key] { return val }
        for (_, value) in dict {
            if let nested = value as? [String: Any], let found = findValue(for: key, in: nested) {
                return found
            }
            if let array = value as? [[String: Any]] {
                for item in array {
                    if let found = findValue(for: key, in: item) { return found }
                }
            }
        }
        return nil
    }
    
    private func findValue(matching keys: [String], in dict: [String: Any]) -> Any? {
        for key in keys {
            if let found = findValue(for: key, in: dict) { return found }
        }
        return nil
    }
    
    private func findAttachmentImage(in plist: [String: Any]) -> NSImage? {
        // High-Res priority: Look for attachments with 'maximize_path' or 'path'
        if let req = plist["req"] as? [String: Any],
           let attachments = req["attachments"] as? [[String: Any]] {
            for attachment in attachments {
                // Prioritize the largest/clearest path
                let paths = [attachment["maximize_path"] as? String, attachment["path"] as? String].compactMap { $0 }
                for p in paths {
                    if let image = NSImage(contentsOfFile: p) {
                        print("NotificationManager: 📸 Found attachment image at: \(p) (\(Int(image.size.width))x\(Int(image.size.height)))")
                        return image
                    }
                }
            }
        }
        
        // Manual scan fallback: Look for ANY image that is definitely NOT a profile icon
        let allImages = recursiveScanForImages(in: plist, ignoreSize: true)
        for img in allImages {
            // Photos are usually larger or non-square
            if img.size.width > 120 || img.size.height > 120 || abs(img.size.width - img.size.height) > 5 {
                return img
            }
        }

        return nil
    }
    
    private func findAudioPath(in container: Any) -> String? {
        if let path = container as? String {
            let audioExtensions = [".m4a", ".caf", ".ogg", ".wav", ".mp3", ".opus"]
            for ext in audioExtensions {
                if path.lowercased().hasSuffix(ext) && FileManager.default.fileExists(atPath: path) {
                    print("NotificationManager: 🎧 Found voice message path: \(path)")
                    return path
                }
            }
        } else if let dict = container as? [String: Any] {
            for (_, value) in dict {
                if let found = findAudioPath(in: value) { return found }
            }
        } else if let array = container as? [Any] {
            for value in array {
                if let found = findAudioPath(in: value) { return found }
            }
        }
        return nil
    }

    private func findStickerImage(in plist: [String: Any]) -> NSImage? {
        // 1. Check specific sticker/artwork keys first with NO size restriction
        // We look for these EXPLICITLY as they usually contain the "TRUE" sticker
        let stickerKeys = ["body_artwork_data", "sticker_thumbnail", "preview_image_data", "sticker"]
        for key in stickerKeys {
            if let value = plist[key] {
                if let data = value as? Data, let img = NSImage(data: data) { return img }
                let images = recursiveScanForImages(in: value, ignoreSize: true)
                if let first = images.first { return first }
            }
        }

        // WhatsApp/iMessage Attachments (but only if they are small or labeled as stickers)
        if let req = plist["req"] as? [String: Any] {
            if let attachments = req["attachments"] as? [[String: Any]] {
                for attachment in attachments {
                    if let path = attachment["path"] as? String ?? attachment["maximize_path"] as? String {
                        if let image = NSImage(contentsOfFile: path) { 
                            // Only count as sticker if it's not a "large" photo
                            if image.size.width < 300 { return image }
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    private func parseNotification(data: Data, uuid: String, appId: String, date: Double) {
        do {
            if let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                // DEBUG: Print entire plist to see structure
                // print("NotificationManager: 🔍 Full Plist for \(appId): \(plist)")
                
                var title: String?
                var subtitle: String?
                var body: String?
                var senderId: String?
                var senderUserId: String?
                
                let reqDict = plist["req"] as? [String: Any]
                
                if appId.lowercased().contains("discord") || appId.lowercased().contains("com.hnc.discord") {
                    print("NotificationManager: 👾 Discord Notification Detected. Plist Keys: \(plist.keys)")
                    if let req = reqDict {
                         print("NotificationManager: 👾 FULL REQ Keys: \(req.keys)")
                    }
                }
                
                // --- 1. Extraction Layer ---
                // Try to find fields in "req.content"
                if let content = reqDict?["content"] as? [String: Any] {
                    title = content["title"] as? String ?? content["titl"] as? String
                    subtitle = content["subtitle"] as? String ?? content["subt"] as? String
                    body = content["body"] as? String
                }
                
                // Fallback to "req" root
                if title == nil { title = reqDict?["title"] as? String ?? reqDict?["titl"] as? String }
                if subtitle == nil { subtitle = reqDict?["subtitle"] as? String ?? reqDict?["subt"] as? String }
                if body == nil { body = reqDict?["body"] as? String }
                
                // Fallback to root plist
                if title == nil { title = plist["title"] as? String ?? plist["titl"] as? String }
                if subtitle == nil { subtitle = plist["subtitle"] as? String ?? plist["subt"] as? String }
                if body == nil { body = plist["body"] as? String }
                
                // --- 2. Discord-Specific ID Layer ---
                if appId.lowercased().contains("discord") || appId.lowercased().contains("com.hnc.discord") {
                    let cidKeys = ["channel_id", "cid", "c", "chid", "c_id", "channelID"]
                    let gidKeys = ["guild_id", "gid", "g", "guid", "g_id", "guildID"]
                    let uidKeys = ["author_id", "user_id", "id", "author", "authorID", "sender_id", "uid", "a"]
                    
                    let cidRaw = findValue(matching: cidKeys, in: plist)
                    let gidRaw = findValue(matching: gidKeys, in: plist)
                    let uidRaw = findValue(matching: uidKeys, in: plist)
                    
                    let cid: String? = (cidRaw as? String) ?? (cidRaw as? Int64).map(String.init) ?? (cidRaw as? Int).map(String.init)
                    let gid: String? = (gidRaw as? String) ?? (gidRaw as? Int64).map(String.init) ?? (gidRaw as? Int).map(String.init)
                    senderUserId = (uidRaw as? String) ?? (uidRaw as? Int64).map(String.init) ?? (uidRaw as? Int).map(String.init)
                    
                    // Snowflake retrieval
                    let allStrings = self.recursiveScanForStrings(in: plist)
                    let usdaStrings = (plist["usda"] as? Data).map { self.recursiveScanForStrings(in: $0) } ?? []
                    let combined = Array(Set(allStrings + usdaStrings))
                    let snowflakes = Array(Set(combined.filter { $0.count >= 17 && $0.count <= 20 && CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: $0)) }))
                    
                    print("NotificationManager: 👾 Detected snowflakes: \(snowflakes)")

                    let discordChannelId = (reqDict?["thre"] as? String) ?? (plist["thre"] as? String)
                    let discordMessageId = (reqDict?["iden"] as? String) ?? (plist["iden"] as? String) ?? (reqDict?["id"] as? String)
                    
                    if let dChanId = discordChannelId {
                        senderId = (gid != nil && gid != "0") ? "\(gid!):\(dChanId)" : dChanId
                        print("NotificationManager: 👾 Discord Channel ID from 'thre': \(dChanId)")
                    } else if cid != nil {
                        senderId = (gid != nil && gid != "0") ? "\(gid!):\(cid!)" : cid
                    } else if snowflakes.count >= 2 {
                        if let msgId = discordMessageId {
                            senderId = snowflakes.first(where: { $0 != msgId }) ?? snowflakes[0]
                        } else {
                            senderId = snowflakes[0]
                        }
                    } else {
                        senderId = snowflakes.first
                    }
                    
                    if senderUserId == nil {
                        if snowflakes.count >= 3 {
                            senderUserId = snowflakes.first(where: { 
                                $0 != discordChannelId && 
                                $0 != discordMessageId && 
                                $0 != (senderId?.contains(":") == true ? senderId?.components(separatedBy: ":").last : senderId) 
                            }) ?? snowflakes.last
                        } else if snowflakes.count == 2 {
                            senderUserId = snowflakes.first(where: { $0 != (senderId?.contains(":") == true ? senderId?.components(separatedBy: ":").last : senderId) }) ?? snowflakes.last
                        } else {
                            senderUserId = snowflakes.first
                        }
                    }
                    
                    if let sid = senderId { print("NotificationManager: 👾 Discord Target ID: \(sid)") }
                    if let uid = senderUserId { print("NotificationManager: 👾 Discord User ID: \(uid)") }
                } else if senderId == nil {
                    // Generic fallback
                    let cid = findValue(matching: ["j", "channel_id", "cid", "sender", "author", "phone"], in: plist) as? String
                    let gid = findValue(matching: ["guild_id", "gid", "group", "group_id"], in: plist) as? String
                    if let cid = cid {
                        senderId = (gid != nil && gid != "0") ? "\(gid!):\(cid)" : cid
                    }
                    
                    if appId.lowercased().contains("whatsapp") {
                         print("NotificationManager: 🟢 WhatsApp Notification Detected. Keys: \(plist.keys)")
                         let allStrings = self.recursiveScanForStrings(in: plist)
                         let jidCandidates = allStrings.filter { ($0.contains("@c.us") || $0.contains("@s.whatsapp.net") || $0.contains("@g.us")) && !$0.contains(":") }
                         
                         print("NotificationManager: 🟢 WhatsApp JID Candidates: \(jidCandidates)")
                         
                         if let jid = jidCandidates.first(where: { $0.contains("@c.us") || $0.contains("@s.whatsapp.net") }) {
                             senderId = jid
                             print("NotificationManager: 🟢 WhatsApp JID discovered via pattern: \(jid)")
                         } else if let groupJid = jidCandidates.first(where: { $0.contains("@g.us") }) {
                             senderId = groupJid
                             print("NotificationManager: 🟢 WhatsApp Group JID discovered via pattern: \(groupJid)")
                         }
                         
                         print("NotificationManager: 🟢 WhatsApp Final ID Candidate: \(senderId ?? "nil"), Sender Name: \(title ?? "Unknown")")
                    }
                }
                
                // --- 3. Parsing Layer ---
                title = title?.replacingOccurrences(of: "\u{200E}", with: "")
                title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                subtitle = subtitle?.replacingOccurrences(of: "\u{200E}", with: "")
                subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)

                if let foundBody = body, !foundBody.isEmpty {
                    var currentBody = foundBody
                    var finalSender = title ?? "Unknown"
                    var isGroup = false
                    var groupName: String? = nil
                    
                    if let foundSubtitle = subtitle, !foundSubtitle.isEmpty {
                        isGroup = true
                        groupName = finalSender
                        finalSender = foundSubtitle
                    }
                    
                    var serverIcon: NSImage? = nil
                    var serverName: String? = nil
                    var channelName: String? = nil
                    var extractedGuildId: String? = nil
                    
                    if appId.lowercased().contains("discord") || appId.lowercased().contains("com.hnc.discord") {
                        if let b = body {
                            let parts = b.components(separatedBy: ":")
                            if parts.count >= 2 {
                                let potentialSender = parts[0].trimmingCharacters(in: .whitespaces)
                                if !potentialSender.isEmpty && potentialSender.count < 35 {
                                    let content = parts.dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                                    
                                    // Extract Server and Channel separately for better UI
                                    if isGroup {
                                        serverName = groupName
                                        channelName = finalSender
                                        groupName = "\(serverName ?? "") > \(channelName ?? "")"
                                    } else {
                                        serverName = finalSender
                                        isGroup = true
                                    }
                                    
                                    finalSender = potentialSender
                                    currentBody = content
                                }
                            }
                        }
                        
                        // Capture Guild ID for icon fetching
                        let gidKeys = ["guild_id", "gid", "g", "guid", "g_id", "guildID"]
                        if let gidRaw = findValue(matching: gidKeys, in: plist) {
                            extractedGuildId = (gidRaw as? String) ?? (gidRaw as? Int64).map(String.init) ?? (gidRaw as? Int).map(String.init)
                        }
                    }
                    
                    print("NotificationManager: 🔍 Final Parsed: Sender='\(finalSender)', Group='\(groupName ?? "None")'")
                    
                    let profilePic = findBestProfilePicture(in: plist)
                    let sticker = findStickerImage(in: plist)
                    let attachmentImg = findAttachmentImage(in: plist)
                    let audio = findAudioPath(in: plist)
                    
                    var notification = MessageNotification(
                        id: uuid,
                        appBundleId: appId,
                        sender: finalSender,
                        content: currentBody,
                        timestamp: Date(timeIntervalSince1970: date),
                        profilePicture: profilePic,
                        stickerImage: sticker,
                        senderIdentifier: senderId,
                        isGroup: isGroup,
                        groupName: groupName,
                        attachmentImage: attachmentImg,
                        audioPath: audio
                    )
                    
                    // Assign extra Discord fields
                    notification.serverName = serverName
                    notification.channelName = channelName
                    notification.guildId = extractedGuildId
                    
                    self.notifications.insert(notification, at: 0)
                    if self.notifications.count > 20 { self.notifications.removeLast() }
                    self.currentIndex = 0
                    print("NotificationManager: 🚀 Preparing to trigger Island for \(finalSender). Has Profile Pic: \(notification.profilePicture != nil)")
                    Task { @MainActor in
                         triggerIsland(notification: notification)
                    }
                    
                    // --- 4. Post-Parsing Layer (Avatars) ---
                    print("NotificationManager: 🟢 Entering Section 4. AppId: \(appId)")
                    if appId.lowercased().contains("whatsapp") {
                        print("NotificationManager: 🟢 Matched WhatsApp AppId, proceeding to fetch...")
                        var candidates: [String] = []
                        if let sId = senderId { candidates.append(sId) }
                        candidates.append(finalSender) // Fallback: search by name
                        
                        print("NotificationManager: 🟢 Requesting WA profile pic for: \(candidates)")
                        
                        WhatsAppWebManager.shared.getProfilePicture(candidates: candidates) { [weak self] image in
                            if let image = image {
                                print("NotificationManager: ✅ WhatsApp Profile Picture FOUND for \(candidates.first ?? "unknown")")
                                DispatchQueue.main.async {
                                    if let idx = self?.notifications.firstIndex(where: { $0.id == uuid }) {
                                        self?.notifications[idx].profilePicture = image
                                    }
                                }
                            } else {
                                print("NotificationManager: ❌ WhatsApp Profile Picture NOT FOUND for \(candidates)")
                            }
                        }
                    }
 else if appId.lowercased().contains("discord") || appId.lowercased().contains("com.hnc.discord") {
                         // Fetch Guild Icon if present
                         if let gId = extractedGuildId {
                             DiscordWebManager.shared.getGuildIcon(guildId: gId) { [weak self] image in
                                 guard let image = image else { return }
                                 DispatchQueue.main.async {
                                     if let idx = self?.notifications.firstIndex(where: { $0.id == uuid }) {
                                         self?.notifications[idx].serverIcon = image
                                         print("NotificationManager: 🏰 Discord Guild Icon updated")
                                     }
                                 }
                             }
                         }

                         var candidates: [String] = []
                         if let uId = senderUserId { candidates.append(uId) }
                         let allStrings = self.recursiveScanForStrings(in: plist)
                         let reqStrings = (plist["req"] as? [String: Any]).map { self.recursiveScanForStrings(in: $0) } ?? []
                         let usdaStrings = (plist["usda"] as? Data).map { self.recursiveScanForStrings(in: $0) } ?? []
                         let snowflakes = Array(Set((allStrings + reqStrings + usdaStrings).filter { $0.count >= 17 && $0.count <= 20 && CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: $0)) }))
                         for s in snowflakes { if !candidates.contains(s) { candidates.append(s) } }
                         
                         if !candidates.isEmpty {
                            DiscordWebManager.shared.getProfilePicture(candidates: candidates) { [weak self] image in
                                guard let image = image else { return }
                                DispatchQueue.main.async {
                                    if let idx = self?.notifications.firstIndex(where: { $0.id == uuid }) {
                                        self?.notifications[idx].profilePicture = image
                                        print("NotificationManager: ✅ Discord Profile Picture updated")
                                    }
                                }
                            }
                         }
                    }
                }
            }
        } catch {
            print("NotificationManager: ❌ Plist error: \(error)")
        }
    }
    
    private func triggerIsland(notification: MessageNotification) {
        print("NotificationManager: 🚀 Triggering Island for \(notification.sender)")
        let coordinator = DynamicIslandViewCoordinator.shared
        
        let content = notification.filteredContent
        // Speed is approx 30px/sec, assuming 8px per char + some buffer
        let estimatedWidth = Double(content.count) * 8.5
        let scrollDuration = (estimatedWidth + 20) / 25 
        let finalDuration = max(8.0, scrollDuration + 2.0) 
        
        let type: SneakContentType = .message
        
        coordinator.toggleSneakPeek(
            status: true,
            type: type,
            duration: finalDuration,
            value: 0,
            icon: ""
        )

        if Defaults[.autoExpandNotifications] {
            coordinator.shouldOpenNotch = true
        }
    }
    
    func nextNotification() {
        if currentIndex < notifications.count - 1 {
            withAnimation(.spring()) {
                currentIndex += 1
                triggerHaptic()
            }
        }
    }
    
    func previousNotification() {
        if currentIndex > 0 {
            withAnimation(.spring()) {
                currentIndex -= 1
                triggerHaptic()
            }
        }
    }
    
    private func triggerHaptic() {
        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }
    
    func removeActive() {
        guard !notifications.isEmpty else { return }
        notifications.remove(at: currentIndex)
        if currentIndex >= notifications.count && !notifications.isEmpty {
            currentIndex = notifications.count - 1
        }
    }
    
    func removeThread(for notification: MessageNotification) {
        withAnimation(.spring()) {
            notifications.removeAll { 
                $0.appBundleId == notification.appBundleId && 
                $0.sender == notification.sender &&
                $0.groupName == notification.groupName
            }
            if currentIndex >= notifications.count && !notifications.isEmpty {
                currentIndex = notifications.count - 1
            }
        }
    }
}
