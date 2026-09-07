import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import Vision

public enum PoseFrameSelectionStrategy: String, Sendable {
	case automatic
	case individualFrames
	case sequentialReader
}

public struct PoseVideoAnalysisConfiguration: Sendable {
	/// The maximum rate at which frames are sampled for pose detection.
	public var maximumFramesPerSecond: Double
	/// The maximum pixel length of the decoded frame's long edge used for Vision.
	public var maximumDetectionLongEdge: CGFloat
	/// The maximum number of sampled frames to run through Vision concurrently.
	public var maximumConcurrentDetectionRequests: Int
	/// The portion of the asset timeline to analyze, or `nil` to analyze the full video track.
	public var timeRange: CMTimeRange?
	/// How sampled frames are decoded from the video.
	public var frameSelectionStrategy: PoseFrameSelectionStrategy

	/// Creates a configuration for pose detection frame sampling and decode size.
	public init(
		maximumFramesPerSecond: Double = 1 / 5,
		maximumDetectionLongEdge: CGFloat = 720,
		maximumConcurrentDetectionRequests: Int = 2,
		timeRange: CMTimeRange? = nil,
		frameSelectionStrategy: PoseFrameSelectionStrategy = .automatic,
	) {
		self.maximumFramesPerSecond = maximumFramesPerSecond
		self.maximumDetectionLongEdge = maximumDetectionLongEdge
		self.maximumConcurrentDetectionRequests = maximumConcurrentDetectionRequests
		self.timeRange = timeRange
		self.frameSelectionStrategy = frameSelectionStrategy
	}
}

public struct PoseVideoAnalyzer {
	public enum Error: Swift.Error {
		case noVideoTrackFound
		case selectedTimeRangeOutsideVideo
		case unableToConfigureAssetReader
		case unableToReadFrames
		case unableToGenerateImage(Swift.Error?)
		case noFramesGenerated
	}

	public typealias ProgressHandler = @Sendable (Double) async -> Void

	private struct ImageDetectionInput: Sendable {
		var index: Int
		var presentationTime: CMTime
		var image: CGImage
	}

	private typealias DetectionResult = (index: Int, frame: FrameData<[HumanBodyPoseObservation]>)

	public let asset: AVAsset
	private let videoTrack: AVAssetTrack?
	public let configuration: PoseVideoAnalysisConfiguration

	public init(
		asset: AVAsset,
		videoTrack: AVAssetTrack? = nil,
		configuration: PoseVideoAnalysisConfiguration = .init(),
	) {
		self.asset = asset
		self.videoTrack = videoTrack
		self.configuration = configuration
	}

	public func process(progressHandler: ProgressHandler? = nil) async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		let track: AVAssetTrack
		if let videoTrack {
			track = videoTrack
		} else {
			guard let loadedTrack = try await asset.loadTracks(withMediaType: .video).first else {
				throw Error.noVideoTrackFound
			}
			track = loadedTrack
		}
		let (nominalFrameRate, naturalSize, preferredTransform, trackTimeRange) = try await track.load(
			.nominalFrameRate,
			.naturalSize,
			.preferredTransform,
			.timeRange,
		)
		let timeRange = try Self.resolvedTimeRange(
			availableTimeRange: trackTimeRange,
			requestedTimeRange: configuration.timeRange,
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
		let requestedTimes = Self.requestedTimes(for: timeRange, sampleInterval: sampleInterval)
		let frameSelectionStrategy = Self.resolvedFrameSelectionStrategy(
			configuration.frameSelectionStrategy,
			requestedFrameCount: requestedTimes.count,
			sampleInterval: sampleInterval,
			nominalFrameRate: nominalFrameRate,
		)

		let frames = switch frameSelectionStrategy {
		case .automatic, .individualFrames:
			try await processIndividualFrames(
				at: requestedTimes,
				sampleInterval: sampleInterval,
				nominalFrameRate: nominalFrameRate,
				timeRange: timeRange,
				detectionSize: detectionSize,
				restrictsToTimeRange: configuration.timeRange != nil,
				progressHandler: progressHandler,
			)
		case .sequentialReader:
			try await processSequentialFrames(
				from: track,
				at: requestedTimes,
				timeRange: timeRange,
				preferredTransform: preferredTransform,
				detectionSize: detectionSize,
				progressHandler: progressHandler,
			)
		}

		guard !frames.isEmpty else { throw Error.noFramesGenerated }
		return frames
	}

	func process(at requestedTimes: [CMTime]) async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		guard !requestedTimes.isEmpty else { return [] }

