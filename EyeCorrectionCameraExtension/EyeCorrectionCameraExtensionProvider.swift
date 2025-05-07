//
//  EyeCorrectionCameraExtensionProvider.swift
//  EyeCorrectionCameraExtension
//
//  Created by Oleksandr Tsepukh on 04/05/2025.
//

import Foundation
import CoreMediaIO
import IOKit.audio
import os.log
import AVFoundation // Add AVFoundation import
import Vision // Add Vision framework import
import CoreImage // Import CoreImage for vector types and potential filters
import CoreImage.CIFilterBuiltins // Import built-in filters

let kWhiteStripeHeight: Int = 10
let kFrameRate: Int = 60

// MARK: -

// Make the class conform to AVCaptureVideoDataOutputSampleBufferDelegate
class EyeCorrectionCameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource, AVCaptureVideoDataOutputSampleBufferDelegate {
	
	private(set) var device: CMIOExtensionDevice!
	
	private var _streamSource: EyeCorrectionCameraExtensionStreamSource!
	
	private var _streamingCounter: UInt32 = 0
	
	// Remove the timer and related queue as we'll use the capture delegate
	// private var _timer: DispatchSourceTimer?
	// private let _timerQueue = DispatchQueue(label: "timerQueue", qos: .userInteractive, attributes: [], autoreleaseFrequency: .workItem, target: .global(qos: .userInteractive))
	
	private var _videoDescription: CMFormatDescription!
	
	private var _bufferPool: CVPixelBufferPool!
	
	private var _bufferAuxAttributes: NSDictionary!

	// AVFoundation properties
	private var captureSession: AVCaptureSession?
	private var videoDeviceInput: AVCaptureDeviceInput?
	private let videoDataOutput = AVCaptureVideoDataOutput()
	private let captureQueue = DispatchQueue(label: "captureQueue", qos: .userInitiated)
	
	// Core Image context (create lazily or once)
	private let ciContext = CIContext(options: nil)
	
	// Removed white stripe properties
	
	init(localizedName: String) {
		
		super.init()
		let deviceID = UUID() // Keep using UUID for uniqueness
		self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)
		
