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
@preconcurrency import AVFoundation
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

private final class LoopingVideoWallpaperController {
    let player: AVPlayer
    private var endObserver: NSObjectProtocol?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.volume = 0
        player.actionAtItemEnd = .none

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }

        player.play()
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player.pause()
    }
}

private final class LoopingVideoWallpaperView: NSView {
    private let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func attach(player: AVPlayer?) {
        playerLayer.player = player
    }
}

private struct AerialWallpaperSlot {
    let assetID: String
    let assetVideoURL: URL
}

private struct ActiveAerialWallpaperOverride {
    let slot: AerialWallpaperSlot
    let backupVideoURL: URL?
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
    private let aerialVideosDirectoryURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
    }()
    private var artworkFileURL: URL?
    private var cachedArtworkPNG: URL?
    private var cachedArtworkIdentifier: String?
    private var activeSongTitle: String?
    private var activeArtist: String?
    private var trackChangeCancellable: AnyCancellable?
    private var artworkCacheCancellable: AnyCancellable?
    private var liveArtworkCancellable: AnyCancellable?
    private var clickWindow: ClickReceiverWindow?
    private var clickWindowDelegated = false
    private var videoWindow: NSWindow?
    private var videoWindowDelegated = false
    private var videoPlayerController: LoopingVideoWallpaperController?
    private var liveWallpaperPreparationTask: Task<Void, Never>?
    private var activeAerialOverride: ActiveAerialWallpaperOverride?
    private var wallpaperPresentationID = UUID()

    private var shouldPresentVideoBehindLockScreen: Bool {
        LockScreenManager.shared.isLocked
    }

    private var desiredVideoWindowLevel: NSWindow.Level {
        if shouldPresentVideoBehindLockScreen {
            return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
        }

        return NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    }

    private var supportsNativeLiveWallpaper: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    private init() {
        observeArtworkChanges()
        observeLiveArtworkChanges()
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
        restoreAerialOverride()
        liveWallpaperPreparationTask?.cancel()
        liveWallpaperPreparationTask = nil
        wallpaperPresentationID = UUID()

        let wallpaperApplied = applyArtworkToPlist(imageURL: fileURL)
        if wallpaperApplied {
            restartWallpaperAgent()
        } else if videoURL == nil {
            print("[FullScreenArtworkWindowManager] Failed to patch plist")
            return
        }

        isShowing = true
        activeSongTitle = MusicManager.shared.songTitle
        activeArtist = MusicManager.shared.artistName

        observeTrackChanges()

        if let videoURL {
            applyLiveArtworkPresentation(
                videoURL: videoURL,
                artworkID: artworkID,
                screen: screen
            )
        } else {
            hideVideoWindow()
        }

        showClickReceiver(on: screen)

        if wallpaperApplied {
            print("[FullScreenArtworkWindowManager] Artwork applied as wallpaper")
        } else {
            print("[FullScreenArtworkWindowManager] Video overlay shown without wallpaper patch")
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        wallpaperPresentationID = UUID()
        liveWallpaperPreparationTask?.cancel()
        liveWallpaperPreparationTask = nil
        trackChangeCancellable?.cancel()
        trackChangeCancellable = nil

        hideClickReceiver()
        hideVideoWindow()
        restoreAerialOverride()
        restoreWallpaper()

        activeSongTitle = nil
        activeArtist = nil

        let callback = onDismiss
        onDismiss = nil
        callback?()

        print("[FullScreenArtworkWindowManager] Original wallpaper restored")
    }

    private func scheduleNativeLiveWallpaperPreparation(
        videoURL: URL,
        artworkID: String,
        presentationID: UUID
    ) {
        guard let slot = pickAerialWallpaperSlot() else {
            print("[FullScreenArtworkWindowManager] No Aerial asset available for native live wallpaper")
            return
        }

        let preparedVideoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll_live_wallpaper_\(presentationID.uuidString).mov")

        liveWallpaperPreparationTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            do {
                try await Self.prepareVideoForAerialWallpaper(from: videoURL, outputURL: preparedVideoURL)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: preparedVideoURL)
                    return
                }

                await MainActor.run {
                    self.finishNativeLiveWallpaperPreparation(
                        preparedVideoURL: preparedVideoURL,
                        slot: slot,
                        artworkID: artworkID,
                        presentationID: presentationID
                    )
                }
            } catch {
                try? FileManager.default.removeItem(at: preparedVideoURL)
                await MainActor.run {
                    guard self.wallpaperPresentationID == presentationID else { return }
                    self.liveWallpaperPreparationTask = nil
                    print("[FullScreenArtworkWindowManager] Failed to prepare native live wallpaper: \(error)")
                    self.restoreStaticArtworkPresentation()
                }
            }
        }
    }

    private func finishNativeLiveWallpaperPreparation(
        preparedVideoURL: URL,
        slot: AerialWallpaperSlot,
        artworkID: String,
        presentationID: UUID
    ) {
        defer {
            liveWallpaperPreparationTask = nil
            try? FileManager.default.removeItem(at: preparedVideoURL)
        }

        guard isShowing,
              wallpaperPresentationID == presentationID,
              cachedArtworkIdentifier == artworkID || "\(MusicManager.shared.songTitle)|\(MusicManager.shared.artistName)" == artworkID
        else {
            return
        }

        do {
            restoreAerialOverride()
            let override = try installPreparedVideo(preparedVideoURL, into: slot)

            guard applyAerialWallpaperToPlist(assetID: slot.assetID) else {
                restoreInstalledAerialOverride(override)
                print("[FullScreenArtworkWindowManager] Failed to patch plist with Aerial asset")
                restoreStaticArtworkPresentation()
                return
            }

            activeAerialOverride = override
            restartWallpaperAgent()
            print("[FullScreenArtworkWindowManager] Native live wallpaper applied with asset \(slot.assetID)")
        } catch {
            print("[FullScreenArtworkWindowManager] Failed to install native live wallpaper: \(error)")
            restoreStaticArtworkPresentation()
        }
    }

    private func applyLiveArtworkPresentation(
        videoURL: URL,
        artworkID: String,
        screen: NSScreen? = NSScreen.main
    ) {
        liveWallpaperPreparationTask?.cancel()
        liveWallpaperPreparationTask = nil

        if supportsNativeLiveWallpaper {
            restoreAerialOverride()
            scheduleNativeLiveWallpaperPreparation(
                videoURL: videoURL,
                artworkID: artworkID,
                presentationID: wallpaperPresentationID
            )
            hideVideoWindow()
        } else if let screen {
            showVideoWindow(on: screen, videoURL: videoURL)
        }
    }

    private func restoreStaticArtworkPresentation() {
        liveWallpaperPreparationTask?.cancel()
        liveWallpaperPreparationTask = nil
        hideVideoWindow()
        restoreAerialOverride()

        guard isShowing,
              let artworkFileURL,
              applyArtworkToPlist(imageURL: artworkFileURL)
        else {
            return
        }

        restartWallpaperAgent()
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

    private func observeLiveArtworkChanges() {
        liveArtworkCancellable = MusicManager.shared.$liveArtworkURL
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] liveArtworkURL in
                guard let self, self.isShowing else { return }

                let artworkID = "\(self.activeSongTitle ?? MusicManager.shared.songTitle)|\(self.activeArtist ?? MusicManager.shared.artistName)"

                if let liveArtworkURL {
                    self.applyLiveArtworkPresentation(videoURL: liveArtworkURL, artworkID: artworkID)
                } else {
                    self.restoreStaticArtworkPresentation()
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

    private func showVideoWindow(on screen: NSScreen, videoURL: URL) {
        let screenFrame = screen.frame

        let window: NSWindow
        if let existing = videoWindow {
            window = existing
        } else {
            let newWindow = NSWindow(
                contentRect: screenFrame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newWindow.isReleasedWhenClosed = false
            newWindow.isOpaque = false
            newWindow.backgroundColor = .clear
            newWindow.level = desiredVideoWindowLevel
            newWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            newWindow.isMovable = false
            newWindow.hasShadow = false
            newWindow.ignoresMouseEvents = true

            ScreenCaptureVisibilityManager.shared.register(newWindow, scope: .entireInterface)
            videoWindow = newWindow
            videoWindowDelegated = false
            window = newWindow
        }

        let contentView: LoopingVideoWallpaperView
        if let existing = window.contentView as? LoopingVideoWallpaperView {
            contentView = existing
        } else {
            let newView = LoopingVideoWallpaperView(frame: NSRect(origin: .zero, size: screenFrame.size))
            newView.autoresizingMask = [.width, .height]
            window.contentView = newView
            contentView = newView
        }

        window.level = desiredVideoWindowLevel
        window.setFrame(screenFrame, display: true)
        contentView.frame = NSRect(origin: .zero, size: screenFrame.size)

        videoPlayerController = LoopingVideoWallpaperController(url: videoURL)
        contentView.attach(player: videoPlayerController?.player)

        if !videoWindowDelegated {
            SkyLightOperator.shared.delegateWindow(window)
            videoWindowDelegated = true
        }

        window.orderFrontRegardless()
    }

    private func hideVideoWindow() {
        videoPlayerController = nil
        (videoWindow?.contentView as? LoopingVideoWallpaperView)?.attach(player: nil)
        videoWindow?.orderOut(nil)
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

        guard let wallpaperBlock = makeImageWallpaperBlock(imageURL: imageURL) else { return false }

        patchWallpaperEntries(&plist, desktopBlock: wallpaperBlock, idleBlock: wallpaperBlock)

        guard let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        else { return false }

        return (try? newData.write(to: wallpaperPlistURL, options: .atomic)) != nil
    }

    private func applyAerialWallpaperToPlist(assetID: String) -> Bool {
        guard let plistData = try? Data(contentsOf: wallpaperPlistURL),
              var plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let wallpaperBlock = makeAerialWallpaperBlock(assetID: assetID)
        else { return false }

        patchWallpaperEntries(&plist, desktopBlock: wallpaperBlock, idleBlock: wallpaperBlock)

        guard let newData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        else { return false }

        return (try? newData.write(to: wallpaperPlistURL, options: .atomic)) != nil
    }

    private func makeImageWallpaperBlock(imageURL: URL) -> [String: Any]? {
        let config: [String: Any] = [
            "type": "imageFile",
            "url": ["relative": imageURL.absoluteString]
        ]
        guard let configData = try? PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
        else { return nil }

        let imageChoice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.image",
            "Files": [] as [Any],
            "Configuration": configData
        ]

        let contentBlock: [String: Any] = [
            "Choices": [imageChoice],
            "Shuffle": "$null"
        ]

        return [
            "Content": contentBlock,
            "LastSet": Date(),
            "LastUse": Date()
        ]
    }

    private func makeAerialWallpaperBlock(assetID: String) -> [String: Any]? {
        let config: [String: Any] = [
            "assetID": assetID
        ]
        guard let configData = try? PropertyListSerialization.data(fromPropertyList: config, format: .binary, options: 0)
        else { return nil }

        let aerialChoice: [String: Any] = [
            "Provider": "com.apple.wallpaper.choice.aerials",
            "Files": [] as [Any],
            "Configuration": configData
        ]

        return [
            "Content": [
                "Choices": [aerialChoice],
                "Shuffle": "$null"
            ],
            "LastSet": Date(),
            "LastUse": Date()
        ]
    }

    private func patchWallpaperEntries(
        _ plist: inout [String: Any],
        desktopBlock: [String: Any],
        idleBlock: [String: Any]
    ) {
        if var allSpaces = plist["AllSpacesAndDisplays"] as? [String: Any] {
            allSpaces["Desktop"] = desktopBlock
            allSpaces["Idle"] = idleBlock
            plist["AllSpacesAndDisplays"] = allSpaces
        }

        if var systemDefault = plist["SystemDefault"] as? [String: Any] {
            systemDefault["Desktop"] = desktopBlock
            systemDefault["Idle"] = idleBlock
            plist["SystemDefault"] = systemDefault
        }

        if var displays = plist["Displays"] as? [String: Any] {
            for key in displays.keys {
                if var display = displays[key] as? [String: Any] {
                    display["Desktop"] = desktopBlock
                    display["Idle"] = idleBlock
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
                        defaultEntry["Idle"] = idleBlock
                        space["Default"] = defaultEntry
                    }
                    if var spaceDisplays = space["Displays"] as? [String: Any] {
                        for displayKey in spaceDisplays.keys {
                            if var display = spaceDisplays[displayKey] as? [String: Any] {
                                display["Desktop"] = desktopBlock
                                display["Idle"] = idleBlock
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

    private func pickAerialWallpaperSlot() -> AerialWallpaperSlot? {
        let fileManager = FileManager.default

        if let plistData = try? Data(contentsOf: wallpaperPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
           let preferredAssetID = preferredAerialAssetID(from: plist)
        {
            let preferredURL = aerialVideosDirectoryURL.appendingPathComponent("\(preferredAssetID).mov")
            if fileManager.fileExists(atPath: preferredURL.path) {
                return AerialWallpaperSlot(assetID: preferredAssetID, assetVideoURL: preferredURL)
            }
        }

        guard let candidates = try? fileManager.contentsOfDirectory(
            at: aerialVideosDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        guard let firstVideo = candidates
            .filter({ $0.pathExtension.lowercased() == "mov" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first
        else {
            return nil
        }

        return AerialWallpaperSlot(
            assetID: firstVideo.deletingPathExtension().lastPathComponent,
            assetVideoURL: firstVideo
        )
    }

    private func preferredAerialAssetID(from plist: [String: Any]) -> String? {
        var candidates: [[String: Any]] = []

        if let allSpaces = plist["AllSpacesAndDisplays"] as? [String: Any] {
            if let idle = allSpaces["Idle"] as? [String: Any] {
                candidates.append(idle)
            }
            if let desktop = allSpaces["Desktop"] as? [String: Any] {
                candidates.append(desktop)
            }
        }

        if let systemDefault = plist["SystemDefault"] as? [String: Any] {
            if let idle = systemDefault["Idle"] as? [String: Any] {
                candidates.append(idle)
            }
            if let desktop = systemDefault["Desktop"] as? [String: Any] {
                candidates.append(desktop)
            }
        }

        if let displays = plist["Displays"] as? [String: Any] {
            for value in displays.values {
                guard let display = value as? [String: Any] else { continue }
                if let idle = display["Idle"] as? [String: Any] {
                    candidates.append(idle)
                }
                if let desktop = display["Desktop"] as? [String: Any] {
                    candidates.append(desktop)
                }
            }
        }

        for block in candidates {
            if let assetID = aerialAssetID(in: block) {
                return assetID
            }
        }

        return nil
    }

    private func aerialAssetID(in wallpaperBlock: [String: Any]) -> String? {
        guard let content = wallpaperBlock["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]]
        else {
            return nil
        }

        for choice in choices {
            guard choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
                  let configurationData = choice["Configuration"] as? Data,
                  let configuration = try? PropertyListSerialization.propertyList(from: configurationData, format: nil) as? [String: Any],
                  let assetID = configuration["assetID"] as? String,
                  !assetID.isEmpty
            else {
                continue
            }

            return assetID
        }

        return nil
    }

    private func installPreparedVideo(_ preparedVideoURL: URL, into slot: AerialWallpaperSlot) throws -> ActiveAerialWallpaperOverride {
        let fileManager = FileManager.default
        let backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll_aerial_backup_\(slot.assetID).mov")
        let originalExists = fileManager.fileExists(atPath: slot.assetVideoURL.path)

        try fileManager.createDirectory(
            at: slot.assetVideoURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try? fileManager.removeItem(at: backupURL)

        if originalExists {
            try fileManager.moveItem(at: slot.assetVideoURL, to: backupURL)
        }

        do {
            try fileManager.copyItem(at: preparedVideoURL, to: slot.assetVideoURL)
        } catch {
            if originalExists, fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: slot.assetVideoURL)
            }
            throw error
        }

        return ActiveAerialWallpaperOverride(
            slot: slot,
            backupVideoURL: originalExists ? backupURL : nil
        )
    }

    private func restoreAerialOverride() {
        guard let override = activeAerialOverride else { return }
        restoreInstalledAerialOverride(override)
        activeAerialOverride = nil
    }

    private func restoreInstalledAerialOverride(_ override: ActiveAerialWallpaperOverride) {
        let fileManager = FileManager.default

        do {
            if fileManager.fileExists(atPath: override.slot.assetVideoURL.path) {
                try fileManager.removeItem(at: override.slot.assetVideoURL)
            }

            if let backupVideoURL = override.backupVideoURL,
               fileManager.fileExists(atPath: backupVideoURL.path)
            {
                try fileManager.moveItem(at: backupVideoURL, to: override.slot.assetVideoURL)
            }
        } catch {
            print("[FullScreenArtworkWindowManager] Failed to restore Aerial asset: \(error)")
        }
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

    private nonisolated static func prepareVideoForAerialWallpaper(
        from sourceURL: URL,
        outputURL: URL
    ) async throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: outputURL)

        do {
            try await exportVideoForAerialWallpaper(from: sourceURL, outputURL: outputURL)
            try await validatePreparedVideoForWallpaper(at: outputURL)
            return
        } catch {
            if sourceURL.isFileURL {
                try fileManager.copyItem(at: sourceURL, to: outputURL)
                try await validatePreparedVideoForWallpaper(at: outputURL)
                return
            }

            let lowercaseExtension = sourceURL.pathExtension.lowercased()
            guard lowercaseExtension == "mp4" || lowercaseExtension == "mov" else {
                throw error
            }

            let (downloadedURL, _) = try await URLSession.shared.download(from: sourceURL)
            try? fileManager.removeItem(at: outputURL)
            try fileManager.moveItem(at: downloadedURL, to: outputURL)
            try await validatePreparedVideoForWallpaper(at: outputURL)
        }
    }

    private nonisolated static func validatePreparedVideoForWallpaper(at url: URL) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "AtollLiveWallpaper",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Prepared live wallpaper file is missing"]
            )
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize > 0 else {
            throw NSError(
                domain: "AtollLiveWallpaper",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Prepared live wallpaper file is empty"]
            )
        }

        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        guard isPlayable else {
            throw NSError(
                domain: "AtollLiveWallpaper",
                code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Prepared live wallpaper is not playable"]
            )
        }

        let tracks = try await asset.load(.tracks)
        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw NSError(
                domain: "AtollLiveWallpaper",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Prepared live wallpaper has no video track"]
            )
        }

        let duration = try await asset.load(.duration)
        guard duration.isValid, !duration.isIndefinite, duration.seconds.isFinite, duration.seconds > 0.1 else {
            throw NSError(
                domain: "AtollLiveWallpaper",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Prepared live wallpaper has an invalid duration"]
            )
        }
    }

    private nonisolated static func exportVideoForAerialWallpaper(
        from sourceURL: URL,
        outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let presetName: String

        if presets.contains(AVAssetExportPresetPassthrough) {
            presetName = AVAssetExportPresetPassthrough
        } else if presets.contains(AVAssetExportPresetHighestQuality) {
            presetName = AVAssetExportPresetHighestQuality
        } else if let firstPreset = presets.first {
            presetName = firstPreset
        } else {
            throw NSError(domain: "AtollLiveWallpaper", code: 1, userInfo: [NSLocalizedDescriptionKey: "No compatible export preset"])
        }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw NSError(domain: "AtollLiveWallpaper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create export session"])
        }

        exportSession.outputURL = outputURL
        exportSession.shouldOptimizeForNetworkUse = true

        if exportSession.supportedFileTypes.contains(.mov) {
            exportSession.outputFileType = .mov
        } else if let supportedType = exportSession.supportedFileTypes.first {
            exportSession.outputFileType = supportedType
        } else {
            throw NSError(domain: "AtollLiveWallpaper", code: 3, userInfo: [NSLocalizedDescriptionKey: "No supported output file types"])
        }

        try await withCheckedThrowingContinuation { continuation in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: exportSession.error ?? NSError(
                        domain: "AtollLiveWallpaper",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Export failed"]
                    ))
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: NSError(
                        domain: "AtollLiveWallpaper",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected export status \(exportSession.status.rawValue)"]
                    ))
                }
            }
        }
    }
}