		let track: AVAssetTrack
		if let videoTrack {
			track = videoTrack
		} else {
			guard let loadedTrack = try await asset.loadTracks(withMediaType: .video).first else {
				throw Error.noVideoTrackFound
			}
			track = loadedTrack
		}
		let (nominalFrameRate, naturalSize, preferredTransform, trackTimeRange) = try await track.load(
			.nominalFrameRate,
			.naturalSize,
			.preferredTransform,
			.timeRange,
		)
		let timeRange = try Self.resolvedTimeRange(
			availableTimeRange: trackTimeRange,
			requestedTimeRange: configuration.timeRange,
		)
		let sourceSize = Self.sourceSize(forNaturalSize: naturalSize, preferredTransform: preferredTransform)
		let detectionSize = Self.detectionSize(
			for: sourceSize,
			maximumLongEdge: configuration.maximumDetectionLongEdge,
		)
		let sampleInterval = Self.sampleInterval(
			forNominalFrameRate: nominalFrameRate,
			maximumFramesPerSecond: configuration.maximumFramesPerSecond,
		)

		return try await processIndividualFrames(
			at: requestedTimes.filter { $0 >= timeRange.start && $0 < timeRange.end },
			sampleInterval: sampleInterval,
			nominalFrameRate: nominalFrameRate,
			timeRange: timeRange,
			detectionSize: detectionSize,
			restrictsToTimeRange: true,
			progressHandler: nil,
		)
	}

	public static func resolvedTimeRange(
		availableTimeRange: CMTimeRange,
		requestedTimeRange: CMTimeRange?,
	) throws -> CMTimeRange {
		guard let requestedTimeRange else { return availableTimeRange }

		let intersection = CMTimeRangeGetIntersection(availableTimeRange, otherRange: requestedTimeRange)
		guard intersection.isValid, !intersection.isEmpty, intersection.duration > .zero else {
			throw Error.selectedTimeRangeOutsideVideo
		}
		return intersection
	}

	static func resolvedFrameSelectionStrategy(
		_ strategy: PoseFrameSelectionStrategy,
		requestedFrameCount: Int,
		sampleInterval: CMTime,
		nominalFrameRate: Float,
	) -> PoseFrameSelectionStrategy {
		guard strategy == .automatic else { return strategy }

		// A reader avoids repeated seeks when sampling densely, but it must decode
		// every intervening source frame. Individual extraction wins for short or
		// sparse requests where that extra decoding outweighs seek overhead.
		guard requestedFrameCount >= 12, sampleInterval > .zero else {
			return .individualFrames
		}

		let samplingFramesPerSecond = 1 / sampleInterval.seconds
		let sourceFramesPerSecond = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
		let sequentialThreshold = max(2, sourceFramesPerSecond / 4)
		return samplingFramesPerSecond >= sequentialThreshold ? .sequentialReader : .individualFrames
	}

	private func processIndividualFrames(
		at requestedTimes: [CMTime],
		sampleInterval: CMTime,
		nominalFrameRate: Float,
		timeRange: CMTimeRange,
		detectionSize: CGSize,
		restrictsToTimeRange: Bool,
		progressHandler: ProgressHandler?,
	) async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		let generator = AVAssetImageGenerator(asset: asset)
		generator.appliesPreferredTrackTransform = true
		generator.maximumSize = detectionSize
		let sourceFrameInterval = Self.sampleInterval(
			forNominalFrameRate: nominalFrameRate,
			maximumFramesPerSecond: .greatestFiniteMagnitude,
		)
		let frameTimeTolerance = min(
			Self.frameTimeTolerance(for: sampleInterval),
			sourceFrameInterval,
		)

		let maximumConcurrentDetectionRequests = max(configuration.maximumConcurrentDetectionRequests, 1)
		var frames = [FrameData<[HumanBodyPoseObservation]>?](repeating: nil, count: requestedTimes.count)
		var lastGenerationError: Swift.Error?

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

			func skipFrame() async {
				completedFrameCount += 1
				if let progressHandler {
					await progressHandler(Double(completedFrameCount) / Double(requestedTimes.count))
				}
			}

			for (index, requestedTime) in requestedTimes.enumerated() {
				// A selected range can begin between source frames. Start with the
				// first frame after that boundary so Vision never sees an earlier frame.
				let requestedFrameTime = if restrictsToTimeRange, requestedTime == timeRange.start {
					requestedTime + sourceFrameInterval
				} else {
					requestedTime
				}
				if restrictsToTimeRange {
					generator.requestedTimeToleranceBefore = min(
						frameTimeTolerance,
						max(requestedFrameTime - timeRange.start, .zero),
					)
					generator.requestedTimeToleranceAfter = min(
						frameTimeTolerance,
						max(timeRange.end - requestedFrameTime, .zero),
					)
				} else {
					generator.requestedTimeToleranceBefore = frameTimeTolerance
					generator.requestedTimeToleranceAfter = frameTimeTolerance
				}

				let image: CGImage
				let actualTime: CMTime
				do {
					(image, actualTime) = try await Self.generatedImage(using: generator, at: requestedFrameTime)
				} catch let Error.unableToGenerateImage(error) {
					lastGenerationError = error
					await skipFrame()
					continue
				}
				guard actualTime >= timeRange.start, actualTime < timeRange.end else {
					await skipFrame()
					continue
				}

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

		let generatedFrames = frames.compactMap(\.self)
		if generatedFrames.isEmpty, let lastGenerationError {
			throw Error.unableToGenerateImage(lastGenerationError)
		}
		return generatedFrames
	}

	private func processSequentialFrames(
		from track: AVAssetTrack,
		at requestedTimes: [CMTime],
		timeRange: CMTimeRange,
		preferredTransform: CGAffineTransform,
		detectionSize: CGSize,
		progressHandler: ProgressHandler?,
	) async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		let reader = try AVAssetReader(asset: asset)
		reader.timeRange = timeRange

		let output = AVAssetReaderTrackOutput(
			track: track,
			outputSettings: [
				kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
			],
		)
		output.alwaysCopiesSampleData = false
		guard reader.canAdd(output) else { throw Error.unableToConfigureAssetReader }
		reader.add(output)
		guard reader.startReading() else {
			if let error = reader.error { throw error }
			throw Error.unableToReadFrames
		}

		let maximumConcurrentDetectionRequests = max(configuration.maximumConcurrentDetectionRequests, 1)
		let context = CIContext(options: [.cacheIntermediates: false])
		var frames = [FrameData<[HumanBodyPoseObservation]>?](repeating: nil, count: requestedTimes.count)
		var completedFrameCount = 0
		var requestedTimeIndex = 0

		if let progressHandler {
			await progressHandler(0)
		}

		try await withThrowingTaskGroup(of: DetectionResult.self) { group in
			var inFlightTaskCount = 0

			func store(_ result: DetectionResult) async {
				frames[result.index] = result.frame
				completedFrameCount += 1
				if let progressHandler {
					await progressHandler(Double(completedFrameCount) / Double(requestedTimes.count))
				}
			}

			while requestedTimeIndex < requestedTimes.count,
			      let sampleBuffer = output.copyNextSampleBuffer()
			{
				try Task.checkCancellation()
				let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
				guard presentationTime.isValid, presentationTime < timeRange.end else { continue }
				guard presentationTime >= requestedTimes[requestedTimeIndex] else { continue }
				guard let image = Self.image(
					from: sampleBuffer,
					preferredTransform: preferredTransform,
					detectionSize: detectionSize,
					context: context,
				) else { continue }

				repeat {
					let input = ImageDetectionInput(
						index: requestedTimeIndex,
						presentationTime: presentationTime,
						image: image,
					)
					group.addTask {
						try await Self.detectPoses(in: input)
					}
					inFlightTaskCount += 1
					requestedTimeIndex += 1

					if inFlightTaskCount >= maximumConcurrentDetectionRequests,
					   let result = try await group.next()
					{
						await store(result)
						inFlightTaskCount -= 1
					}
				} while requestedTimeIndex < requestedTimes.count
					&& presentationTime >= requestedTimes[requestedTimeIndex]
			}

			while let result = try await group.next() {
				await store(result)
			}
		}

		if requestedTimeIndex == requestedTimes.count, reader.status == .reading {
			reader.cancelReading()
		} else if reader.status == .failed {
			if let error = reader.error { throw error }
			throw Error.unableToReadFrames
		}

		if let progressHandler {
			await progressHandler(1)
		}
		return frames.compactMap(\.self)
	}

	private static func image(
		from sampleBuffer: CMSampleBuffer,
		preferredTransform: CGAffineTransform,
		detectionSize: CGSize,
		context: CIContext,
	) -> CGImage? {
		guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }

		let transformedImage = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: preferredTransform)
		let transformedExtent = transformedImage.extent.standardized
		guard transformedExtent.width > 0, transformedExtent.height > 0 else { return nil }

		let normalizedImage = transformedImage.transformed(
			by: .init(translationX: -transformedExtent.minX, y: -transformedExtent.minY),
		)
		let scale = min(
			detectionSize.width / transformedExtent.width,
			detectionSize.height / transformedExtent.height,
		)
		let scaledImage = normalizedImage.transformed(by: .init(scaleX: scale, y: scale))
		return context.createCGImage(scaledImage, from: scaledImage.extent)
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

	static func requestedTimes(for timeRange: CMTimeRange, sampleInterval: CMTime) -> [CMTime] {
		guard timeRange.duration > .zero, sampleInterval > .zero else { return [] }

		var times: [CMTime] = []
		var requestedTime = timeRange.start
		let endTime = timeRange.end

		while requestedTime < endTime {
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

extension PoseVideoAnalyzer.Error: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .noVideoTrackFound:
			"No video track was found in the selected file."
		case .selectedTimeRangeOutsideVideo:
			"The selected time range does not overlap the video."
		case .unableToConfigureAssetReader:
			"The video reader could not be configured for pose detection."
		case .unableToReadFrames:
			"The video frames could not be read for pose detection."
		case let .unableToGenerateImage(error):
			error.map { "Unable to generate an analysis frame: \($0.localizedDescription)" }
				?? "Unable to generate an analysis frame."
		case .noFramesGenerated:
			"No video frames could be generated for analysis."
		}
	}
}