		// Use a common format, assuming the physical camera can provide it or conversion is handled.
		// Let's stick to 1920x1080 for now, but this might need adjustment based on camera capabilities.
		let dims = CMVideoDimensions(width: 1920, height: 1080)
		CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: dims.width, height: dims.height, extensions: nil, formatDescriptionOut: &_videoDescription)
		
		let pixelBufferAttributes: NSDictionary = [
			kCVPixelBufferWidthKey: dims.width,
			kCVPixelBufferHeightKey: dims.height,
			kCVPixelBufferPixelFormatTypeKey: _videoDescription.mediaSubType,
			kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary
		]
		CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes, &_bufferPool)
		
		let videoStreamFormat = CMIOExtensionStreamFormat.init(formatDescription: _videoDescription, maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)), validFrameDurations: nil)
		_bufferAuxAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 5]
		
		let videoID = UUID() // Keep using UUID for uniqueness
		_streamSource = EyeCorrectionCameraExtensionStreamSource(localizedName: "EyeCorrectionCamera.Video", streamID: videoID, streamFormat: videoStreamFormat, device: self.device) // Pass self.device
		do {
			try self.device.addStream(_streamSource.stream)
		} catch let error {
			fatalError("Failed to add stream: \(error.localizedDescription)")
		}

		// Setup AVFoundation capture session
		setupCaptureSession()
	}

	private func setupCaptureSession() {
		captureSession = AVCaptureSession()
		captureSession?.sessionPreset = .high // Or choose a specific resolution

		// Find a default video device
		guard let videoDevice = AVCaptureDevice.default(for: .video) else {
			os_log(.error, "Failed to find default video device.")
			// Handle error appropriately - maybe fall back to placeholder?
			return
		}

		do {
			videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
		} catch {
			os_log(.error, "Failed to create video device input: \(error.localizedDescription)")
			return
		}

		// Add input
		if let input = videoDeviceInput, captureSession?.canAddInput(input) == true {
			captureSession?.addInput(input)
		} else {
			os_log(.error, "Failed to add video device input to capture session.")
			return
		}

		// Configure output
		videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
		videoDataOutput.alwaysDiscardsLateVideoFrames = true
		videoDataOutput.setSampleBufferDelegate(self, queue: captureQueue)

		// Add output
		if captureSession?.canAddOutput(videoDataOutput) == true {
			captureSession?.addOutput(videoDataOutput)
		} else {
			os_log(.error, "Failed to add video data output to capture session.")
			return
		}

		os_log(.info, "AVCaptureSession setup complete.")
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [.deviceTransportType, .deviceModel]
	}
	
	func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
		
		let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
		if properties.contains(.deviceTransportType) {
			deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
		}
		if properties.contains(.deviceModel) {
			deviceProperties.model = "Eye Correction Virtual Camera" // Updated model name
		}
		
		return deviceProperties
	}
	
	func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
		
		// Handle settable properties here.
	}
	
	func startStreaming() {
		
		// Start the AVCaptureSession instead of the timer
		captureQueue.async { [weak self] in
			guard let self = self, let session = self.captureSession, !session.isRunning else { return }
			os_log(.info, "Starting AVCaptureSession...")
			session.startRunning()
			
			// Increment counter only after successfully starting
			DispatchQueue.main.async { // Ensure counter access is thread-safe if needed, though likely fine here
				self._streamingCounter += 1
				os_log(.info, "Streaming started. Counter: \(self._streamingCounter)")
			}
		}
	}
	
	func stopStreaming() {
		
		// Stop the AVCaptureSession
		captureQueue.async { [weak self] in
			guard let self = self, let session = self.captureSession, session.isRunning else { return }
			
			let shouldStop = DispatchQueue.main.sync { // Synchronize counter access
				if self._streamingCounter > 0 {
					self._streamingCounter -= 1
				}
				return self._streamingCounter == 0
			}

			if shouldStop {
				os_log(.info, "Stopping AVCaptureSession...")
				session.stopRunning()
				os_log(.info, "Streaming stopped.")
			}
		}
	}

	// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

	func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
		// Check if streaming is active
		guard _streamingCounter > 0 else {
			return
		}

		// Get the pixel buffer from the sample buffer
		guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
			os_log(.error, "Failed to get pixel buffer from sample buffer")
			return
		}

		// --- Start Error Handling Block ---
		var finalPixelBuffer = pixelBuffer // Default to original if processing fails
		do {
			// Create a CIImage from the pixel buffer
			let originalImage = CIImage(cvPixelBuffer: pixelBuffer)

			// --- Face Detection ---
			let faceLandmarksRequest = VNDetectFaceLandmarksRequest { [weak self] request, error in
				guard let self = self else { return }

				if let error = error {
					os_log(.error, "Face landmark detection failed: \(error.localizedDescription)")
					// If detection fails, we might still want to pass the original frame
					// Or handle differently (e.g., skip correction for this frame)
					// For now, we'll let the outer catch handle passing the original frame.
					return // Exit the closure on error
				}

				guard let results = request.results as? [VNFaceObservation], let firstFace = results.first else {
					// No face detected, pass original frame (handled by finalPixelBuffer default)
					// os_log(.debug, "No face detected in frame.")
					return
				}

				// --- Eye Correction Logic (Simplified) ---
				// Get eye landmarks (assuming they exist if face is detected)
				guard let leftEye = firstFace.landmarks?.leftEye, let rightEye = firstFace.landmarks?.rightEye else {
					os_log(.info, "Could not get eye landmarks.")
					return // Pass original frame
				}

				// Calculate center of eyes (normalized coordinates)
				let leftEyeCenter = self.calculateCentroid(points: leftEye.normalizedPoints)
				let rightEyeCenter = self.calculateCentroid(points: rightEye.normalizedPoints)
				let eyeMidPoint = CGPoint(x: (leftEyeCenter.x + rightEyeCenter.x) / 2.0, y: (leftEyeCenter.y + rightEyeCenter.y) / 2.0)

				// --- Apply Core Image Filter (Perspective Correction) ---
				// Define target gaze point (center of the frame in normalized coordinates)
				let targetPoint = CGPoint(x: 0.5, y: 0.5)

				// Calculate the shift vector (from eye midpoint to target)
				let shiftVector = CIVector(x: targetPoint.x - eyeMidPoint.x, y: targetPoint.y - eyeMidPoint.y)

				// Calculate shift magnitude (simple example: scale based on distance)
				let imageSize = originalImage.extent.size // Get image size from CIImage
				let distanceFromCenter = sqrt(pow(shiftVector.x, 2) + pow(shiftVector.y, 2))
				let maxShiftFactor: CGFloat = 0.08 // Max allowed shift (e.g., 8% of frame dimension)
				let shiftMagnitude = min(distanceFromCenter * 0.4, maxShiftFactor) // Adjust scaling factor as needed

				// Use CIPerspectiveCorrection filter
				guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
					os_log(.error, "Failed to create CIPerspectiveCorrection filter.")
					return // Pass original frame
				}
				filter.setValue(originalImage, forKey: kCIInputImageKey)

				// Calculate the new corner points based on the shift
				// Apply the *inverse* shift to the corners
				let dx = shiftVector.x * shiftMagnitude * imageSize.width
				let dy = shiftVector.y * shiftMagnitude * imageSize.height

				filter.setValue(CIVector(cgPoint: CGPoint(x: 0 - dx, y: imageSize.height - dy)), forKey: "inputTopLeft")
				filter.setValue(CIVector(cgPoint: CGPoint(x: imageSize.width - dx, y: imageSize.height - dy)), forKey: "inputTopRight")
				filter.setValue(CIVector(cgPoint: CGPoint(x: 0 - dx, y: 0 - dy)), forKey: "inputBottomLeft")
				filter.setValue(CIVector(cgPoint: CGPoint(x: imageSize.width - dx, y: 0 - dy)), forKey: "inputBottomRight")

				guard let outputImage = filter.outputImage else {
					os_log(.error, "Failed to apply Core Image perspective filter.")
					return // Pass original frame
				}

				// --- Render Output to a New Pixel Buffer ---
				// Create a new pixel buffer for the output
				var processedPixelBuffer: CVPixelBuffer?
				CVPixelBufferPoolCreatePixelBuffer(nil, self._bufferPool, &processedPixelBuffer)

				guard let outputPixelBuffer = processedPixelBuffer else {
					os_log(.error, "Failed to create output pixel buffer.")
					return // Pass original frame
				}

				do {
					// Render the processed CIImage into the output pixel buffer
					self.ciContext.render(outputImage, to: outputPixelBuffer)
					finalPixelBuffer = outputPixelBuffer // Update final buffer only on success
				} catch let renderError {
					os_log(.error, "Failed to render processed image: \(renderError.localizedDescription)")
					// Pass original frame (already default)
				}
			}

			// Perform the request on the image
			let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
			try handler.perform([faceLandmarksRequest])

		} catch let error {
			os_log(.error, "Error during Vision request or processing: \(error.localizedDescription)")
			// Ensure original pixelBuffer is used if any error occurs in the 'do' block
			finalPixelBuffer = pixelBuffer
		}
		// --- End Error Handling Block ---

		// Get the timestamp for the frame
		let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

		// Enqueue the final pixel buffer (either original or processed)
		// Create a new CMSampleBuffer with the potentially modified pixel buffer and original timing info
		var timingInfo = CMSampleTimingInfo(
			duration: CMSampleBufferGetDuration(sampleBuffer), // Use original duration
			presentationTimeStamp: timestamp, // Use original timestamp
			decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer) // Use original decode timestamp, or kCMTimeInvalid if not needed
		)

		var newSampleBuffer: CMSampleBuffer?
		let osStatus = CMSampleBufferCreateForImageBuffer(
			allocator: kCFAllocatorDefault,
			imageBuffer: finalPixelBuffer, // Use the potentially modified buffer
			dataReady: true,
			makeDataReadyCallback: nil,
			refcon: nil,
			formatDescription: _videoDescription, // Use the stored format description
			sampleTiming: &timingInfo,
			sampleBufferOut: &newSampleBuffer
		)

		if osStatus == kCVReturnSuccess, let bufferToSend = newSampleBuffer {
			// Use the send method
			_streamSource.stream.send(bufferToSend, discontinuity: [], hostTimeInNanoseconds: CMClockGetHostTimeInNanoseconds())
		} else {
			os_log(.error, "Failed to create new sample buffer for processed frame. OSStatus: \(osStatus)")
		}
	}

	// Helper function to calculate centroid (center) of points
	private func calculateCentroid(points: [CGPoint]) -> CGPoint {
		guard !points.isEmpty else { return .zero }
		let sumX = points.reduce(0) { $0 + $1.x }
		let sumY = points.reduce(0) { $0 + $1.y }
		return CGPoint(x: sumX / CGFloat(points.count), y: sumY / CGFloat(points.count))
	}

}

