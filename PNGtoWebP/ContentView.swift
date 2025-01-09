//
//  ContentView.swift
//  PNGtoWebP
//
//  Created by Kish on 08/01/2025.
//

import SwiftUI
import UniformTypeIdentifiers
import Metal
import MetalKit

// Model to represent an image file and its conversion state
struct ImageFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let originalSize: Int64
    var convertedSize: Int64?
    var conversionProgress: Double = 0
    var status: ConversionStatus = .pending
    
    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
        self.originalSize = Int64(resources?.fileSize ?? 0)
    }
}

enum ConversionStatus {
    case pending
    case converting
    case completed
    case failed(Error)
}

// View Model

class ConverterViewModel: ObservableObject {
    @Published var imageFiles: [ImageFile] = []
    @Published var compressionQuality: Double = 100.0
    @Published var isConverting = false
    
    private var imageConverter: ImageConverter?
    
    init() {
        do {
            imageConverter = try ImageConverter()
        } catch {
            print("Failed to initialize Metal converter: \(error)")
        }
    }
    
    func addFiles(_ urls: [URL]) {
        let newFiles = urls.filter { url in
            url.pathExtension.lowercased() == "png"
        }.map { url in
            // If file already exists in list, remove it
            if let existingIndex = imageFiles.firstIndex(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
                print("Removing existing file from list: \(url.lastPathComponent)")
                imageFiles.remove(at: existingIndex)
            }
            return ImageFile(url: url)
        }
        
        print("Adding new files: \(newFiles.map { $0.name })")
        imageFiles.append(contentsOf: newFiles)
        
        // Start conversion if new files were added
        if !newFiles.isEmpty {
            startConversion()
        }
    }
    
    func startConversion() {
        print("Starting conversion process...")
        guard !imageFiles.isEmpty else { return }
        isConverting = true
        
        Task {
            for index in imageFiles.indices {
                print("Converting file \(index + 1) of \(imageFiles.count)")
                await convertImage(at: index)
            }
            
            await MainActor.run {
                isConverting = false
            }
        }
    }
    
    @MainActor
    private func updateProgress(for index: Int, progress: Double) {
        imageFiles[index].conversionProgress = progress
    }
    
    @MainActor
    private func updateStatus(for index: Int, status: ConversionStatus) {
        imageFiles[index].status = status
    }
    
    private func convertImage(at index: Int) async {
        await updateStatus(for: index, status: .converting)
        
        guard let converter = imageConverter else {
            await updateStatus(for: index, status: .failed(ImageConverter.ConversionError.metalDeviceNotFound))
            return
        }
        
        do {
            let outputURL = try await converter.convertToWebP(
                url: imageFiles[index].url,
                quality: Float(compressionQuality),
                progressHandler: { progress in
                    Task { @MainActor in
                        self.imageFiles[index].conversionProgress = progress
                    }
                }
            )
            
            // Get the size of the converted file
            let resources = try outputURL.resourceValues(forKeys: [.fileSizeKey])
            await MainActor.run {
                imageFiles[index].convertedSize = Int64(resources.fileSize ?? 0)
                imageFiles[index].status = .completed
            }
        } catch {
            await updateStatus(for: index, status: .failed(error))
        }
    }
}

// Main View
struct ContentView: View {
    
    @StateObject private var viewModel = ConverterViewModel()
    private let supportedTypes: [UTType] = [.png]
    
    var body: some View {
        VStack(spacing: 20) {
            // Drop zone visualization (now just visual)
            VStack {
                Image(systemName: "arrow.down.doc")
                    .font(.largeTitle)
                Text("Drop PNG files here or")
                Button("Browse Files") {
                    showFilePicker()
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
                    .foregroundColor(.gray)
            )
            
            // File list
            if !viewModel.imageFiles.isEmpty {
                List {
                    ForEach(viewModel.imageFiles) { file in
                        HStack {
                            Text(file.name)
                            Spacer()
                            
                            // Original size
                            Text(ByteCountFormatter.string(fromByteCount: file.originalSize, countStyle: .file))
                            
                            // Arrow and converted size (if available)
                            if let convertedSize = file.convertedSize {
                                Text("→")
                                Text(ByteCountFormatter.string(fromByteCount: convertedSize, countStyle: .file))
                                    .foregroundColor(.green)
                            }
                            
                            // Status indicator
                            switch file.status {
                            case .pending:
                                Image(systemName: "circle")
                                    .foregroundColor(.gray)
                            case .converting:
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.8)
                                Text("\(Int(file.conversionProgress * 100))%")
                                    .font(.caption)
                            case .completed:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            case .failed:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
            
            // Quality slider
            VStack {
                Text("Compression Quality: \(Int(viewModel.compressionQuality))%")
                Slider(
                    value: Binding(
                        get: { viewModel.compressionQuality },
                        set: { newValue in
                            let snappedValue = round(newValue / 5) * 5
                            viewModel.compressionQuality = snappedValue
                        }
                    ),
                    in: 0...100,
                    step: 5
                )
            }
            
            // Convert button
            Button(action: {
                viewModel.startConversion()
            }) {
                HStack {
                    if viewModel.isConverting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        Text("Converting...")
                    } else {
                        Text("Convert to WebP")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .disabled(viewModel.imageFiles.isEmpty || viewModel.isConverting)
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 500)
        .dropDestination(
            for: URL.self,
            action: { urls, _ in
                let pngUrls = urls.filter { url in
                    url.pathExtension.lowercased() == "png"
                }
                print("Received URLs: \(urls)")
                print("Filtered PNG URLs: \(pngUrls)")
                viewModel.addFiles(pngUrls)
                return true
            },
            isTargeted: { isTargeted in
                // You could add some visual feedback when files are being dragged over the window
                
            }
        )
    }
    
    private func showFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [UTType.png]
        panel.prompt = "Select PNG Files"
        panel.message = "Choose PNG files to convert to WebP"
        
        // Request both read and write access
        panel.isAccessoryViewDisclosed = true
        panel.treatsFilePackagesAsDirectories = false
        
        panel.begin { response in
            if response == .OK {
                
                // These URLs are already security-scoped
                let urls = panel.urls
                viewModel.addFiles(urls)
            }
        }
    }
}
