import SwiftUI
import Defaults

struct InPlayerNotificationBanner: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(NotificationManager.shared.notifications) { notification in
                    NotificationRow(notification: notification)
                }
            }
        }
        .frame(height: 36) // Fixed compact height
        .onHover { hovering in
            vm.isHoveringNotification = hovering
        }
    }
    
    // MARK: - Subviews
    
    private struct NotificationRow: View {
        let notification: MessageNotification
        @EnvironmentObject var vm: DynamicIslandViewModel
        @ObservedObject var coordinator = DynamicIslandViewCoordinator.shared
        
        var body: some View {
            HStack(spacing: 8) {
                mainContentButton
                dismissButton
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundView)
        }
        
        private var mainContentButton: some View {
            Button(action: {
                // Set this as the active one for expanded view
                if let index = NotificationManager.shared.notifications.firstIndex(where: { $0.id == notification.id }) {
                    NotificationManager.shared.currentIndex = index
                }
                withAnimation(.spring()) {
                    coordinator.currentView = .messages
                }
            }) {
                HStack(spacing: 8) {
                    iconView
                    contentTextView
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        
        @ViewBuilder
        private var iconView: some View {
            Group {
                if let profilePic = notification.profilePicture, Defaults[.showProfilePictures] {
                    let _ = print("BannerRow: 👤 Showing Profile Pic for \(notification.sender)")
                    Image(nsImage: profilePic)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                } else if let appIcon = notification.appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: "bubble.left.fill")
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
        }
        
        private var contentTextView: some View {
            HStack(spacing: 6) {
                combinedText
                    .lineLimit(1)
                    .truncationMode(.tail)
    
                 if let sticker = notification.stickerImage {
                    Image(nsImage: sticker)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        
        private var combinedText: Text {
            let sender = notification.isGroup && notification.groupName != nil ? "\(notification.groupName!): \(notification.sender)" : notification.sender
            let content = notification.filteredContent.isEmpty ? "" : " " + notification.filteredContent
            
            return Text(sender)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white) +
            Text(content)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.8))
        }
        
        private var dismissButton: some View {
            Button(action: {
                if let index = NotificationManager.shared.notifications.firstIndex(where: { $0.id == notification.id }) {
                    withAnimation(.spring()) {
                        NotificationManager.shared.notifications.remove(at: index)
                    }
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        
        private var backgroundView: some View {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                )
        }
    }
}