// MARK: -

class EyeCorrectionCameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
	
	private(set) var stream: CMIOExtensionStream!
	
	let device: CMIOExtensionDevice
	
	private let _streamFormat: CMIOExtensionStreamFormat
	
	init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
		
		self.device = device
		self._streamFormat = streamFormat
		super.init()
		self.stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source, clockType: .hostTime, source: self)
	}
	
	var formats: [CMIOExtensionStreamFormat] {
		
		return [_streamFormat]
	}
	
	var activeFormatIndex: Int = 0 {
		
		didSet {
			if activeFormatIndex >= 1 {
				os_log(.error, "Invalid index")
			}
		}
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		return [.streamActiveFormatIndex, .streamFrameDuration]
	}
	
	func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
		
		let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
		if properties.contains(.streamActiveFormatIndex) {
			streamProperties.activeFormatIndex = 0
		}
		if properties.contains(.streamFrameDuration) {
			let frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
			streamProperties.frameDuration = frameDuration
		}
		
		return streamProperties
	}
	
	func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
		
		if let activeFormatIndex = streamProperties.activeFormatIndex {
			self.activeFormatIndex = activeFormatIndex
		}
	}
	
	func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
		
		// An opportunity to inspect the client info and decide if it should be allowed to start the stream.
		return true
	}
	
	func startStream() throws {
		
		guard let deviceSource = device.source as? EyeCorrectionCameraExtensionDeviceSource else {
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		deviceSource.startStreaming()
	}
	
	func stopStream() throws {
		
		guard let deviceSource = device.source as? EyeCorrectionCameraExtensionDeviceSource else {
			fatalError("Unexpected source type \(String(describing: device.source))")
		}
		deviceSource.stopStreaming()
	}
}

