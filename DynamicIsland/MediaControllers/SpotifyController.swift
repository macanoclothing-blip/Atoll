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

import Foundation
import Combine
import SwiftUI

private actor SpotifyCanvasResolver {
    private struct CanvasCandidate {
        let url: URL
        let score: Int
    }

    private struct IdentifierMatch {
        let distance: Int
        let baseScore: Int
        let precedesURL: Bool
    }

    private let fileManager = FileManager.default
    private var resolvedCache: [String: URL] = [:]

    func resolveCanvasURL(trackIdentifiers: [String]) async -> URL? {
        let normalizedIdentifiers = normalized(trackIdentifiers)
        guard !normalizedIdentifiers.isEmpty else { return nil }

        let cacheKey = normalizedIdentifiers.sorted().joined(separator: "|")
        if let cached = resolvedCache[cacheKey] {
            return cached
        }

        let result = searchCanvasURL(trackIdentifiers: normalizedIdentifiers)
        if let result {
            resolvedCache[cacheKey] = result
        }
        return result
    }

    private func normalized(_ identifiers: [String]) -> [String] {
        Array(Set(
            identifiers
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        ))
    }

    private func searchCanvasURL(trackIdentifiers: [String]) -> URL? {
        var bestCandidate = searchPersistentCache(trackIdentifiers: trackIdentifiers)

        for (fileIndex, fileURL) in indexedDBCandidateFiles().enumerated() {
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { continue }
            let sourceBias = max(0, 80 - fileIndex)

            if let candidate = bestIndexedDBCanvasCandidate(
                from: data,
                trackIdentifiers: trackIdentifiers,
                sourceBias: sourceBias
            ) {
                bestCandidate = preferredCandidate(bestCandidate, candidate)
            }
        }

        return bestCandidate?.url
    }

    private func persistentCacheCandidateFiles() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let persistentCacheRoot = home.appendingPathComponent(
            "Library/Application Support/Spotify/PersistentCache/Users",
            isDirectory: true
        )

        return newestFiles(in: persistentCacheRoot, limit: 160) { url in
            url.pathExtension.lowercased() == "ldb"
        }
    }

    private func indexedDBCandidateFiles() -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let blobRoot = home.appendingPathComponent(
            "Library/Caches/com.spotify.client/Default/IndexedDB/https_xpui.app.spotify.com_0.indexeddb.blob",
            isDirectory: true
        )
        let levelDBRoot = home.appendingPathComponent(
            "Library/Caches/com.spotify.client/Default/IndexedDB/https_xpui.app.spotify.com_0.indexeddb.leveldb",
            isDirectory: true
        )

        return newestFiles(in: blobRoot, limit: 120) { _ in
            true
        } + newestFiles(in: levelDBRoot, limit: 60) { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasSuffix(".ldb") || name.hasSuffix(".log") || name.hasPrefix("manifest")
        }
    }

    private func searchPersistentCache(trackIdentifiers: [String]) -> CanvasCandidate? {
        let trackURIs = trackIdentifiers
            .compactMap(normalizedTrackURI)

        guard !trackURIs.isEmpty else { return nil }
        var bestCandidate: CanvasCandidate?

        for (fileIndex, fileURL) in persistentCacheCandidateFiles().enumerated() {
            guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else { continue }
            let sourceBias = max(160, 260 - fileIndex)

            for trackURI in trackURIs {
                if let candidate = extractPersistentCanvasCandidate(
                    from: data,
                    trackURI: trackURI,
                    sourceBias: sourceBias
                ) {
                    bestCandidate = preferredCandidate(bestCandidate, candidate)
                }
            }
        }

        return bestCandidate
    }

    private func newestFiles(in root: URL, limit: Int, filter: (URL) -> Bool) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [(url: URL, modificationDate: Date)] = []

        for case let fileURL as URL in enumerator {
            guard filter(fileURL),
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true
            else {
                continue
            }

            candidates.append((fileURL, values.contentModificationDate ?? .distantPast))
        }

        return candidates
            .sorted { $0.modificationDate > $1.modificationDate }
            .prefix(limit)
            .map(\.url)
    }

    private func normalizedTrackURI(from identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("spotify:track:") {
            return trimmed
        }

        guard trimmed.count == 22 else { return nil }
        return "spotify:track:\(trimmed)"
    }

    private func extractPersistentCanvasCandidate(
        from data: Data,
        trackURI: String,
        sourceBias: Int
    ) -> CanvasCandidate? {
        guard let trackData = trackURI.data(using: .utf8) else { return nil }

        var searchRange = data.startIndex..<data.endIndex
        var bestCandidate: CanvasCandidate?

        while let matchRange = data.range(of: trackData, options: [], in: searchRange) {
            let snippetRange = recordRange(in: data, around: matchRange)
            let snippet = String(decoding: data[snippetRange], as: UTF8.self)

            if let candidate = bestCanvasCandidate(
                in: snippet,
                trackIdentifiers: [trackURI],
                sourceBias: sourceBias
            ) {
                bestCandidate = preferredCandidate(bestCandidate, candidate)
            }

            searchRange = matchRange.upperBound..<data.endIndex
        }

        return bestCandidate
    }

    private func bestIndexedDBCanvasCandidate(
        from data: Data,
        trackIdentifiers: [String],
        sourceBias: Int
    ) -> CanvasCandidate? {
        guard let canvasSuffixData = ".cnvs.mp4".data(using: .utf8) else { return nil }

        var searchRange = data.startIndex..<data.endIndex
        var bestCandidate: CanvasCandidate?

        while let suffixRange = data.range(of: canvasSuffixData, options: [], in: searchRange) {
            let snippetRange = recordRange(in: data, around: suffixRange)
            let snippet = String(decoding: data[snippetRange], as: UTF8.self)

            if let candidate = bestCanvasCandidate(
                in: snippet,
                trackIdentifiers: trackIdentifiers,
                sourceBias: sourceBias
            ) {
                bestCandidate = preferredCandidate(bestCandidate, candidate)
            }

            searchRange = suffixRange.upperBound..<data.endIndex
        }

        return bestCandidate
    }

    private func bestCanvasCandidate(
        in text: String,
        trackIdentifiers: [String],
        sourceBias: Int
    ) -> CanvasCandidate? {
        let patterns = [
            #"https?://[^"'\\s]+\.cnvs\.mp4"#,
            #"upload/[A-Za-z0-9/_\-.]+\.cnvs\.mp4"#
        ]

        var bestCandidate: CanvasCandidate?

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }

            let searchRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: searchRange) {
                guard let captureRange = Range(match.range, in: text) else { continue }
                let rawValue = String(text[captureRange])
                guard let url = normalizedCanvasURL(from: rawValue),
                      let score = scoreCanvasCandidate(
                        urlToken: rawValue,
                        in: text,
                        trackIdentifiers: trackIdentifiers,
                        sourceBias: sourceBias
                      )
                else {
                    continue
                }

                let candidate = CanvasCandidate(url: url, score: score)
                bestCandidate = preferredCandidate(bestCandidate, candidate)
            }
        }

        return bestCandidate
    }

    private func scoreCanvasCandidate(
        urlToken: String,
        in text: String,
        trackIdentifiers: [String],
        sourceBias: Int
    ) -> Int? {
        guard let urlRange = text.range(of: urlToken) else { return nil }
        let urlPosition = text.distance(from: text.startIndex, to: urlRange.lowerBound)

        var bestScore: Int?

        for identifier in trackIdentifiers {
            guard let match = strongestIdentifierMatch(for: identifier, in: text, urlPosition: urlPosition) else {
                continue
            }

            var score = sourceBias + match.baseScore - match.distance
            score += match.precedesURL ? 120 : -30

            if text.contains("associationsV3") {
                score += 35
            }
            if text.contains("VIDEO_LOOPING") {
                score += 20
            }
            if text.localizedCaseInsensitiveContains("canvas") {
                score += 15
            }

            if let existing = bestScore {
                bestScore = max(existing, score)
            } else {
                bestScore = score
            }
        }

        guard let bestScore, bestScore >= 520 else { return nil }
        return bestScore
    }

    private func strongestIdentifierMatch(
        for identifier: String,
        in text: String,
        urlPosition: Int
    ) -> IdentifierMatch? {
        guard !identifier.isEmpty else { return nil }

        let isTrackURI = identifier.hasPrefix("spotify:track:")
        let maxDistance = isTrackURI ? 1_400 : 420
        let baseScore = isTrackURI ? 1_500 : 950

        var bestMatch: IdentifierMatch?
        var searchRange = text.startIndex..<text.endIndex

        while let matchRange = text.range(of: identifier, options: [.caseInsensitive], range: searchRange) {
            if isTrackURI || isIdentifierBoundary(matchRange, in: text) {
                let matchPosition = text.distance(from: text.startIndex, to: matchRange.lowerBound)
                let distance = abs(matchPosition - urlPosition)

                if distance <= maxDistance {
                    let candidate = IdentifierMatch(
                        distance: distance,
                        baseScore: baseScore,
                        precedesURL: matchPosition <= urlPosition
                    )

                    if let existing = bestMatch {
                        bestMatch = preferredIdentifierMatch(existing, candidate)
                    } else {
                        bestMatch = candidate
                    }
                }
            }

            searchRange = matchRange.upperBound..<text.endIndex
        }

        return bestMatch
    }

    private func preferredIdentifierMatch(
        _ lhs: IdentifierMatch,
        _ rhs: IdentifierMatch
    ) -> IdentifierMatch {
        let lhsScore = lhs.baseScore - lhs.distance + (lhs.precedesURL ? 60 : 0)
        let rhsScore = rhs.baseScore - rhs.distance + (rhs.precedesURL ? 60 : 0)
        return lhsScore >= rhsScore ? lhs : rhs
    }

    private func preferredCandidate(
        _ lhs: CanvasCandidate?,
        _ rhs: CanvasCandidate
    ) -> CanvasCandidate {
        guard let lhs else { return rhs }
        return lhs.score >= rhs.score ? lhs : rhs
    }

    private func normalizedCanvasURL(from rawValue: String) -> URL? {
        if rawValue.hasPrefix("http") {
            return URL(string: rawValue)
        }

        if rawValue.hasPrefix("upload/") {
            return URL(string: "https://canvaz.scdn.co/\(rawValue)")
        }

        return nil
    }

    private func recordRange(in data: Data, around anchor: Range<Data.Index>) -> Range<Data.Index> {
        let lowerFallback = max(data.startIndex, anchor.lowerBound - 2_048)
        let upperFallback = min(data.endIndex, anchor.upperBound + 2_048)
        let markers = [
            Data("xmeta#cache#".utf8),
            Data("__typename".utf8),
            Data("associationsV3".utf8)
        ]

        var lowerBound = lowerFallback
        for marker in markers {
            if let markerRange = data.range(of: marker, options: [.backwards], in: lowerFallback..<anchor.lowerBound),
               markerRange.lowerBound > lowerBound {
                lowerBound = markerRange.lowerBound
            }
        }

        var upperBound = upperFallback
        for marker in markers {
            if let markerRange = data.range(of: marker, options: [], in: anchor.upperBound..<upperFallback),
               markerRange.lowerBound < upperBound {
                upperBound = markerRange.lowerBound
            }
        }

        if upperBound <= lowerBound {
            return lowerFallback..<upperFallback
        }

        return lowerBound..<upperBound
    }

    private func isIdentifierBoundary(_ range: Range<String.Index>, in text: String) -> Bool {
        let lowerIsBoundary: Bool
        if range.lowerBound == text.startIndex {
            lowerIsBoundary = true
        } else {
            lowerIsBoundary = !isIdentifierCharacter(text[text.index(before: range.lowerBound)])
        }

        let upperIsBoundary: Bool
        if range.upperBound == text.endIndex {
            upperIsBoundary = true
        } else {
            upperIsBoundary = !isIdentifierCharacter(text[range.upperBound])
        }

        return lowerIsBoundary && upperIsBoundary
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == ":" || character == "-" || character == "_"
    }
}

