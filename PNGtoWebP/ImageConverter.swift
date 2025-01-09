//
//  ImageConverter.swift
//  PNGtoWebP
//
//  Created by Kish on 08/01/2025.
//

import Foundation
import Metal
import MetalKit
import ImageIO
import libwebp

class ImageConverter {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ConversionError.metalDeviceNotFound
        }
        self.device = device
        
        guard let commandQueue = device.makeCommandQueue() else {
            throw ConversionError.commandQueueCreationFailed
        }
        self.commandQueue = commandQueue
        
        // Load and compile the Metal shader
        guard let library = try? device.makeDefaultLibrary() else {
            throw ConversionError.kernelNotFound
        }
        guard let kernelFunction = library.makeFunction(name: "convertImage") else {
            throw ConversionError.kernelNotFound
        }

        self.pipelineState = try device.makeComputePipelineState(function: kernelFunction)
    }
    
    enum ConversionError: Error {
        case metalDeviceNotFound
        case commandQueueCreationFailed
        case kernelNotFound
        case textureCreationFailed
        case cgImageCreationFailed
        case webpEncodingFailed
        case fileAccessDenied
        case directoryAccessDenied
    }
    
    func convertToWebP(url: URL, quality: Float, progressHandler: @escaping (Double) -> Void) async throws -> URL {
        print("Starting conversion for: \(url.lastPathComponent)")
        
        // Resolve the security-scoped bookmark
        guard let bookmark = UserDefaults.standard.data(forKey: url.lastPathComponent),
              let dirBookmark = UserDefaults.standard.data(forKey: url.lastPathComponent + "_dir") else {
            print("No bookmark found for: \(url.lastPathComponent)")
            throw ConversionError.fileAccessDenied
        }
        
        var isStale = false
        guard let resolvedURL = try? URL(resolvingBookmarkData: bookmark,
                                       options: .withSecurityScope,
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &isStale),
              let resolvedDirURL = try? URL(resolvingBookmarkData: dirBookmark,
                                          options: .withSecurityScope,
                                          relativeTo: nil,
                                          bookmarkDataIsStale: &isStale) else {
            print("Failed to resolve bookmarks")
            throw ConversionError.fileAccessDenied
        }
        
        // Start accessing the security-scoped resources
        guard resolvedURL.startAccessingSecurityScopedResource(),
              resolvedDirURL.startAccessingSecurityScopedResource() else {
            print("Failed to access security-scoped resources")
            throw ConversionError.fileAccessDenied
        }
        defer {
            resolvedURL.stopAccessingSecurityScopedResource()
            resolvedDirURL.stopAccessingSecurityScopedResource()
        }
        
        // Load image from URL
        guard let imageSource = CGImageSourceCreateWithURL(resolvedURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("Failed to create CGImage")
            throw ConversionError.cgImageCreationFailed
        }
        print("Loaded CGImage successfully")
        
        // Create Metal texture from image
        let textureLoader = MTKTextureLoader(device: device)
        print("Creating input texture...")
        let inputTexture = try await textureLoader.newTexture(
            cgImage: cgImage,
            options: [
                MTKTextureLoader.Option.textureUsage: MTLTextureUsage.shaderRead.rawValue,
                MTKTextureLoader.Option.SRGB: false
            ]
        )
        print("Input texture created: \(inputTexture.width)x\(inputTexture.height)")
        
        // Create output texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: inputTexture.width,
            height: inputTexture.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderWrite, .shaderRead]
        
        guard let outputTexture = device.makeTexture(descriptor: textureDescriptor) else {
            print("Failed to create output texture")
            throw ConversionError.textureCreationFailed
        }
        print("Output texture created")
        
        // Process the image using Metal
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            print("Failed to create command buffer or encoder")
            throw ConversionError.commandQueueCreationFailed
        }
        
        print("Starting Metal processing...")
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSizeMake(16, 16, 1)
        let threadGroups = MTLSizeMake(
            (inputTexture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            (inputTexture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            1
        )
        
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        print("Metal processing completed")
        
        progressHandler(0.3)
        
        // Create destination URL for WebP file
        let outputURL = resolvedURL.deletingPathExtension().appendingPathExtension("webp")
        print("Will save to: \(outputURL.path)")
        
        // Read back the texture
        let region = MTLRegionMake2D(0, 0, inputTexture.width, inputTexture.height)
        let bytesPerRow = inputTexture.width * 4
        var imageData = [UInt8](repeating: 0, count: inputTexture.height * bytesPerRow)
        
        outputTexture.getBytes(&imageData,
                              bytesPerRow: bytesPerRow,
                              from: region,
                              mipmapLevel: 0)
        
        progressHandler(0.5)
        
        // Convert to WebP and save
        do {
            print("Encoding to WebP with quality: \(quality)")
            var output: UnsafeMutablePointer<UInt8>?
            var outputSize: Int = 0
            
            var config = WebPConfig()
            WebPConfigInit(&config)
            
            if quality >= 100 {
                // Use lossless for 100% quality
                print("Using lossless encoding")
                config.lossless = 1
                config.exact = 1
            } else {
                // Use lossy compression with specified quality
                print("Using lossy encoding")
                config.lossless = 0
                config.quality = quality
            }
            
            config.use_sharp_yuv = 1  // Better RGB->YUV conversion
            config.image_hint = WEBP_HINT_GRAPH  // Optimize for synthetic images
            
            // Encode directly using WebP encoder based on quality setting
            if config.lossless == 1 {
                outputSize = Int(WebPEncodeLosslessRGBA(imageData,
                                                      Int32(inputTexture.width),
                                                      Int32(inputTexture.height),
                                                      Int32(bytesPerRow),
                                                      &output))
            } else {
                outputSize = Int(WebPEncodeRGBA(imageData,
                                              Int32(inputTexture.width),
                                              Int32(inputTexture.height),
                                              Int32(bytesPerRow),
                                              quality,
                                              &output))
            }
            
            guard outputSize > 0, let outputData = output else {
                print("WebP encoding failed")
                throw ConversionError.webpEncodingFailed
            }
            
            progressHandler(0.9)
            
            // Convert to Data and write to file
            let encodedData = Data(bytes: outputData, count: outputSize)
            print("WebP encoded size: \(encodedData.count) bytes")
            
            // Check if file exists and remove it
            if FileManager.default.fileExists(atPath: outputURL.path) {
                print("WebP file already exists, removing: \(outputURL.path)")
                try FileManager.default.removeItem(at: outputURL)
            }
            
            // Write to file
            try encodedData.write(to: outputURL)
            
            // Clean up
            WebPFree(output)
        }
        
        print("Conversion completed successfully")
        progressHandler(1.0)
        return outputURL
    }
}
