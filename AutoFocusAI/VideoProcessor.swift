import AVFoundation
import CoreImage
import Foundation
import Observation
import Vision

@MainActor
@Observable
final class VideoProcessor {
	let inputURL = URL(fileURLWithPath: "walking-short-2.mov")
	let clock = ContinuousClock()

	var currentSource: CIImage?
	var currentOutput: CIImage?
	var currentState: ShotState?
	
	var size: CGSize?

	init() {}

	func process() async {
		let videoAsset = AVURLAsset(url: inputURL)

		let track = try! await videoAsset.loadTracks(withMediaType: .video).first!
		let (naturalSize, preferredTransform) = try! await track.load(.naturalSize, .preferredTransform)
		let size = CGSizeApplyAffineTransform(naturalSize, preferredTransform)
		print("size", size)
		self.apply(size: size)

		let shotTracker = ShotTracker(sourceSize: size)

		let assetReader = try! AVAssetReader(asset: videoAsset)

		let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		])
		trackOutput.alwaysCopiesSampleData = false

		assert(assetReader.canAdd(trackOutput))
		assetReader.add(trackOutput)

		assetReader.startReading()

		var lastFrame = clock.now
		while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
			let presentationTime = sampleBuffer.presentationTimeStamp
			let image = CIImage(cvImageBuffer: sampleBuffer.imageBuffer!)

			let visionRequestHandler = ImageRequestHandler(image)

			let bodyPostRequest = DetectHumanBodyPoseRequest()
			let poses = try! await visionRequestHandler.perform(bodyPostRequest)

			if let pose = poses.first {
				let state = await shotTracker.track(pose, at: presentationTime)

				var output = image
					.cropped(to: state.bounds)
				output = output
					.transformed(by:
						CGAffineTransform.identity
							.translatedBy(x: -output.extent.origin.x, y: -output.extent.origin.y)
					)

				self.apply(
					source: image,
					output: output,
					state: state
				)
			}

			let nextFrame = lastFrame.advanced(by: .seconds(Double(1.0 / 30.0)))
			try! await clock.sleep(until: nextFrame)
			lastFrame = nextFrame
		}

		if let error = assetReader.error {
			print(error)
		} else {
			print("done")
		}
	}
	
	private func apply(size: CGSize) {
		self.size = size
	}

	private func apply(
		source: CIImage,
		output: CIImage,
		state: ShotState
	) {
		self.currentSource = source
		self.currentOutput = output
		self.currentState = state
	}
}
