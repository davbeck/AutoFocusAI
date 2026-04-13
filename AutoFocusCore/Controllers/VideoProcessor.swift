import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Vision

public struct VideoProcessingConfiguration: Sendable {
	/// The maximum rate at which frames are sampled for pose detection.
	public var maximumFramesPerSecond: Double
	/// The maximum pixel length of the decoded frame's long edge used for Vision.
	public var maximumDetectionLongEdge: CGFloat
	/// The maximum number of sampled frames to run through Vision concurrently.
	///
	/// The current default of `2` is a measured balance point: it overlaps decode
	/// and body-pose work enough to beat the reader-only path, while wider
	/// pipelines started to lose time to contention on the benchmark sermon clip.
	public var maximumConcurrentDetectionRequests: Int

	/// Creates a configuration for pose detection frame sampling and decode size.
	public init(
		maximumFramesPerSecond: Double = 10,
		maximumDetectionLongEdge: CGFloat = 720,
		maximumConcurrentDetectionRequests: Int = 2,
	) {
		self.maximumFramesPerSecond = maximumFramesPerSecond
		self.maximumDetectionLongEdge = maximumDetectionLongEdge
		self.maximumConcurrentDetectionRequests = maximumConcurrentDetectionRequests
	}
}

public struct VideoProcessor {
	public enum Error: Swift.Error {
		case noVideoTrackFound
		case unableToStartReading(Swift.Error?)
	}

	public typealias ProgressHandler = @Sendable (Double) async -> Void

	private struct DetectionInput: @unchecked Sendable {
		var index: Int
		var presentationTime: CMTime
		var sampleBuffer: CMSampleBuffer
	}

	private typealias DetectionResult = (index: Int, frame: FrameData<[HumanBodyPoseObservation]>)

	public let asset: AVAsset
	public let configuration: VideoProcessingConfiguration

	public init(asset: AVAsset, configuration: VideoProcessingConfiguration = .init()) {
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
		let (reader, sampleBufferOutput) = try Self.makeSampleBufferOutput(
			asset: asset,
			track: track,
			outputSize: detectionSize,
		)
		let orientation = Self.imageOrientation(for: preferredTransform)
		// Keep a small amount of overlap without flooding the system with Vision
		// work. Benchmarks showed `2` in flight was faster than both a fully serial
		// reader path and a wider pipeline of `3`.
		let maximumConcurrentDetectionRequests = max(configuration.maximumConcurrentDetectionRequests, 1)

		var frames = [FrameData<[HumanBodyPoseObservation]>?](repeating: nil, count: requestedTimes.count)

		if let progressHandler {
			await progressHandler(0)
		}

		var nextRequestedTimeIndex = 0
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

			while reader.status == .reading,
			      nextRequestedTimeIndex < requestedTimes.count,
			      let sampleBuffer = sampleBufferOutput.copyNextSampleBuffer()
			{
				let actualTime = sampleBuffer.presentationTimeStamp
				guard actualTime >= requestedTimes[nextRequestedTimeIndex] else { continue }

				let input = DetectionInput(
					index: nextRequestedTimeIndex,
					presentationTime: actualTime,
					sampleBuffer: sampleBuffer,
				)
				group.addTask {
					try await Self.detectPoses(in: input, orientation: orientation)
				}
				inFlightTaskCount += 1
				nextRequestedTimeIndex += 1

				// Bound the queue so decode can stay slightly ahead of Vision without
				// building unnecessary buffer backlog or increasing CPU contention.
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

		if reader.status == .failed {
			throw Error.unableToStartReading(reader.error)
		}

		return frames.compactMap(\.self)
	}

	public static func sampleInterval(forNominalFrameRate nominalFrameRate: Float, maximumFramesPerSecond: Double) -> CMTime {
		let clampedMaximum = max(maximumFramesPerSecond, 1)
		let frameRate = nominalFrameRate > 0 ? min(Double(nominalFrameRate), clampedMaximum) : clampedMaximum
		return CMTime(seconds: 1 / frameRate, preferredTimescale: 600)
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

	private static func makeSampleBufferOutput(
		asset: AVAsset,
		track: AVAssetTrack,
		outputSize: CGSize,
	) throws -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
		let outputSettings: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
			kCVPixelBufferWidthKey as String: max(1, Int(outputSize.width.rounded())),
			kCVPixelBufferHeightKey as String: max(1, Int(outputSize.height.rounded())),
		]

		let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
		output.alwaysCopiesSampleData = false

		let reader = try AVAssetReader(asset: asset)
		guard reader.canAdd(output) else { throw Error.unableToStartReading(reader.error) }
		reader.add(output)

		guard reader.startReading() else { throw Error.unableToStartReading(reader.error) }
		return (reader, output)
	}

	static func imageOrientation(for preferredTransform: CGAffineTransform) -> CGImagePropertyOrientation {
		switch (preferredTransform.a, preferredTransform.b, preferredTransform.c, preferredTransform.d) {
		case (1, 0, 0, 1):
			return .up
		case (-1, 0, 0, -1):
			return .down
		case (0, 1, -1, 0):
			return .right
		case (0, -1, 1, 0):
			return .left
		default:
			return .up
		}
	}

	private static func detectPoses(
		in input: DetectionInput,
		orientation: CGImagePropertyOrientation,
	) async throws -> DetectionResult {
		// Vision request values are cheap to create and this keeps each task fully
		// isolated, avoiding shared mutable request state inside the task group.
		var request = DetectHumanBodyPoseRequest()
		request.detectsHands = false

		let handler = ImageRequestHandler(input.sampleBuffer, orientation: orientation)
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
