/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Combine
import SkyLightWindow
import SwiftUI

// MARK: - Click Receiver Window

private class ClickReceiverWindow: NSWindow {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onClick?()
    }
}

// MARK: - Window Manager

@MainActor
final class FullScreenArtworkWindowManager {
    static let shared = FullScreenArtworkWindowManager()

    private(set) var isShowing = false
    var onDismiss: (() -> Void)?

    private let wallpaperPlistURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }()
    private let backupPlistURL: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll_wallpaper_backup.plist")
    }()
    private var artworkFileURL: URL?
    private var cachedArtworkPNG: URL?
    private var cachedArtworkIdentifier: String?
    private var activeSongTitle: String?
    private var activeArtist: String?
    private var trackChangeCancellable: AnyCancellable?
    private var artworkCacheCancellable: AnyCancellable?
    private var clickWindow: ClickReceiverWindow?
    private var clickWindowDelegated = false

    private init() {
        observeArtworkChanges()
    }

    func show(artwork: NSImage, videoURL: URL? = nil) {
        guard !isShowing else { return }
        guard let screen = NSScreen.main else { return }

        let fileURL: URL
        let artworkID = "\(MusicManager.shared.songTitle)|\(MusicManager.shared.artistName)"

        if let cached = cachedArtworkPNG,
           cachedArtworkIdentifier == artworkID,
           FileManager.default.fileExists(atPath: cached.path) {
            fileURL = cached
        } else {
            guard let encoded = encodeToPNG(artwork) else { return }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("atoll_artwork_wallpaper.png")
            do {
                try encoded.write(to: tempURL, options: .atomic)
            } catch {
                return
            }
            fileURL = tempURL
            cachedArtworkPNG = tempURL
            cachedArtworkIdentifier = artworkID
        }

        artworkFileURL = fileURL
        backupWallpaperConfig()

        guard applyArtworkToPlist(imageURL: fileURL) else {
            print("[FullScreenArtworkWindowManager] Failed to patch plist")
            return
        }

        restartWallpaperAgent()
        showClickReceiver(on: screen)

        isShowing = true
        activeSongTitle = MusicManager.shared.songTitle
        activeArtist = MusicManager.shared.artistName

        observeTrackChanges()

        print("[FullScreenArtworkWindowManager] Artwork applied as wallpaper")
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        trackChangeCancellable?.cancel()
        trackChangeCancellable = nil

        hideClickReceiver()
        restoreWallpaper()

        activeSongTitle = nil
        activeArtist = nil

        let callback = onDismiss
        onDismiss = nil
        callback?()

        print("[FullScreenArtworkWindowManager] Original wallpaper restored")
    }

    // MARK: - Artwork Pre-Cache

    private func observeArtworkChanges() {
        artworkCacheCancellable = MusicManager.shared.$albumArt
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] newArt in
                guard let self else { return }
                let artID = "\(MusicManager.shared.songTitle)|\(MusicManager.shared.artistName)"
                guard artID != self.cachedArtworkIdentifier else { return }
                Task.detached(priority: .utility) {
                    guard let pngData = self.encodeToPNG(newArt) else { return }
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("atoll_artwork_wallpaper.png")
                    try? pngData.write(to: url, options: .atomic)
                    await MainActor.run {
                        self.cachedArtworkPNG = url
                        self.cachedArtworkIdentifier = artID
                    }
                }
            }
    }

    private nonisolated func encodeToPNG(_ image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Click Receiver

    private func showClickReceiver(on screen: NSScreen) {
        let screenFrame = screen.frame

        let window: ClickReceiverWindow
        if let existing = clickWindow {
            window = existing
        } else {
            let newWindow = ClickReceiverWindow(
                contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newWindow.isReleasedWhenClosed = false
            newWindow.isOpaque = false
            newWindow.backgroundColor = .clear
            newWindow.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            newWindow.isMovable = false
            newWindow.hasShadow = false

            ScreenCaptureVisibilityManager.shared.register(newWindow, scope: .entireInterface)
            clickWindow = newWindow
            window = newWindow
            clickWindowDelegated = false
        }

        window.setFrame(screenFrame, display: true)
        window.onClick = { [weak self] in
            self?.hide()
        }

        if !clickWindowDelegated {
            SkyLightOperator.shared.delegateWindow(window)
            clickWindowDelegated = true
        }

        window.orderFrontRegardless()

        for other in NSApp.windows where other !== window && other.level.rawValue >= Int(CGShieldingWindowLevel()) && other.isVisible {
            window.order(.below, relativeTo: other.windowNumber)
        }
    }

    private func hideClickReceiver() {
        clickWindow?.orderOut(nil)
        clickWindow?.onClick = nil
    }

    // MARK: - Backup / Restore

    private var hasValidBackup: Bool {
        FileManager.default.fileExists(atPath: backupPlistURL.path)
    }

    private func backupWallpaperConfig() {
        guard !hasValidBackup else { return }
        try? FileManager.default.copyItem(at: wallpaperPlistURL, to: backupPlistURL)
    }

    private func applyArtworkToPlist(imageURL: URL) -> Bool {
        guard let plistData = try? Data(contentsOf: wallpaperPlistURL),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        else { return false }

        let config: [String: Any] = [
            "type": "imageFile",
            "url": ["relative": imageURL.absoluteString]
        ]
        guard let configData = try? PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
        else { return false }

        let imageChoice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.image",
            "Files": [] as [Any],
            "Configuration": configData
        ]

        let contentBlock: [String: Any] = [
            "Choices": [imageChoice],
            "Shuffle": "$null"
        ]

        let desktopBlock: [String: Any] = [
            "Content": contentBlock,
            "LastSet": Date(),
            "LastUse": Date()
        ]

        patchDesktopEntries(&plist, desktopBlock: desktopBlock)

        guard let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        else { return false }

        return (try? newData.write(to: wallpaperPlistURL, options: .atomic)) != nil
    }

    private func patchDesktopEntries(_ plist: inout [String: Any], desktopBlock: [String: Any]) {
        if var allSpaces = plist["AllSpacesAndDisplays"] as? [String: Any] {
            allSpaces["Desktop"] = desktopBlock
            plist["AllSpacesAndDisplays"] = allSpaces
        }

        if var displays = plist["Displays"] as? [String: Any] {
            for key in displays.keys {
                if var display = displays[key] as? [String: Any] {
                    display["Desktop"] = desktopBlock
                    displays[key] = display
                }
            }
            plist["Displays"] = displays
        }

        if var spaces = plist["Spaces"] as? [String: Any] {
            for spaceKey in spaces.keys {
                if var space = spaces[spaceKey] as? [String: Any] {
                    if var defaultEntry = space["Default"] as? [String: Any] {
                        defaultEntry["Desktop"] = desktopBlock
                        space["Default"] = defaultEntry
                    }
                    if var spaceDisplays = space["Displays"] as? [String: Any] {
                        for displayKey in spaceDisplays.keys {
                            if var display = spaceDisplays[displayKey] as? [String: Any] {
                                display["Desktop"] = desktopBlock
                                spaceDisplays[displayKey] = display
                            }
                        }
                        space["Displays"] = spaceDisplays
                    }
                    spaces[spaceKey] = space
                }
            }
            plist["Spaces"] = spaces
        }
    }

    private func restartWallpaperAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
    }

    private func restoreWallpaper() {
        let fm = FileManager.default
        guard hasValidBackup else { return }

        do {
            try fm.removeItem(at: wallpaperPlistURL)
            try fm.copyItem(at: backupPlistURL, to: wallpaperPlistURL)
            try fm.removeItem(at: backupPlistURL)
        } catch {
            print("[FullScreenArtworkWindowManager] Failed to restore plist: \(error)")
        }

        restartWallpaperAgent()
    }

    // MARK: - Track Change Observer

    private func observeTrackChanges() {
        trackChangeCancellable?.cancel()
        trackChangeCancellable = MusicManager.shared.$songTitle
            .combineLatest(MusicManager.shared.$artistName)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title, artist in
                guard let self, self.isShowing else { return }
                if title != self.activeSongTitle || artist != self.activeArtist {
                    self.hide()
                }
            }
    }
}
