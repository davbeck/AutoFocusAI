import AVFoundation
import CoreImage
import Foundation
import Vision

public actor VideoProcessor {
	public enum Error: Swift.Error {
		case noVideoTrackFound
		case couldNotAddTrackOutput
	}

	public let asset: AVAsset

	public init(asset: AVAsset) {
		self.asset = asset
	}

	public func process() async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Error.noVideoTrackFound }

		let assetReader = try AVAssetReader(asset: asset)

		let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		])
		trackOutput.alwaysCopiesSampleData = false

		guard assetReader.canAdd(trackOutput) else { throw Error.couldNotAddTrackOutput }
		assetReader.add(trackOutput)

		assetReader.startReading()

		var frames: [FrameData<[HumanBodyPoseObservation]>] = []

		while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
			let presentationTime = sampleBuffer.presentationTimeStamp

			guard let imageBuffer = sampleBuffer.imageBuffer else { continue }
			let image = CIImage(cvImageBuffer: imageBuffer)

			let visionRequestHandler = ImageRequestHandler(image)

			let bodyPostRequest = DetectHumanBodyPoseRequest()
			let poses = try await visionRequestHandler.perform(bodyPostRequest)

			frames.append(FrameData(presentationTime: presentationTime, value: poses))
		}

		if let error = assetReader.error {
			throw error
		}

		return frames
	}
}

public struct FrameData<Value> {
	public var presentationTime: CMTime
	public var value: Value

	public init(presentationTime: CMTime, value: Value) {
		self.presentationTime = presentationTime
		self.value = value
	}
}

extension FrameData: Sendable where Value: Sendable {}
