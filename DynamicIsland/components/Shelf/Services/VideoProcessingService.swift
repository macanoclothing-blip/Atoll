//
//  VideoProcessingService.swift
//  boringNotch
//
//  Created by Alexander on 2025-12-08.
//  Updated by ChatGPT for Davide on 2025-12-10 (fix pointer issues).
//

import Foundation
import AVFoundation
import AudioToolbox

/// Options for video conversion
struct VideoConversionOptions {
    enum VideoFormat {
        case mp4, mov

        var fileType: AVFileType {
            switch self {
            case .mp4: return .mp4
            case .mov: return .mov
            }
        }

        var fileExtension: String {
            switch self {
            case .mp4: return "mp4"
            case .mov: return "mov"
            }
        }
    }

    enum AudioFormat {
        case mp3, m4a

        var fileTypeForExportSession: AVFileType? {
            switch self {
            case .mp3: return nil // AVAssetExportSession does NOT support mp3 directly
            case .m4a: return .m4a
            }
        }

        var fileExtension: String {
            switch self {
            case .mp3: return "mp3"
            case .m4a: return "m4a"
            }
        }

        var presetName: String {
            switch self {
            case .mp3: return AVAssetExportPresetAppleM4A // fallback if needed
            case .m4a: return AVAssetExportPresetAppleM4A
            }
        }
    }

    let format: VideoFormat?
    let audioFormat: AudioFormat?
    let presetName: String

    init(format: VideoFormat, presetName: String = AVAssetExportPresetHighestQuality) {
        self.format = format
        self.audioFormat = nil
        self.presetName = presetName
    }

    init(audioFormat: AudioFormat) {
        self.format = nil
        self.audioFormat = audioFormat
        self.presetName = audioFormat.presetName
    }
}

/// Service for processing videos (conversion, audio extraction)
@MainActor
final class VideoProcessingService {
    static let shared = VideoProcessingService()
    private init() {}

    // MARK: - Public

    func convertVideo(from url: URL, options: VideoConversionOptions) async throws -> URL? {
        await ConversionManager.shared.startConversion()
        defer {
            Task { @MainActor in
                ConversionManager.shared.finishConversion()
            }
        }
        
        let asset = AVAsset(url: url)

        // Try smart passthrough for video first
        if options.format != nil {
            if let out = try await trySmartVideoExport(asset: asset, sourceURL: url, options: options) {
                return out
            }
        }

        // Audio extraction
        if let audioFormat = options.audioFormat {
            switch audioFormat {
            case .m4a:
                return try await export(asset: asset, url: url, options: options, preset: options.presetName)
            case .mp3:
                return try await exportToMP3(asset: asset, sourceURL: url)
            }
        }

        // Fallback for video export
        if options.format != nil {
            return try await export(asset: asset, url: url, options: options, preset: options.presetName)
        }

        return nil
    }

    // MARK: - Smart video export (Reader/Writer passthrough)

