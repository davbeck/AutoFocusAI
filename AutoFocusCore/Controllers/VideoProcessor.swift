import AVFoundation
import CoreGraphics
import Foundation
import Vision

public struct VideoProcessingConfiguration: Sendable {
	/// The maximum rate at which frames are sampled for pose detection.
	public var maximumFramesPerSecond: Double
	/// The maximum pixel length of the decoded frame's long edge used for Vision.
	public var maximumDetectionLongEdge: CGFloat

	/// Creates a configuration for pose detection frame sampling and decode size.
	public init(
		maximumFramesPerSecond: Double = 10,
		maximumDetectionLongEdge: CGFloat = 720
	) {
		self.maximumFramesPerSecond = maximumFramesPerSecond
		self.maximumDetectionLongEdge = maximumDetectionLongEdge
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
		let sourceSize = try await Self.sourceSize(for: track)

		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true

		let sampleInterval = Self.sampleInterval(
			forNominalFrameRate: nominalFrameRate,
			maximumFramesPerSecond: configuration.maximumFramesPerSecond,
		)
		let frameTimeTolerance = Self.frameTimeTolerance(for: sampleInterval)
		generator.requestedTimeToleranceBefore = frameTimeTolerance
		generator.requestedTimeToleranceAfter = frameTimeTolerance
		generator.maximumSize = Self.detectionSize(
			for: sourceSize,
			maximumLongEdge: configuration.maximumDetectionLongEdge
		)
		let requestedTimes = Self.requestedTimes(duration: duration, sampleInterval: sampleInterval)

		var frames: [FrameData<[HumanBodyPoseObservation]>] = []
		frames.reserveCapacity(requestedTimes.count)
		var request = DetectHumanBodyPoseRequest()
		request.detectsHands = false

		if let progressHandler {
			await progressHandler(0)
		}

		for (index, requestedTime) in requestedTimes.enumerated() {
			let (image, actualTime) = try await generator.image(at: requestedTime)

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

	/// Returns the tolerated distance from each requested timestamp when decoding analysis frames.
	public static func frameTimeTolerance(for sampleInterval: CMTime) -> CMTime {
		guard sampleInterval > .zero else { return .zero }
		return CMTimeMultiplyByFloat64(sampleInterval, multiplier: 0.5)
	}

	/// Returns the decode size used for Vision while preserving aspect ratio and avoiding upscaling.
	public static func detectionSize(for sourceSize: CGSize, maximumLongEdge: CGFloat) -> CGSize {
		guard sourceSize.width > 0, sourceSize.height > 0 else { return .zero }
		guard maximumLongEdge > 0 else { return sourceSize }

		let longEdge = max(sourceSize.width, sourceSize.height)
		guard longEdge > maximumLongEdge else { return sourceSize }

		let scale = maximumLongEdge / longEdge
		return CGSize(
			width: max(1, (sourceSize.width * scale).rounded()),
			height: max(1, (sourceSize.height * scale).rounded())
		)
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

	private static func sourceSize(for track: AVAssetTrack) async throws -> CGSize {
		let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
		let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
		return CGSize(width: abs(rect.width), height: abs(rect.height))
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