class SpotifyController: MediaControllerProtocol {
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.spotify.client"
    )
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }
    
    var isWorking: Bool {
        return true  // Spotify controller always works
    }
    
    private var notificationTask: Task<Void, Never>?
    
    // Constant for time between command and update
    private let commandUpdateDelay: Duration = .milliseconds(25)

    private let canvasResolver = SpotifyCanvasResolver()
    private var lastArtworkURL: String?
    private var artworkFetchTask: Task<Void, Never>?
    private var liveArtworkFetchTask: Task<Void, Never>?
    private var lastCanvasTrackKey: String?
    
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
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            
            for await _ in notifications {
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    deinit {
        notificationTask?.cancel()
        artworkFetchTask?.cancel()
        liveArtworkFetchTask?.cancel()
    }
    
    // MARK: - Protocol Implementation
    func play() async { await executeCommand("play") }
    func pause() async { await executeCommand("pause") }
    func togglePlay() async { await executeCommand("playpause") }
    func nextTrack() async { await executeCommand("next track") }
    
    func previousTrack() async {
        await executeAndRefresh("previous track")
    }
    
    func seek(to time: Double) async {
        await executeAndRefresh("set player position to \(time)")
    }
    
    func toggleShuffle() async {
        await executeAndRefresh("set shuffling to not shuffling")
    }
    
    func toggleRepeat() async {
        await executeAndRefresh("set repeating to not repeating")
    }
    
    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == playbackState.bundleIdentifier }
    }
    
    func updatePlaybackInfo() async {
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 11 else { return }
        
        let isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        let currentTrack = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        let currentTrackArtist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        let currentTrackAlbum = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        let currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        let duration = (descriptor.atIndex(6)?.doubleValue ?? 0)/1000
        let isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let isRepeating = descriptor.atIndex(8)?.booleanValue ?? false
        let artworkURL = descriptor.atIndex(9)?.stringValue ?? ""
        let trackID = descriptor.atIndex(10)?.stringValue ?? ""
        let spotifyURLString = descriptor.atIndex(11)?.stringValue ?? ""
        let trackIdentifiers = trackIdentifiers(trackID: trackID, spotifyURLString: spotifyURLString)
        let canvasTrackKey = trackIdentifiers.sorted().joined(separator: "|")
        
        var state = PlaybackState(
            bundleIdentifier: "com.spotify.client",
            isPlaying: isPlaying,
            title: currentTrack,
            artist: currentTrackArtist,
            album: currentTrackAlbum,
            currentTime: currentTime,
            duration: duration,
            playbackRate: 1,
            isShuffled: isShuffled,
            repeatMode: isRepeating ? .all : .off,
            lastUpdated: Date()
        )

        if artworkURL == lastArtworkURL, let existingArtwork = self.playbackState.artwork {
            state.artwork = existingArtwork
        }

        if canvasTrackKey == lastCanvasTrackKey {
            state.liveArtworkURL = self.playbackState.liveArtworkURL
        }

        playbackState = state
        scheduleCanvasFetchIfNeeded(
            for: state,
            trackIdentifiers: trackIdentifiers,
            canvasTrackKey: canvasTrackKey
        )

        if !artworkURL.isEmpty, let url = URL(string: artworkURL) {
            guard artworkURL != lastArtworkURL || state.artwork == nil else { return }
            artworkFetchTask?.cancel()

            let currentState = state

            artworkFetchTask = Task {
                do {
                    let data = try await ImageService.shared.fetchImageData(from: url)

                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        guard self.playbackState.title == currentState.title,
                              self.playbackState.artist == currentState.artist,
                              self.playbackState.album == currentState.album
                        else {
                            self.artworkFetchTask = nil
                            return
                        }

                        var updatedState = self.playbackState
                        updatedState.artwork = data
                        self.playbackState = updatedState
                        self.lastArtworkURL = artworkURL
                        self.artworkFetchTask = nil
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.artworkFetchTask = nil
                    }
                }
            }
        }
    }
    
