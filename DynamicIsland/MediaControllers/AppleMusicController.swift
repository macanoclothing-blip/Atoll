/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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
import Foundation

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let trackName: String?
    let collectionName: String?
    let artworkUrl100: String?
    let collectionViewUrl: String?
    let trackViewUrl: String?
}

class AppleMusicController: MediaControllerProtocol {
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.apple.Music",
        playbackRate: 1
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var isWorking: Bool {
        return true  // AppleMusic controller always works
    }

    /// Minimum byte count for artwork data to be considered valid. Anything
    /// smaller is likely an empty descriptor or error string, not image data.
    private static let minimumArtworkSize = 16

    private var notificationTask: Task<Void, Never>?
    private var liveArtworkFetchTask: Task<Void, Never>?
    private var lastCatalogArtworkKey: String?
    private var cachedCatalogArtwork: Data?
    private var lastCatalogTrackKey: String?
    private var cachedCatalogTrack: ITunesTrack?
    private var lastMotionArtworkKey: String?
    private var cachedMotionArtworkURL: URL?

    // MARK: - Initialization
    init() {
        setupPlaybackStateChangeObserver()
        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
    }
    
    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.apple.Music.playerInfo")
            )
            
            for await _ in notifications {
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    deinit {
        notificationTask?.cancel()
        liveArtworkFetchTask?.cancel()
    }
    
    // MARK: - Protocol Implementation
    func play() async {
        await executeCommand("play")
    }
    
    func pause() async {
        await executeCommand("pause")
    }
    
    func togglePlay() async {
        await executeCommand("playpause")
    }
    
    func nextTrack() async {
        await executeCommand("next track")
    }
    
    func previousTrack() async {
        await executeCommand("previous track")
    }
    
    func seek(to time: Double) async {
        await executeCommand("set player position to \(time)")
        await updatePlaybackInfo()
    }
    
    func toggleShuffle() async {
        await executeCommand("set shuffle enabled to not shuffle enabled")
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func toggleRepeat() async {
        await executeCommand("""
            if song repeat is off then
                set song repeat to all
            else if song repeat is all then
                set song repeat to one
            else
                set song repeat to off
            end if
            """)
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }
    
    func isActive() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == "com.apple.Music" }
    }
    
    func updatePlaybackInfo() async {
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 9 else { return }
        var updatedState = self.playbackState

        updatedState.isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        updatedState.title = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        updatedState.artist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        updatedState.album = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        updatedState.currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        updatedState.duration = descriptor.atIndex(6)?.doubleValue ?? 0
        updatedState.isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let repeatModeValue = descriptor.atIndex(8)?.int32Value ?? 0
        updatedState.repeatMode = RepeatMode(rawValue: Int(repeatModeValue)) ?? .off

        // AppleScript returns artwork data for library tracks. For streamed
        // content not in the library it returns an empty descriptor, so we
        // fall back to the iTunes Search API to fetch artwork by metadata.
        if let artworkData = descriptor.atIndex(9)?.data as Data?,
           artworkData.count > Self.minimumArtworkSize {
            updatedState.artwork = artworkData
        } else {
            updatedState.artwork = await fetchArtworkFromCatalog(
                title: updatedState.title, artist: updatedState.artist, album: updatedState.album
            )
        }

        let trackKey = mediaKey(title: updatedState.title, artist: updatedState.artist, album: updatedState.album)
        if trackKey == lastMotionArtworkKey {
            updatedState.liveArtworkURL = cachedMotionArtworkURL
        }

        updatedState.lastUpdated = Date()
        self.playbackState = updatedState
        scheduleLiveArtworkFetchIfNeeded(for: updatedState)
    }

    // MARK: - Private Methods

    private func fetchArtworkFromCatalog(title: String, artist: String, album: String) async -> Data? {
        let key = "\(title)|\(artist)|\(album)"

        if key == lastCatalogArtworkKey, let cached = cachedCatalogArtwork {
            return cached
        }

        do {
            guard let match = await fetchCatalogTrack(title: title, artist: artist, album: album),
                  let artworkURLString = match.artworkUrl100
            else { return nil }
            let highResURL = artworkURLString.replacingOccurrences(of: "100x100", with: "600x600")
            guard let imageURL = URL(string: highResURL) else { return nil }

            let (imageData, _) = try await URLSession.shared.data(from: imageURL)
            lastCatalogArtworkKey = key
            cachedCatalogArtwork = imageData
            return imageData
        } catch {
            return nil
        }
    }

    private func fetchCatalogTrack(title: String, artist: String, album: String) async -> ITunesTrack? {
        let key = mediaKey(title: title, artist: artist, album: album)

        if key == lastCatalogTrackKey {
            return cachedCatalogTrack
        }

        let query = "\(title) \(artist)"
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty,
              let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=10")
        else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            guard !response.results.isEmpty else { return nil }

            let normalizedAlbum = album.lowercased()
            let normalizedTitle = title.lowercased()

            let match = response.results.first(where: {
                $0.trackName?.lowercased() == normalizedTitle &&
                $0.collectionName?.lowercased() == normalizedAlbum
            }) ?? response.results.first(where: {
                $0.collectionName?.lowercased() == normalizedAlbum
            }) ?? response.results.first(where: {
                $0.trackName?.lowercased() == normalizedTitle
            }) ?? response.results.first

            lastCatalogTrackKey = key
            cachedCatalogTrack = match
            return match
        } catch {
            return nil
        }
    }

    private func scheduleLiveArtworkFetchIfNeeded(for state: PlaybackState) {
        guard state.liveArtworkURL == nil else { return }

        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = state.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = state.album.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !title.isEmpty, !artist.isEmpty,
              title.lowercased() != "not playing",
              artist.lowercased() != "unknown"
        else { return }

        if mediaKey(title: title, artist: artist, album: album) == lastMotionArtworkKey {
            return
        }

        liveArtworkFetchTask?.cancel()

        liveArtworkFetchTask = Task { [weak self] in
            guard let self else { return }
            let liveURL = await self.fetchLiveArtworkFromCatalog(title: title, artist: artist, album: album)
            guard !Task.isCancelled else { return }
            guard self.playbackState.title == title,
                  self.playbackState.artist == artist,
                  self.playbackState.album == album
            else {
                self.liveArtworkFetchTask = nil
                return
            }

            var updatedState = self.playbackState
            updatedState.liveArtworkURL = liveURL
            updatedState.lastUpdated = Date()
            self.playbackState = updatedState
            self.liveArtworkFetchTask = nil
        }
    }

    private func fetchLiveArtworkFromCatalog(title: String, artist: String, album: String) async -> URL? {
        let key = mediaKey(title: title, artist: artist, album: album)

        if key == lastMotionArtworkKey {
            return cachedMotionArtworkURL
        }

        guard let track = await fetchCatalogTrack(title: title, artist: artist, album: album) else {
            return nil
        }

        for pageURL in candidatePageURLs(from: track) {
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 8
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let html = String(decoding: data, as: UTF8.self)
                if let motionURL = extractMotionArtworkURL(from: html) {
                    lastMotionArtworkKey = key
                    cachedMotionArtworkURL = motionURL
                    return motionURL
                }
            } catch {
                continue
            }
        }

        lastMotionArtworkKey = key
        cachedMotionArtworkURL = nil
        return nil
    }

    private func candidatePageURLs(from track: ITunesTrack) -> [URL] {
        [track.collectionViewUrl, track.trackViewUrl]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .reduce(into: [URL]()) { urls, url in
                if !urls.contains(url) {
                    urls.append(url)
                }
            }
    }

    private func extractMotionArtworkURL(from html: String) -> URL? {
        let patterns = [
            #"amp-ambient-video[^>]+src="([^"]+)""#,
            #""motionDetailSquareVideo1x1"\s*:\s*\{[^}]*"video"\s*:\s*"([^"]+)""#,
            #"(https?:\\/\\/[^"]+\.m3u8[^"]*)""#
        ]

        for pattern in patterns {
            guard let rawValue = firstRegexMatch(in: html, pattern: pattern) else { continue }
            let normalized = rawValue
                .replacingOccurrences(of: #"\/"#, with: "/")
                .replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: normalized) {
                return url
            }
        }

        return nil
    }

    private func firstRegexMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[captureRange])
    }

    private func mediaKey(title: String, artist: String, album: String) -> String {
        "\(title)|\(artist)|\(album)"
    }

    private func executeCommand(_ command: String) async {
        let script = "tell application \"Music\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Music"
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffle enabled
                set repeatState to song repeat
                if repeatState is off then
                    set repeatValue to 1
                else if repeatState is one then
                    set repeatValue to 2
                else if repeatState is all then
                    set repeatValue to 3
                end if

                set artData to ""
                try
                    set artData to raw data of artwork 1 of current track
                end try

                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatValue, artData}
            on error
                return {false, "Not Playing", "Unknown", "Unknown", 0, 0, false, 0, ""}
            end try
        end tell
        """
        return try await AppleScriptHelper.execute(script)
    }
}