    private func trySmartVideoExport(asset: AVAsset, sourceURL: URL, options: VideoConversionOptions) async throws -> URL? {
        guard let format = options.format else { return nil }

        guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
        let outURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.fileExtension)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: format.fileType)

        // Video passthrough (copy)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil) // nil => passthrough
        if reader.canAdd(videoOutput) { reader.add(videoOutput) }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil) // passthrough
        videoInput.expectsMediaDataInRealTime = false
        // Keep transform
        if let transform = try? await videoTrack.load(.preferredTransform) {
            videoInput.transform = transform
        }
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        // Audio passthrough (if exists)
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let aOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(aOutput) {
                reader.add(aOutput)
                audioOutput = aOutput
            }

            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            if writer.canAdd(aInput) {
                writer.add(aInput)
                audioInput = aInput
            }
        }

        guard reader.startReading() else { throw VideoProcessingError.unknown }
        guard writer.startWriting() else { throw VideoProcessingError.unknown }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()

        // Video loop
        group.enter()
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoQueue")) {
            while videoInput.isReadyForMoreMediaData {
                if let sb = videoOutput.copyNextSampleBuffer() {
                    if !videoInput.append(sb) {
                        // append failed - let it go and break
                    }
                } else {
                    videoInput.markAsFinished()
                    group.leave()
                    break
                }
            }
        }

        // Audio loop
        if let aInput = audioInput, let aOutput = audioOutput {
            group.enter()
            aInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audioQueue")) {
                while aInput.isReadyForMoreMediaData {
                    if let sb = aOutput.copyNextSampleBuffer() {
                        if !aInput.append(sb) {
                            // append failed
                        }
                    } else {
                        aInput.markAsFinished()
                        group.leave()
                        break
                    }
                }
            }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                group.wait()
                writer.finishWriting {
                    if writer.status == .completed {
                        if let data = try? Data(contentsOf: outURL) {
                            try? FileManager.default.removeItem(at: outURL)
                            Task {
                                let suggested = sourceURL.deletingPathExtension().lastPathComponent + "_converted.\(format.fileExtension)"
                                let final = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: suggested))
                                continuation.resume(returning: final)
                            }
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } else {
                        try? FileManager.default.removeItem(at: outURL)
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    // MARK: - Export with AVAssetExportSession (fallback)

    private func export(asset: AVAsset, url: URL, options: VideoConversionOptions, preset: String) async throws -> URL? {
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw VideoProcessingError.sessionCreationFailed
        }

        let originalName = url.deletingPathExtension().lastPathComponent
        let newExtension = options.format?.fileExtension ?? options.audioFormat?.fileExtension ?? "mov"
        let newName = "\(originalName)_converted.\(newExtension)"

        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(newExtension)

        exportSession.outputURL = outputURL
        exportSession.shouldOptimizeForNetworkUse = true

        if let fileType = options.format?.fileType {
            exportSession.outputFileType = fileType
        } else if let audioFileType = options.audioFormat?.fileTypeForExportSession {
            exportSession.outputFileType = audioFileType
        } else {
            exportSession.outputFileType = .mov
        }

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            if let data = try? Data(contentsOf: outputURL) {
                try? FileManager.default.removeItem(at: outputURL)
                guard let finalTempURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: newName)) else {
                    throw VideoProcessingError.saveFailed
                }
                return finalTempURL
            } else {
                throw VideoProcessingError.saveFailed
            }
        case .failed:
            throw VideoProcessingError.conversionFailed(exportSession.error)
        case .cancelled:
            throw VideoProcessingError.cancelled
        default:
            throw VideoProcessingError.unknown
        }
    }

    // MARK: - Export to MP3 (via M4A intermediate conversion)
    
    /// Exports audio to MP3 by first converting to M4A, then using ffmpeg to convert to MP3
    private func exportToMP3(asset: AVAsset, sourceURL: URL) async throws -> URL? {
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_extracted.mp3"
        
        // Step 1: Convert to M4A first (this works reliably)
        let m4aOptions = VideoConversionOptions(audioFormat: .m4a)
        guard let m4aURL = try await export(asset: asset, url: sourceURL, options: m4aOptions, preset: AVAssetExportPresetAppleM4A) else {
            throw VideoProcessingError.conversionFailed(NSError(domain: "VideoProcessing", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create M4A intermediate file"]))
        }
        
        defer {
            // Clean up M4A file after conversion
            try? FileManager.default.removeItem(at: m4aURL)
        }
        
        // Step 2: Convert M4A to MP3 using ffmpeg (if available) or fallback to error
        let tempDir = FileManager.default.temporaryDirectory
        let mp3URL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
        
        // Try to find ffmpeg in common locations
        let ffmpegPaths = [
            "/usr/local/bin/ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/opt/local/bin/ffmpeg"
        ]
        
        var ffmpegPath: String?
        for path in ffmpegPaths {
            if FileManager.default.fileExists(atPath: path) {
                ffmpegPath = path
                break
            }
        }
        
        // Also try to find ffmpeg in PATH
        if ffmpegPath == nil {
            let whichProcess = Process()
            whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            whichProcess.arguments = ["ffmpeg"]
            let pipe = Pipe()
            whichProcess.standardOutput = pipe
            do {
                try whichProcess.run()
                whichProcess.waitUntilExit()
                if whichProcess.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !path.isEmpty {
                        ffmpegPath = path
                    }
                }
            } catch {
                // Ignore
            }
        }
        
        guard let ffmpeg = ffmpegPath else {
            throw VideoProcessingError.formatNotSupported("MP3 conversion requires ffmpeg. Please install it using: brew install ffmpeg")
        }
        
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = [
                    "-i", m4aURL.path,
                    "-acodec", "libmp3lame",
                    "-ab", "192k",
                    "-y", // Overwrite output file
                    mp3URL.path
                ]
                
                // Capture stderr for better error messages
                let errorPipe = Pipe()
                process.standardError = errorPipe
                
                do {
                    try process.run()
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: mp3URL.path) {
                        // Success - read the MP3 file and create temp file
                        if let mp3Data = try? Data(contentsOf: mp3URL) {
                            try? FileManager.default.removeItem(at: mp3URL)
                            Task {
                                let final = await TemporaryFileStorageService.shared.createTempFile(for: .data(mp3Data, suggestedName: newName))
                                continuation.resume(returning: final)
                            }
                        } else {
                            try? FileManager.default.removeItem(at: mp3URL)
                            continuation.resume(throwing: VideoProcessingError.saveFailed)
                        }
                    } else {
                        // Read error output
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        let errorMessage = "ffmpeg failed with exit code \(process.terminationStatus): \(errorOutput)"
                        continuation.resume(throwing: VideoProcessingError.conversionFailed(NSError(domain: "VideoProcessing", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorMessage])))
                    }
                } catch {
                    continuation.resume(throwing: VideoProcessingError.conversionFailed(error))
                }
            }
        }
    }

    // Helper: create PCM buffer from CMSampleBuffer
    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let inputFormat = AVAudioFormat(streamDescription: asbdPointer) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let _ = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var audioBufferList = pcmBuffer.mutableAudioBufferList
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: audioBufferList)

        return pcmBuffer
    }

    // MARK: - Helpers

    func isVideoFile(_ url: URL) -> Bool {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return contentType.conforms(to: .movie)
    }
}

// MARK: - Errors

enum VideoProcessingError: LocalizedError {
    case sessionCreationFailed
    case conversionFailed(Error?)
    case cancelled
    case saveFailed
    case formatNotSupported(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .sessionCreationFailed:
            return "Failed to create export session"
        case .conversionFailed(let error):
            return "Conversion failed: \(error?.localizedDescription ?? "Unknown error")"
        case .cancelled:
            return "Conversion cancelled"
        case .saveFailed:
            return "Failed to save processed file"
        case .formatNotSupported(let message):
            return message
        case .unknown:
            return "An unknown error occurred"
        }
    }
}