// MARK: - Private Methods
    
    private func executeCommand(_ command: String) async {
        let script = "tell application \"Spotify\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }

    private func executeAndRefresh(_ command: String) async {
        await executeCommand(command)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }

    private func scheduleCanvasFetchIfNeeded(
        for state: PlaybackState,
        trackIdentifiers: [String],
        canvasTrackKey: String
    ) {
        guard state.liveArtworkURL == nil, !trackIdentifiers.isEmpty else { return }

        liveArtworkFetchTask?.cancel()

        let expectedTitle = state.title
        let expectedArtist = state.artist
        let expectedAlbum = state.album

        liveArtworkFetchTask = Task { [weak self] in
            guard let self else { return }

            var liveArtworkURL: URL?
            for attempt in 0..<6 {
                liveArtworkURL = await self.canvasResolver.resolveCanvasURL(trackIdentifiers: trackIdentifiers)
                if liveArtworkURL != nil || Task.isCancelled {
                    break
                }

                if attempt < 5 {
                    try? await Task.sleep(for: .seconds(1))
                }
            }

            guard !Task.isCancelled else { return }
            let resolvedLiveArtworkURL = liveArtworkURL

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                guard self.playbackState.title == expectedTitle,
                      self.playbackState.artist == expectedArtist,
                      self.playbackState.album == expectedAlbum
                else {
                    self.liveArtworkFetchTask = nil
                    return
                }

                var updatedState = self.playbackState
                updatedState.liveArtworkURL = resolvedLiveArtworkURL
                self.playbackState = updatedState
                self.lastCanvasTrackKey = canvasTrackKey
                self.liveArtworkFetchTask = nil
            }
        }
    }

    private func trackIdentifiers(trackID: String, spotifyURLString: String) -> [String] {
        var identifiers = Set<String>()

        let trimmedTrackID = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTrackID.isEmpty {
            identifiers.insert(trimmedTrackID)

            if trimmedTrackID.hasPrefix("spotify:track:") {
                let bareID = String(trimmedTrackID.dropFirst("spotify:track:".count))
                if !bareID.isEmpty {
                    identifiers.insert(bareID)
                }
            } else {
                identifiers.insert("spotify:track:\(trimmedTrackID)")
            }
        }

        if let extractedTrackID = extractTrackID(from: spotifyURLString) {
            identifiers.insert(extractedTrackID)
            identifiers.insert("spotify:track:\(extractedTrackID)")
        }

        return Array(identifiers)
    }

    private func extractTrackID(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let range = trimmed.range(of: "spotify:track:") {
            let suffix = trimmed[range.upperBound...]
            let trackID = suffix.split(separator: "?").first.map(String.init) ?? ""
            return trackID.isEmpty ? nil : trackID
        }

        if let url = URL(string: trimmed),
           let host = url.host?.lowercased(),
           host.contains("spotify.com") {
            let pathComponents = url.pathComponents.filter { $0 != "/" }
            if let trackIndex = pathComponents.firstIndex(of: "track"),
               pathComponents.indices.contains(trackIndex + 1) {
                let trackID = pathComponents[trackIndex + 1]
                return trackID.isEmpty ? nil : trackID
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9]{22}"#),
           let match = regex.firstMatch(
            in: trimmed,
            options: [],
            range: NSRange(trimmed.startIndex..., in: trimmed)
           ),
           let range = Range(match.range, in: trimmed) {
            return String(trimmed[range])
        }

        return nil
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set artworkURL to artwork url of current track
                set trackID to id of current track
                set trackSpotifyURL to spotify url of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, artworkURL, trackID, trackSpotifyURL}
            on error
                return {false, "Unknown", "Unknown", "Unknown", 0, 0, false, false, "", "", ""}
            end try
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }
}
