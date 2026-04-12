import AVFoundation
import Foundation
import Vision

public struct VideoProcessingConfiguration: Sendable {
	public var maximumFramesPerSecond: Double

	public init(maximumFramesPerSecond: Double = 10) {
		self.maximumFramesPerSecond = maximumFramesPerSecond
	}
}

public struct VideoProcessor {
	public enum Error: Swift.Error {
		case noVideoTrackFound
	}

	public typealias ProgressHandler = @Sendable (Double) async -> Void

	public let asset: AVAsset
	public let configuration: VideoProcessingConfiguration

	public init(asset: AVAsset, configuration: VideoProcessingConfiguration = .init()) {
		self.asset = asset
		self.configuration = configuration
	}

	public func process(progressHandler: ProgressHandler? = nil) async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Error.noVideoTrackFound }
		let duration = try await asset.load(.duration)
		let nominalFrameRate = try await track.load(.nominalFrameRate)

		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero

		let sampleInterval = Self.sampleInterval(
			forNominalFrameRate: nominalFrameRate,
			maximumFramesPerSecond: configuration.maximumFramesPerSecond,
		)
		let requestedTimes = Self.requestedTimes(duration: duration, sampleInterval: sampleInterval)

		var frames: [FrameData<[HumanBodyPoseObservation]>] = []
		frames.reserveCapacity(requestedTimes.count)

		if let progressHandler {
			await progressHandler(0)
		}

		for (index, requestedTime) in requestedTimes.enumerated() {
			let (image, actualTime) = try await generator.image(at: requestedTime)

			var request = DetectHumanBodyPoseRequest()
			request.detectsHands = false
			let handler = ImageRequestHandler(image)
			let poses = try await handler.perform(request)

			frames.append(FrameData(presentationTime: actualTime, value: poses))
			if let progressHandler {
				await progressHandler(Double(index + 1) / Double(requestedTimes.count))
			}
		}

		return frames
	}

	public static func sampleInterval(forNominalFrameRate nominalFrameRate: Float, maximumFramesPerSecond: Double) -> CMTime {
		let clampedMaximum = max(maximumFramesPerSecond, 1)
		let frameRate = nominalFrameRate > 0 ? min(Double(nominalFrameRate), clampedMaximum) : clampedMaximum
		return CMTime(seconds: 1 / frameRate, preferredTimescale: 600)
	}

	private static func requestedTimes(duration: CMTime, sampleInterval: CMTime) -> [CMTime] {
		guard duration > .zero, sampleInterval > .zero else { return [] }

		var times: [CMTime] = []
		var requestedTime = CMTime.zero

		while requestedTime < duration {
			times.append(requestedTime)
			requestedTime = requestedTime + sampleInterval
		}

		return times
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
