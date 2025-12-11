//
//  ImageProcessingService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-16.
//

import Foundation
import AppKit
import CoreImage
import CoreGraphics
import Vision
import PDFKit
import UniformTypeIdentifiers
import ImageIO

/// Options for image conversion
struct ImageConversionOptions {
    enum ImageFormat {
        case png, jpeg, heic, tiff, bmp
        
        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .tiff: return .tiff
            case .bmp: return .bmp
            }
        }
        
        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .heic: return "heic"
            case .tiff: return "tiff"
            case .bmp: return "bmp"
            }
        }
    }
    
    let format: ImageFormat
    let compressionQuality: Double // 0.0 to 1.0, only applies to JPEG/HEIC
    let maxDimension: CGFloat? // Max width or height, nil for no scaling
    let removeMetadata: Bool
}

/// Service for processing images (background removal, conversion, PDF creation)
@MainActor
final class ImageProcessingService {
    static let shared = ImageProcessingService()
    
    private init() {}
    private let ciContext = CIContext(options: nil)
    
    // MARK: - Remove Background
    
    /// Removes the background from an image using Vision framework
    @available(macOS 14.0, *)
    func removeBackground(from url: URL) async throws -> URL? {
        await ConversionManager.shared.startConversion()
        defer {
            Task { @MainActor in
                ConversionManager.shared.finishConversion()
            }
        }
        
        guard let inputImage = NSImage(contentsOf: url) else {
            throw ImageProcessingError.invalidImage
        }
        
        guard let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageProcessingError.invalidImage
        }
        
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        
        try handler.perform([request])
        
        guard let result = request.results?.first else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        
        let output = try await applyMask(mask, to: cgImage)
        
        let processedImage = NSImage(cgImage: output, size: inputImage.size)
        
        // Create temporary file
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_no_bg.png"
        
        guard let pngData = processedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: pngData),
              let finalData = bitmap.representation(using: .png, properties: [:]) else {
            throw ImageProcessingError.saveFailed
        }
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(finalData, suggestedName: newName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    private func applyMask(_ mask: CVPixelBuffer, to image: CGImage) async throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let maskImage = CIImage(cvPixelBuffer: mask)
        
        let filter = CIFilter.blendWithMask()
        filter.inputImage = ciImage
        filter.maskImage = maskImage
        filter.backgroundImage = CIImage.empty()
        
        guard let output = filter.outputImage else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        let context = CIContext()
        guard let result = context.createCGImage(output, from: output.extent) else {
            throw ImageProcessingError.backgroundRemovalFailed
        }
        
        return result
    }
    
    // MARK: - Convert Image
    
    /// Converts an image with specified options using ImageIO for performance
    func convertImage(from url: URL, options: ImageConversionOptions) async throws -> URL? {
        await ConversionManager.shared.startConversion()
        defer {
            Task { @MainActor in
                ConversionManager.shared.finishConversion()
            }
        }
        
        // Create temporary file
        let originalName = url.deletingPathExtension().lastPathComponent
        let newName = "\(originalName)_converted.\(options.format.fileExtension)"
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(options.format.fileExtension)
        
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageProcessingError.invalidImage
        }
        
        guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, options.format.utType.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.conversionFailed
        }
        
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: options.compressionQuality
        ]
        
        // If we need to scale, we use a thumbnail approach with CGImageSource
        if let maxDim = options.maxDimension {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                throw ImageProcessingError.conversionFailed
            }
            
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        } else {
            // Direct copy/transcode
            if options.removeMetadata {
                // To remove metadata, we must decode to a clean CGImage and re-encode
                // This strips all source metadata that would otherwise be copied
                if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
                } else {
                     // Fallback if decoding fails (unlikely)
                     CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
                }
            } else {
                // Preserve metadata by copying from source
                CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
            }
        }
        
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.conversionFailed
        }
        
        // Move to managed storage
        if let data = try? Data(contentsOf: tempURL) {
            try? FileManager.default.removeItem(at: tempURL)
            
            guard let finalTempURL = await TemporaryFileStorageService.shared.createTempFile(
                for: .data(data, suggestedName: newName)
            ) else {
                throw ImageProcessingError.saveFailed
            }
            return finalTempURL
        } else {
            throw ImageProcessingError.saveFailed
        }
    }
    
    private func scaleImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        guard maxDimension > 0 else { return image }

        guard let srcCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }

        let srcMax = max(srcCG.width, srcCG.height)
        if CGFloat(srcMax) <= maxDimension {
            return image // no downscaling needed
        }

        let scale = maxDimension / CGFloat(srcMax)

        let ciImage = CIImage(cgImage: srcCG)
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = ciImage
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1.0

        guard let output = lanczos.outputImage else {
            return image
        }

        // Preserve the source color space for exact color matching
        let colorSpace = srcCG.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ciContext = CIContext(options: [.workingColorSpace: colorSpace])

        // Render using the CIContext with matching color space
        guard let dstCG = ciContext.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace) else {
            return image
        }

        return NSImage(cgImage: dstCG, size: NSSize(width: dstCG.width, height: dstCG.height))
    }
    
    // MARK: - Create PDF
    
    /// Creates a PDF from multiple image URLs
    func createPDF(from imageURLs: [URL], outputName: String? = nil) async throws -> URL? {
        await ConversionManager.shared.startConversion()
        defer {
            Task { @MainActor in
                ConversionManager.shared.finishConversion()
            }
        }
        
        guard !imageURLs.isEmpty else {
            throw ImageProcessingError.noImagesProvided
        }
        
        let pdfDocument = PDFDocument()
        
        for (index, url) in imageURLs.enumerated() {
            guard let image = NSImage(contentsOf: url) else {
                continue
            }
            
            let pdfPage = PDFPage(image: image)
            if let page = pdfPage {
                pdfDocument.insert(page, at: index)
            }
        }
        
        guard pdfDocument.pageCount > 0 else {
            throw ImageProcessingError.pdfCreationFailed
        }
        
        // Create temporary file
        let name = outputName ?? "images_\(Date().timeIntervalSince1970).pdf"
        let pdfName = name.hasSuffix(".pdf") ? name : "\(name).pdf"
        
        guard let pdfData = pdfDocument.dataRepresentation() else {
            throw ImageProcessingError.pdfCreationFailed
        }
        
        guard let tempURL = await TemporaryFileStorageService.shared.createTempFile(
            for: .data(pdfData, suggestedName: pdfName)
        ) else {
            throw ImageProcessingError.saveFailed
        }
        
        return tempURL
    }
    
    // MARK: - Helper Methods
    
    /// Checks if a URL is an image file
    func isImageFile(_ url: URL) -> Bool {
        guard let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return contentType.conforms(to: .image)
    }
}

// MARK: - Errors

enum ImageProcessingError: LocalizedError {
    case invalidImage
    case backgroundRemovalFailed
    case conversionFailed
    case pdfCreationFailed
    case noImagesProvided
    case saveFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The file is not a valid image"
        case .backgroundRemovalFailed:
            return "Failed to remove background from image"
        case .conversionFailed:
            return "Failed to convert image format"
        case .pdfCreationFailed:
            return "Failed to create PDF from images"
        case .noImagesProvided:
            return "No images were provided"
        case .saveFailed:
            return "Failed to save processed file"
        }
    }
}
