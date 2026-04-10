import AVFoundation
import CoreImage
import Foundation
import Observation
import Vision

actor VideoProcessor {
	enum Error: Swift.Error {
		case noVideoTrackFound
		case couldNotAddTrackOutput
	}

	let asset: AVAsset

	init(asset: AVAsset) {
		self.asset = asset
	}

	func process() async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Error.noVideoTrackFound }
//		let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
//		let size = CGSizeApplyAffineTransform(naturalSize, preferredTransform)

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

			let frame: FrameData<[HumanBodyPoseObservation]>
			let visionRequestHandler = ImageRequestHandler(image)

			let bodyPostRequest = DetectHumanBodyPoseRequest()
			let poses = try await visionRequestHandler.perform(bodyPostRequest)

			frame = FrameData(presentationTime: presentationTime, value: poses)
			frames.append(frame)
		}

		if let error = assetReader.error {
			throw error
		}

		return frames
	}
}

struct FrameData<Value> {
	var presentationTime: CMTime
	var value: Value
}

extension FrameData: Sendable where Value: Sendable {}

// extension AVAsset {
//	func detectPoses() async throws -> [PoseFrame] {
//		let assetReader = try! AVAssetReader(asset: self)
//
//		guard let track = try await self.loadTracks(withMediaType: .video).first else { throw Error.noVideoTrackFound }
//
//		let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
//			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
//		])
//		trackOutput.alwaysCopiesSampleData = false
//
//		assert(assetReader.canAdd(trackOutput))
//		assetReader.add(trackOutput)
//
//		assetReader.startReading()
//
//		var frames: [PoseFrame] = []
//
//		while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
//			let presentationTime = sampleBuffer.presentationTimeStamp
//			let image = CIImage(cvImageBuffer: sampleBuffer.imageBuffer!)
//
//			let visionRequestHandler = ImageRequestHandler(image)
//
//			let bodyPostRequest = DetectHumanBodyPoseRequest()
//			let poses = try await visionRequestHandler.perform(bodyPostRequest)
//
//			frames.append(.init(presentationTime: presentationTime, poses: poses))
//		}
//
//		if let error = assetReader.error {
//			throw error
//		}
//
//		return frames
//	}
// }
