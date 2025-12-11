//
//  ConversionActionView.swift
//  boringNotch
//
//  Created by Alexander on 2025-12-08.
//

import SwiftUI
import Defaults

struct ConversionActionView: View {
    var isPopover: Bool = false
    @StateObject private var selection = ShelfSelectionModel.shared
    @StateObject private var vm = ShelfStateViewModel.shared
    @State private var isProcessing = false
    @State private var errorMessage: String?
    
    var body: some View {
        if !Defaults[.enableFileConversion] {
            EmptyView()
        } else {
            if isPopover {
                content
            } else {
                content
            }
        }
    }

    var content: some View {
        VStack(spacing: 12) {
            if let item = selection.firstSelectedItem,
               let url = item.fileURL {
                
                if ImageProcessingService.shared.isImageFile(url) {
                    imageActions(for: url, item: item)
                } else if VideoProcessingService.shared.isVideoFile(url) {
                    videoActions(for: url, item: item)
                } else {
                    Text("No actions available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Options Section
                if ImageProcessingService.shared.isImageFile(url) {
                    Divider()
                        .padding(.vertical, 4)
                    
                    HStack(spacing: 8) {
                        Text("Size:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Picker("", selection: $selectedSize) {
                            ForEach(ImageSize.allCases) { size in
                                Text(size.rawValue).tag(size)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 100)
                    }
                    .padding(.horizontal, 4)
                }
            } else {
                ContentUnavailableView {
                    Label("Select a file", systemImage: "cursorarrow.click")
                } description: {
                    Text("Select an image or video to convert")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
        .padding(.top, 8)
        .background {
            if !isPopover {
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            if isProcessing {
                ZStack {
                    Color.black.opacity(0.4)
                    ProgressView()
                        .controlSize(.large)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { _ in errorMessage = nil })) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
    }
    
    // MARK: - IMAGE ACTIONS
    
    @ViewBuilder
    private func imageActions(for url: URL, item: ShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert Image")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    let ext = url.pathExtension.lowercased()
                    
                    actionButton("To PNG", icon: "photo", isDisabled: ext == "png") {
                        await convertImage(url, format: .png)
                    }
                    
                    actionButton("To JPEG", icon: "photo", isDisabled: ext == "jpg" || ext == "jpeg") {
                        await convertImage(url, format: .jpeg)
                    }
                    
                    actionButton("To HEIC", icon: "photo", isDisabled: ext == "heic") {
                        await convertImage(url, format: .heic)
                    }
                    
                    actionButton("To PDF", icon: "doc.text") {
                        await convertToPDF(url)
                    }
                    
                    if #available(macOS 14.0, *) {
                        actionButton("Remove Background", icon: "person.crop.circle.badge.minus") {
                            await removeBackground(url)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - VIDEO ACTIONS
    
    @ViewBuilder
    private func videoActions(for url: URL, item: ShelfItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Convert Video")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 12) {
                        let ext = url.pathExtension.lowercased()
                        
                        // ROW 1
                        HStack(spacing: 12) {
                            actionButton("To MP4", icon: "film", isDisabled: ext == "mp4") {
                                await convertVideo(url, format: .mp4)
                            }
                            
                            actionButton("To MOV", icon: "film", isDisabled: ext == "mov") {
                                await convertVideo(url, format: .mov)
                            }
                        }
                        
                        // ROW 2
                        HStack(spacing: 12) {
                            actionButton("Extract Audio (MP3)", icon: "music.note") {
                                await extractAudio(url, format: .mp3)
                            }
                            
                            actionButton("Extract Audio (M4A)", icon: "music.note") {
                                await extractAudio(url, format: .m4a)
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - BUTTON
    
    private func actionButton(_ title: String, icon: String, isDisabled: Bool = false, action: @escaping () async -> Void) -> some View {
        Button {
            Task {
                isProcessing = true
                await action()
                isProcessing = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                    .lineLimit(1)
            }
            .frame(minWidth: 140)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(isDisabled ? 0.05 : 0.1))
            .cornerRadius(8)
            .opacity(isDisabled ? 0.4 : 1.0)
        }
        .disabled(isDisabled)
        .buttonStyle(.plain)
    }
    
    // MARK: - ACTIONS (unchanged)
    
    // MARK: - OPTIONS
    
    enum ImageSize: String, CaseIterable, Identifiable {
        case `default` = "Default"
        case large = "Large"
        case medium = "Medium"
        case small = "Small"
        
        var id: String { rawValue }
        
        var maxDimension: CGFloat? {
            switch self {
            case .default: return nil
            case .large: return 2048
            case .medium: return 1024
            case .small: return 512
            }
        }
    }
    
    @State private var selectedSize: ImageSize = .default
    
    // MARK: - ACTIONS (unchanged)
    
    private func convertImage(_ url: URL, format: ImageConversionOptions.ImageFormat) async {
        do {
            let options = ImageConversionOptions(
                format: format,
                compressionQuality: 0.8,
                maxDimension: selectedSize.maxDimension,
                removeMetadata: !Defaults[.keepImageMetadata]
            )
            if let newURL = try await ImageProcessingService.shared.convertImage(from: url, options: options) {
                await saveFile(at: newURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func convertToPDF(_ url: URL) async {
        do {
            if let newURL = try await ImageProcessingService.shared.createPDF(from: [url]) {
                await saveFile(at: newURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func removeBackground(_ url: URL) async {
        if #available(macOS 14.0, *) {
            do {
                if let newURL = try await ImageProcessingService.shared.removeBackground(from: url) {
                    await saveFile(at: newURL)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            errorMessage = "Background removal requires macOS 14.0 or later."
        }
    }
    
    private func convertVideo(_ url: URL, format: VideoConversionOptions.VideoFormat) async {
        do {
            let options = VideoConversionOptions(format: format)
            if let newURL = try await VideoProcessingService.shared.convertVideo(from: url, options: options) {
                await saveFile(at: newURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func extractAudio(_ url: URL, format: VideoConversionOptions.AudioFormat) async {
        do {
            let options = VideoConversionOptions(audioFormat: format)
            if let newURL = try await VideoProcessingService.shared.convertVideo(from: url, options: options) {
                await saveFile(at: newURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    // MARK: - SAVE
    
    @MainActor
    private func saveFile(at tempURL: URL) async {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = tempURL.lastPathComponent
        savePanel.canCreateDirectories = true
        
        let response = await savePanel.begin()
        
        if response == .OK, let targetURL = savePanel.url {
            do {
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: targetURL)
                addToShelf(targetURL)
            } catch {
                errorMessage = "Failed to save file: \(error.localizedDescription)"
            }
        } else {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
    
    private func addToShelf(_ url: URL) {
        Task { @MainActor in
            do {
                let bookmark = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                let item = ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
                vm.add([item])
            } catch {
                errorMessage = "Failed to create bookmark: \(error.localizedDescription)"
            }
        }
    }
}
