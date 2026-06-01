import AVFoundation
import CoreGraphics
import Foundation
import Vision

public struct PoseVideoAnalysisConfiguration: Sendable {
	/// The maximum rate at which frames are sampled for pose detection.
	public var maximumFramesPerSecond: Double
	/// The maximum pixel length of the decoded frame's long edge used for Vision.
	public var maximumDetectionLongEdge: CGFloat
	/// The maximum number of sampled frames to run through Vision concurrently.
	public var maximumConcurrentDetectionRequests: Int

	/// Creates a configuration for pose detection frame sampling and decode size.
	public init(
		maximumFramesPerSecond: Double = 1,
		maximumDetectionLongEdge: CGFloat = 720,
		maximumConcurrentDetectionRequests: Int = 2,
	) {
		self.maximumFramesPerSecond = maximumFramesPerSecond
		self.maximumDetectionLongEdge = maximumDetectionLongEdge
		self.maximumConcurrentDetectionRequests = maximumConcurrentDetectionRequests
	}
}

public struct PoseVideoAnalyzer {
	public enum Error: Swift.Error {
		case noVideoTrackFound
		case unableToGenerateImage(Swift.Error?)
	}

	public typealias ProgressHandler = @Sendable (Double) async -> Void

	private struct ImageDetectionInput: Sendable {
		var index: Int
		var presentationTime: CMTime
		var image: CGImage
	}

	private typealias DetectionResult = (index: Int, frame: FrameData<[HumanBodyPoseObservation]>)

	public let asset: AVAsset
	public let configuration: PoseVideoAnalysisConfiguration

	public init(asset: AVAsset, configuration: PoseVideoAnalysisConfiguration = .init()) {
		self.asset = asset
		self.configuration = configuration
	}

	public func process(progressHandler: ProgressHandler? = nil) async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Error.noVideoTrackFound }
		let duration = try await asset.load(.duration)
		let (nominalFrameRate, naturalSize, preferredTransform) = try await track.load(
			.nominalFrameRate,
			.naturalSize,
			.preferredTransform,
		)
		let sourceSize = Self.sourceSize(forNaturalSize: naturalSize, preferredTransform: preferredTransform)

		let sampleInterval = Self.sampleInterval(
			forNominalFrameRate: nominalFrameRate,
			maximumFramesPerSecond: configuration.maximumFramesPerSecond,
		)
		let detectionSize = Self.detectionSize(
			for: sourceSize,
			maximumLongEdge: configuration.maximumDetectionLongEdge,
		)
		let requestedTimes = Self.requestedTimes(duration: duration, sampleInterval: sampleInterval)
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.requestedTimeToleranceBefore = Self.frameTimeTolerance(for: sampleInterval)
		generator.requestedTimeToleranceAfter = Self.frameTimeTolerance(for: sampleInterval)
		generator.maximumSize = detectionSize

		let maximumConcurrentDetectionRequests = max(configuration.maximumConcurrentDetectionRequests, 1)
		var frames = [FrameData<[HumanBodyPoseObservation]>?](repeating: nil, count: requestedTimes.count)

		if let progressHandler {
			await progressHandler(0)
		}

		var completedFrameCount = 0

		try await withThrowingTaskGroup(of: DetectionResult.self) { group in
			var inFlightTaskCount = 0

			func store(_ result: DetectionResult) async {
				frames[result.index] = result.frame
				completedFrameCount += 1
				if let progressHandler {
					await progressHandler(Double(completedFrameCount) / Double(requestedTimes.count))
				}
			}

			for (index, requestedTime) in requestedTimes.enumerated() {
				let (image, actualTime) = try await Self.generatedImage(using: generator, at: requestedTime)
				let input = ImageDetectionInput(index: index, presentationTime: actualTime, image: image)
				group.addTask {
					try await Self.detectPoses(in: input)
				}
				inFlightTaskCount += 1

				if inFlightTaskCount >= maximumConcurrentDetectionRequests,
				   let result = try await group.next()
				{
					await store(result)
					inFlightTaskCount -= 1
				}
			}

			while let result = try await group.next() {
				await store(result)
			}
		}

		return frames.compactMap(\.self)
	}

	public static func sampleInterval(forNominalFrameRate nominalFrameRate: Float, maximumFramesPerSecond: Double) -> CMTime {
		let clampedMaximum = max(maximumFramesPerSecond, .leastNonzeroMagnitude)
		let frameRate = nominalFrameRate > 0 ? min(Double(nominalFrameRate), clampedMaximum) : clampedMaximum
		return CMTime(seconds: 1 / frameRate, preferredTimescale: 600)
	}

	/// Returns the tolerated distance from each requested timestamp when using sparse image extraction.
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
			height: max(1, (sourceSize.height * scale).rounded()),
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

	private static func sourceSize(forNaturalSize naturalSize: CGSize, preferredTransform: CGAffineTransform) -> CGSize {
		let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
		return CGSize(width: abs(rect.width), height: abs(rect.height))
	}

	private static func generatedImage(
		using generator: AVAssetImageGenerator,
		at requestedTime: CMTime,
	) async throws -> (image: CGImage, actualTime: CMTime) {
		try await withCheckedThrowingContinuation { continuation in
			generator.generateCGImageAsynchronously(for: requestedTime) { image, actualTime, error in
				if let error {
					continuation.resume(throwing: Error.unableToGenerateImage(error))
				} else if let image {
					continuation.resume(returning: (image, actualTime))
				} else {
					continuation.resume(throwing: Error.unableToGenerateImage(nil))
				}
			}
		}
	}

	private static func detectPoses(in input: ImageDetectionInput) async throws -> DetectionResult {
		var request = DetectHumanBodyPoseRequest()
		request.detectsHands = false

		let handler = ImageRequestHandler(input.image)
		let poses = try await handler.perform(request)
		return (
			input.index,
			FrameData(presentationTime: input.presentationTime, value: poses),
		)
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
