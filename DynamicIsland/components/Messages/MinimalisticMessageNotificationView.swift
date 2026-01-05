//
//  MinimalisticMessageNotificationView.swift
//  DynamicIsland
//
//  Created for minimalistic UI mode - Compact message notification display
//

import SwiftUI
import Defaults

struct MinimalisticMessageNotificationView: View {
    let notification: MessageNotification
    @State private var replyText: String = ""
    @FocusState private var isReplyFieldFocused: Bool
    @Default(.showProfilePictures) var showProfilePictures
    @Default(.enableQuickReply) var enableQuickReply
    
    var body: some View {
        VStack(spacing: 12) {
            // Header: Profile Picture + Sender
            HStack(spacing: 12) {
                // Profile Picture or App Icon
                if notification.appBundleId.lowercased().contains("discord"), let serverIcon = notification.serverIcon {
                    // SPECIAL DISCORD LAYOUT: Server Icon (Big) + User Avatar (Small Overlay)
                    ZStack(alignment: .bottomLeading) {
                        Image(nsImage: serverIcon)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        
                        if let pp = notification.profilePicture {
                            Image(nsImage: pp)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 18, height: 18)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                                .offset(x: -4, y: 4)
                        }
                    }
                } else if showProfilePictures, let profilePic = notification.profilePicture {
                    // FACE with small app badge
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: profilePic)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                        
                        // Small overlay badge
                        if let appIcon = notification.appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 12, height: 12) // Slightly smaller as requested
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.black, lineWidth: 1.2))
                                .offset(x: 3, y: 3)
                        }
                    }
                } else {
                    ZStack(alignment: .bottomTrailing) {
                        if let appIcon = notification.appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    if notification.appBundleId.lowercased().contains("discord"), let serverName = notification.serverName {
                        HStack(spacing: 4) {
                            Text(serverName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(">")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                            Text(notification.sender)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        
                        if let channel = notification.channelName {
                            Text(channel)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    } else {
                        Text(notification.sender)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    
                    if notification.appBundleId.lowercased().contains("discord") {
                        Text(notification.timestamp, style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    } else {
                        Text(notification.timestamp, style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            // Message Content
            ScrollView {
                Text(notification.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            .frame(maxHeight: 60)
            
            if enableQuickReply {
                // Reply Field (Compact)
                HStack(spacing: 8) {
                    TextField("Reply...", text: $replyText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .focused($isReplyFieldFocused)
                        .onSubmit {
                            sendReply()
                        }
                    
                    Button(action: { sendReply() }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(replyText.isEmpty)
                    .opacity(replyText.isEmpty ? 0.5 : 1)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    private func sendReply() {
        guard !replyText.isEmpty else { return }
        
        let messageText = replyText
        replyText = ""
        isReplyFieldFocused = false
        
        NotificationManager.shared.removeActive()
        
        let bundleId = notification.appBundleId
        let sender = notification.senderIdentifier ?? notification.sender
        
        DispatchQueue.global(qos: .userInitiated).async {
            let escapedMessage = messageText.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            
            // Capture current active app
            let previousApp = NSWorkspace.shared.frontmostApplication
            
            if bundleId.lowercased().contains("mobilesms") {
                // iMessage / SMS (Backgroundable)
                let escapedSender = sender.replacingOccurrences(of: "\"", with: "\\\"")
                let scriptSource = "tell application \"Messages\" to send \"\(messageText.replacingOccurrences(of: "\"", with: "\\\""))\" to participant \"\(escapedSender)\""
                executeAppleScript(scriptSource)
                
            } else if bundleId.lowercased().contains("whatsapp") {
                // WhatsApp Phantom Send
                let phone = sender.components(separatedBy: "@").first ?? ""
                if let url = URL(string: "whatsapp://send?phone=\(phone)&text=\(escapedMessage)") {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = false
                    
                    NSWorkspace.shared.open(url, configuration: config) { app, error in
                        if error == nil {
                            let scriptSource = """
                            delay 0.5
                            tell application "System Events"
                                if exists process "WhatsApp" then
                                    tell process "WhatsApp"
                                        set frontmost to true
                                        key code 36
                                    end tell
                                end if
                            end tell
                            delay 0.1
                            tell application "WhatsApp" to set visible to false
                            """
                            self.executeAppleScript(scriptSource)
                            
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                previousApp?.activate(options: .activateIgnoringOtherApps)
                            }
                        }
                    }
                }
            } else if bundleId.lowercased().contains("telegram") {
                // Telegram Headless Send
                Task { @MainActor in
                     NotificationManager.shared.removeActive()
                     TelegramWebManager.shared.sendReply(username: sender, text: messageText)
                }
            } else if bundleId.lowercased().contains("discord") {
                // Discord Headless Send
                Task { @MainActor in
                    NotificationManager.shared.removeActive()
                    DiscordWebManager.shared.sendReply(channelId: sender, text: messageText)
                }
            } else {
                print("NotificationManager: Universal reply for \(bundleId) not yet implemented.")
            }
        }
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