// MARK: -

class EyeCorrectionCameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
	
	private(set) var provider: CMIOExtensionProvider!
	
	private var deviceSource: EyeCorrectionCameraExtensionDeviceSource!
	
	// CMIOExtensionProviderSource protocol methods (all are required)
	
	init(clientQueue: DispatchQueue?) {
		
		super.init()
		
		provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
		// Use a more descriptive name for the device
		deviceSource = EyeCorrectionCameraExtensionDeviceSource(localizedName: "Eye Correction Camera")
		
		do {
			try provider.addDevice(deviceSource.device)
		} catch let error {
			fatalError("Failed to add device: \(error.localizedDescription)")
		}
	}
	
	func connect(to client: CMIOExtensionClient) throws {
		
		// Handle client connect
		os_log(.info, "Client connected: \(client.description)")
	}
	
	func disconnect(from client: CMIOExtensionClient) {
		
		// Handle client disconnect
		os_log(.info, "Client disconnected: \(client.description)")
	}
	
	var availableProperties: Set<CMIOExtensionProperty> {
		
		// See full list of CMIOExtensionProperty choices in CMIOExtensionProperties.h
		return [.providerManufacturer]
	}
	
	func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
		
		let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
		if properties.contains(.providerManufacturer) {
			providerProperties.manufacturer = "Eye Correction App" // Updated manufacturer
		}
		return providerProperties
	}
	
	func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
		
		// Handle settable properties here.
	}
}
