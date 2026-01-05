import SwiftUI
import Defaults

struct MessageNotificationView: View {
    let notification: MessageNotification
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    @Default(.showProfilePictures) var showProfilePictures
    @State private var replyText: String = ""
    @FocusState private var isFocused: Bool
    @State private var selectedFileURL: URL?
    @State private var isExporting = false
    @State private var selectingFileToken = UUID()
    
    private var threadedMessages: [MessageNotification] {
        NotificationManager.shared.notifications.filter { msg in
            if notification.isGroup && notification.groupName != nil {
                // For groups, match app and group name
                return msg.appBundleId == notification.appBundleId && 
                       msg.isGroup &&
                       msg.groupName == notification.groupName
            } else {
                // For private chats, match app and sender
                return msg.appBundleId == notification.appBundleId && 
                       !msg.isGroup &&
                       msg.sender == notification.sender
            }
        }.reversed() // Chronological order (oldest first)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(threadedMessages) { msg in
                        MessageThreadRow(notification: msg, isGroup: notification.isGroup)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 250) // Limit expansion height
            
            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.horizontal, 10)
            
            replySection
        }
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.8))
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 10) {
            // Profile Picture / App Icon
            if notification.appBundleId.lowercased().contains("discord"), let serverIcon = notification.serverIcon {
                // SPECIAL DISCORD LAYOUT: Server Icon (Big) + User Avatar (Small Overlay)
                DiscordIconView(serverIcon: serverIcon, profilePic: notification.profilePicture, appIcon: notification.appIcon)
            } else {
                // DEFAULT LAYOUT
                ZStack(alignment: .bottomTrailing) {
                    if showProfilePictures, let profilePic = notification.profilePicture {
                        Image(nsImage: profilePic)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                        
                        // App Icon Badge - Small overlay
                        if let appIcon = notification.appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 12, height: 12)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.black, lineWidth: 1.2))
                                .offset(x: 3, y: 3)
                        }
                    } else if let appIcon = notification.appIcon {
                        Image(nsImage: appIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                if notification.appBundleId.lowercased().contains("discord"), let serverName = notification.serverName {
                    // Discord Header: Server > Sender > Channel
                    HStack(spacing: 4) {
                        Text(serverName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        
                        Text(">")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary.opacity(0.8))
                        
                        Text(notification.sender)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    
                    if let channel = notification.channelName {
                        Text(channel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // Default Header
                    Text(notification.isGroup && notification.groupName != nil ? notification.groupName! : notification.sender)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    
                    if notification.isGroup {
                         Text(notification.sender)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Text("Now")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private struct DiscordIconView: View {
        let serverIcon: NSImage
        let profilePic: NSImage?
        let appIcon: NSImage?
        
        var body: some View {
            ZStack(alignment: .bottomLeading) {
                // Server Icon (Big)
                Image(nsImage: serverIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
                
                // Profile Pic (Small Overlay)
                if let pp = profilePic {
                    Image(nsImage: pp)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 16, height: 16)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.black.opacity(0.8), lineWidth: 1.5))
                        .offset(x: -4, y: 4)
                }
            }
            .frame(width: 38, height: 38) // Add some padding for the offset
        }
    }

    private var replySection: some View {
        // Reply Section
        VStack(alignment: .leading, spacing: 6) {
            // Attachment Preview Pill
            if let fileURL = selectedFileURL {
                HStack(spacing: 6) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)
                    
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                    
                    Button(action: { selectedFileURL = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.blue.opacity(0.15)))
                .transition(.scale.combined(with: .opacity))
                .padding(.leading, 10)
            }

            HStack(spacing: 8) {
                Button(action: { selectFile() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                        .foregroundStyle(selectedFileURL != nil ? .blue : .secondary)
                }
                .buttonStyle(.plain)
            
            ZStack(alignment: .trailing) {
                /* Reply TextField */
                TextField("Reply...", text: $replyText)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.white.opacity(0.1))
                    )
                    .onSubmit {
                        sendReply()
                    }
                
                if !replyText.isEmpty {
                    Button(action: { sendReply() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
    }

    private func selectFile() {
        // Suppress auto-close while panel is active
        vm.setAutoCloseSuppression(true, token: selectingFileToken)
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.canChooseFiles = true
        
        // Ensure the panel level is high enough to be ABOVE the Dynamic Island
        // DynamicIslandWindow is at .mainMenu + 3, so we go even higher
        panel.level = .screenSaver
        panel.orderFrontRegardless()
        
        panel.begin { response in
            if response == .OK {
                DispatchQueue.main.async {
                    self.selectedFileURL = panel.url
                }
            }
            
            // Release suppression
            DispatchQueue.main.async {
                self.vm.setAutoCloseSuppression(false, token: selectingFileToken)
            }
        }
    }
}

private struct MessageThreadRow: View {
    let notification: MessageNotification
    var isGroup: Bool = false
    @State private var isPlaying = false
    @State private var player: NSSound?
    @State private var delegate: SoundDelegate? // Retain delegate
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Text Body
            if !notification.filteredContent.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if isGroup {
                        Text(notification.sender)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.blue.opacity(0.8))
                            .padding(.leading, 2)
                    }
                    
                    Text(notification.filteredContent)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            // Attachment Image
            if let attachment = notification.attachmentImage {
                Image(nsImage: attachment)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 90, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .padding(.vertical, 2)
            }
            
            // Sticker
            if let sticker = notification.stickerImage {
                Image(nsImage: sticker)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 90, height: 90)
                    .padding(.vertical, 2)
            }
            
            // Audio Message
            if let audio = notification.audioPath {
                HStack(spacing: 8) {
                    Button(action: { toggleAudio(path: audio) }) {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 28, height: 28)
                            
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice Message")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white)
                        
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 3)
                            .overlay(
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(Color.blue)
                                        .frame(width: isPlaying ? geo.size.width * 0.7 : 0)
                                }
                            )
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 2)
    }
    
    private func toggleAudio(path: String) {
        if isPlaying {
            player?.stop()
            isPlaying = false
        } else {
            print("MessageThreadRow: 🎧 Attempting to play: \(path)")
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                let newDelegate = SoundDelegate {
                    isPlaying = false
                }
                self.delegate = newDelegate
                sound.delegate = newDelegate
                self.player = sound
                if sound.play() {
                    isPlaying = true
                } else {
                    print("MessageThreadRow: ❌ NSSound failed to play")
                }
            } else {
                print("MessageThreadRow: ❌ Could not load sound from path")
            }
        }
    }
}

// Helper to handle NSSound completion
class SoundDelegate: NSObject, NSSoundDelegate {
    var onFinish: () -> Void
    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }
    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        onFinish()
    }
}

extension MessageNotificationView {
    
    private var appName: String {
        let bundleId = notification.appBundleId.lowercased()
        if bundleId.lowercased().contains("whatsapp") { return "WhatsApp" }
        if bundleId.lowercased().contains("mobilesms") { return "Messages" }
        if bundleId.lowercased().contains("telegram") { return "Telegram" }
        if bundleId.lowercased().contains("discord") { return "Discord" }
        return "Message"
    }
    
    private func sendReply() {
        guard !replyText.isEmpty || selectedFileURL != nil else { return }
        
        let messageText = replyText
        let fileURL = selectedFileURL
        let bundleId = notification.appBundleId
        let sender = notification.senderIdentifier ?? notification.sender
        
        replyText = ""
        selectedFileURL = nil
        isFocused = false
        
        // Clear after reply and return to home view
        withAnimation(.smooth) {
            NotificationManager.shared.removeThread(for: notification)
            coordinator.currentView = .home
            vm.close()
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let escapedMessage = messageText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            
            // Capture current active app
            let previousApp = NSWorkspace.shared.frontmostApplication
            
            if bundleId.contains("mobilesms") {
                // iMessage / SMS
                if let file = fileURL {
                    self.sendUniversalFile(fileURL: file, text: messageText, bundleId: bundleId)
                } else {
                    let escapedSender = sender.replacingOccurrences(of: "\"", with: "\\\"")
                    let scriptSource = "tell application \"Messages\" to send \"\(messageText.replacingOccurrences(of: "\"", with: "\\\""))\" to participant \"\(escapedSender)\""
                    executeAppleScript(scriptSource)
                }
                
            } else if bundleId.contains("whatsapp") {
                // Background Bridge Integration
                if WhatsAppWebManager.shared.isAuthenticated {
                    print("MessageNotificationView: 🚀 Sending via Background Bridge")
                    if let file = fileURL {
                        WhatsAppWebManager.shared.sendFile(to: sender, fileURL: file, caption: messageText)
                    } else {
                        WhatsAppWebManager.shared.sendMessage(to: sender, text: messageText)
                    }
                } else {
                    // Fallback to legacy Phantom Send (text only for now in fallback)
                    self.sendUniversalFile(fileURL: fileURL, text: messageText, bundleId: bundleId)
                }
            } else if bundleId.lowercased().contains("telegram") {
                // Telegram (Universal/AppleScript)
                self.sendUniversalFile(fileURL: fileURL, text: messageText, bundleId: bundleId)
            } else if bundleId.lowercased().contains("discord") {
                // Discord Headless Send
                Task { @MainActor in
                    NotificationManager.shared.removeActive()
                    if let file = fileURL {
                        DiscordWebManager.shared.sendFile(channelId: sender, fileURL: file, text: messageText)
                    } else {
                        DiscordWebManager.shared.sendReply(channelId: sender, text: messageText)
                    }
                }
            } else {
                // Universal Fallback
                self.sendUniversalFile(fileURL: fileURL, text: messageText, bundleId: bundleId)
            }
        }
    }

    private func sendUniversalFile(fileURL: URL?, text: String, bundleId: String) {
        // Universal AppleScript UI Scripting Fallback
        // This activates the app, pastes the message/file and hits enter
        // Note: For files, we'll try to put the file on the clipboard or use 'posix path'
        
        let appName = self.appName // Uses the helper to get "WhatsApp", "Telegram", etc.
        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")
        
        var script = ""
        if let file = fileURL {
            let posixPath = file.path
            script = """
            set theFile to POSIX file "\(posixPath)"
            set theText to "\(escapedText)"
            
            tell application "System Events"
                tell process "\(appName)"
                    set frontmost to true
                    -- Try to copy file to clipboard
                    set the clipboard to theFile
                    delay 0.2
                    keystroke "v" using {command down}
                    delay 0.5
                    if theText is not "" then
                        keystroke theText
                    end if
                    delay 0.2
                    key code 36 -- Enter
                end tell
            end tell
            """
        } else {
            script = """
            tell application "System Events"
                tell process "\(appName)"
                    set frontmost to true
                    keystroke "\(escapedText)"
                    delay 0.1
                    key code 36 -- Enter
                end tell
            end tell
            """
        }
        
        executeAppleScript(script)
    }
    
    private func executeAppleScript(_ source: String) {
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let err = error {
                print("AppleScript Error: \(err)")
            }
        }
    }
}
