import AVFoundation
import CoreImage
import Foundation
import Vision

private actor AdaptivePoseFrameProvider {
	let analyzer: PoseVideoAnalyzer

	init(url: URL, configuration: PoseVideoAnalysisConfiguration) {
		self.analyzer = PoseVideoAnalyzer(
			asset: AVURLAsset(url: url),
			configuration: configuration,
		)
	}

	func frames(at times: [CMTime]) async throws -> [FrameData<[HumanBodyPoseObservation]>] {
		try await analyzer.process(at: times)
	}
}

public struct ReframingConfiguration: Sendable {
	public static let defaultTrackingFramesPerSecond = 8.0

	public var outputSize: VideoOutputSize
	public var trackingFramesPerSecond: Double
	public var poseAnalysisConfiguration: PoseVideoAnalysisConfiguration

	public init(
		outputSize: VideoOutputSize = .maximum9By16,
		trackingFramesPerSecond: Double = ReframingConfiguration.defaultTrackingFramesPerSecond,
		poseAnalysisConfiguration: PoseVideoAnalysisConfiguration = .init(),
	) {
		self.outputSize = outputSize
		self.trackingFramesPerSecond = trackingFramesPerSecond
		self.poseAnalysisConfiguration = poseAnalysisConfiguration
	}
}

public struct ReframingSourceAnalysis: Sendable {
	typealias PoseFrameProvider = @Sendable ([CMTime]) async throws -> [FrameData<[HumanBodyPoseObservation]>]

	public var sourceSize: CGSize
	public var poseFrames: [FrameData<[HumanBodyPoseObservation]>]
	public var timeRange: CMTimeRange?
	var poseFrameProvider: PoseFrameProvider?

	public init(
		sourceSize: CGSize,
		poseFrames: [FrameData<[HumanBodyPoseObservation]>],
		timeRange: CMTimeRange? = nil,
	) {
		self.sourceSize = sourceSize
		self.poseFrames = poseFrames
		self.timeRange = timeRange
		self.poseFrameProvider = nil
	}

	init(
		sourceSize: CGSize,
		poseFrames: [FrameData<[HumanBodyPoseObservation]>],
		timeRange: CMTimeRange?,
		poseFrameProvider: @escaping PoseFrameProvider,
	) {
		self.sourceSize = sourceSize
		self.poseFrames = poseFrames
		self.timeRange = timeRange
		self.poseFrameProvider = poseFrameProvider
	}
}

public struct ReframingAnalysis: Sendable {
	public var sourceSize: CGSize
	public var renderSize: CGSize
	public var shotStates: [FrameData<ShotState>]
	public var timeRange: CMTimeRange?

	public init(
		sourceSize: CGSize,
		renderSize: CGSize,
		shotStates: [FrameData<ShotState>],
		timeRange: CMTimeRange? = nil,
	) {
		self.sourceSize = sourceSize
		self.renderSize = renderSize
		self.shotStates = shotStates
		self.timeRange = timeRange
	}

	func interpolatedBounds(at compositionTime: CMTime) -> CGRect? {
		switch shotStates.binarySearch(for: compositionTime, transform: { $0.presentationTime }) {
		case .found(index: _, value: let frame):
			return frame.value.bounds
		case let .insert(at: index):
			guard !shotStates.isEmpty else { return nil }
			guard index != shotStates.startIndex else { return shotStates.first?.value.bounds }
			guard index != shotStates.endIndex else { return shotStates.last?.value.bounds }

			let previousFrame = shotStates[shotStates.index(before: index)]
			let nextFrame = shotStates[index]
			let duration = nextFrame.presentationTime.seconds - previousFrame.presentationTime.seconds

			guard duration > 0 else { return previousFrame.value.bounds }

			let progress = max(
				0,
				min(1, (compositionTime.seconds - previousFrame.presentationTime.seconds) / duration),
			)
			return previousFrame.value.bounds.interpolated(to: nextFrame.value.bounds, progress: progress)
		}
	}

	func previewAnalysis(maximumShotStateCount: Int) -> ReframingAnalysis {
		guard maximumShotStateCount > 1, shotStates.count > maximumShotStateCount else {
			return self
		}

		// Long sermon recordings can produce tens of thousands of crop samples. The
		// player preview only needs a representative subset because the video
		// composition already interpolates between adjacent bounds with ramps.
		let lastSourceIndex = shotStates.index(before: shotStates.endIndex)
		var reducedShotStates: [FrameData<ShotState>] = []
		reducedShotStates.reserveCapacity(maximumShotStateCount)

		var previousSourceIndex: Int?
		for reducedIndex in 0 ..< maximumShotStateCount {
			let progress = Double(reducedIndex) / Double(maximumShotStateCount - 1)
			let sourceIndex = Int((Double(lastSourceIndex) * progress).rounded())
			guard previousSourceIndex != sourceIndex else { continue }

			reducedShotStates.append(shotStates[sourceIndex])
			previousSourceIndex = sourceIndex
		}

		return ReframingAnalysis(
			sourceSize: sourceSize,
			renderSize: renderSize,
			shotStates: reducedShotStates,
			timeRange: timeRange,
		)
	}
}

public enum ReframingProgressStage: String, Sendable {
	case poseDetection
	case shotTracking
	case buildingPreview
	case buildingExport
	case exporting

	public var label: String {
		switch self {
		case .poseDetection:
			"Detecting poses..."
		case .shotTracking:
			"Cropping..."
		case .buildingPreview:
			"Building Preview..."
		case .buildingExport:
			"Preparing Export..."
		case .exporting:
			"Exporting..."
		}
	}
}

public struct ReframingProgress: Sendable {
	public var stage: ReframingProgressStage
	public var fractionCompleted: Double

	public init(stage: ReframingProgressStage, fractionCompleted: Double) {
		self.stage = stage
		self.fractionCompleted = min(max(fractionCompleted, 0), 1)
	}
}

public enum VideoReframerError: Swift.Error {
	case noVideoTrackFound
	case noDetectedSubject
	case invalidOutputSize(width: Int, height: Int)
	case outputSizeExceedsSource(
		outputWidth: Int,
		outputHeight: Int,
		sourceWidth: Int,
		sourceHeight: Int,
	)
	case unsupportedOutputFileType(String)
	case exportSessionUnavailable
	case exportFailed
	case exportCancelled
}

extension VideoReframerError: LocalizedError {
	public var errorDescription: String? {
		switch self {
		case .noVideoTrackFound:
			"No video track was found in the selected file."
		case .noDetectedSubject:
			"No subject was detected in the selected video."
		case let .invalidOutputSize(width, height):
			"The output size \(width) × \(height) isn't valid for video export."
		case let .outputSizeExceedsSource(outputWidth, outputHeight, sourceWidth, sourceHeight):
			"The \(outputWidth) × \(outputHeight) output is larger than the \(sourceWidth) × \(sourceHeight) source video."
		case let .unsupportedOutputFileType(fileType):
			"Unsupported output file type: \(fileType)"
		case .exportSessionUnavailable:
			"Unable to create an export session for this video."
		case .exportFailed:
			"Video export failed."
		case .exportCancelled:
			"Video export was cancelled."
		}
	}

	public var recoverySuggestion: String? {
		switch self {
		case .invalidOutputSize:
			"Use positive, even pixel dimensions."
		case .outputSizeExceedsSource:
			"Choose a smaller output size or use 9:16 Max."
		case .noVideoTrackFound, .noDetectedSubject, .unsupportedOutputFileType,
		     .exportSessionUnavailable, .exportFailed, .exportCancelled:
			nil
		}
	}
}

public struct VideoReframer {
	public typealias ProgressHandler = @Sendable (ReframingProgress) async -> Void

	private static let poseDetectionWeight = 0.7
	private static let shotTrackingWeight = 0.25
	private static let maximumContinuityMissCount = 3
	// Keep preview ramp counts bounded on very long timelines without changing
	// export quality, which still uses the full analysis.
	private static let maximumPreviewShotStateCount = 6000

	struct PoseCandidate: Sendable {
		var index: Int
		var center: CGPoint
		var area: CGFloat
	}

	struct CropAnimation: Sendable {
		var startTime: CMTime
		var endTime: CMTime
		var startOrigin: CGPoint
		var endOrigin: CGPoint

		func origin(at time: CMTime) -> CGPoint {
			guard endTime > startTime else { return endOrigin }
			// Movement boundaries already determine the pan's duration. Follow
			// their implied velocity instead of easing behind a moving speaker.
			let progress = CGFloat(max(
				0,
				min(1, (time - startTime).seconds / (endTime - startTime).seconds),
			))
			return CGPoint(
				x: startOrigin.x + (endOrigin.x - startOrigin.x) * progress,
				y: startOrigin.y + (endOrigin.y - startOrigin.y) * progress,
			)
		}
	}

	struct CropMotionPlan: Sendable {
		var initialOrigin: CGPoint
		var acquisitionTime: CMTime?
		var acquisitionOrigin: CGPoint?
		var animations: [CropAnimation]

		func origin(at time: CMTime) -> CGPoint {
			guard
				let acquisitionTime,
				let acquisitionOrigin,
				time >= acquisitionTime
			else {
				return initialOrigin
			}

			var origin = acquisitionOrigin
			for animation in animations {
				if time < animation.startTime {
					return origin
				}
				if time <= animation.endTime {
					return animation.origin(at: time)
				}
				origin = animation.endOrigin
			}
			return origin
		}
	}

	typealias SubjectCenterProvider = @Sendable (CMTime, CGPoint) async throws -> CGPoint?

	public let configuration: ReframingConfiguration

	public init(configuration: ReframingConfiguration = .init()) {
		self.configuration = configuration
	}

	public func analyze(asset: AVAsset, progressHandler: ProgressHandler? = nil) async throws -> ReframingAnalysis {
		let sourceAnalysis = try await analyzeSource(asset: asset, progressHandler: progressHandler)
		return try await reframe(sourceAnalysis, progressHandler: progressHandler)
	}

	public func analyzeSource(
		asset: AVAsset,
		progressHandler: ProgressHandler? = nil,
	) async throws -> ReframingSourceAnalysis {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}

		let sourceSize = try await Self.sourceSize(for: track)
		_ = try configuration.outputSize.resolve(for: sourceSize)
		let trackTimeRange = try await track.load(.timeRange)
		let timeRange = try PoseVideoAnalyzer.resolvedTimeRange(
			availableTimeRange: trackTimeRange,
			requestedTimeRange: configuration.poseAnalysisConfiguration.timeRange,
		)
		await progressHandler?(.init(stage: .poseDetection, fractionCompleted: 0))
		let analyzer = PoseVideoAnalyzer(
			asset: asset,
			videoTrack: track,
			configuration: configuration.poseAnalysisConfiguration,
		)
		let poseFrames = try await analyzer.process { progress in
			await progressHandler?(
				.init(
					stage: .poseDetection,
					fractionCompleted: progress * Self.poseDetectionWeight,
				),
			)
		}
		if let urlAsset = asset as? AVURLAsset {
			let adaptivePoseFrameProvider = AdaptivePoseFrameProvider(
				url: urlAsset.url,
				configuration: configuration.poseAnalysisConfiguration,
			)
			return ReframingSourceAnalysis(
				sourceSize: sourceSize,
				poseFrames: poseFrames,
				timeRange: timeRange,
				poseFrameProvider: { times in
					try await adaptivePoseFrameProvider.frames(at: times)
				},
			)
		} else {
			return ReframingSourceAnalysis(
				sourceSize: sourceSize,
				poseFrames: poseFrames,
				timeRange: timeRange,
			)
		}
	}

	public func reframe(
		_ sourceAnalysis: ReframingSourceAnalysis,
		progressHandler: ProgressHandler? = nil,
	) async throws -> ReframingAnalysis {
		let sourceSize = sourceAnalysis.sourceSize
		let outputSize = try configuration.outputSize.resolve(for: sourceSize)
		let tracker = ShotTracker(sourceSize: sourceSize, outputSize: outputSize)

		var selectedPoseFrames: [FrameData<HumanBodyPoseObservation?>] = []
		var detectedPoses = 0
		var trackedSubjectCenter: CGPoint?
		var continuityMissCount = 0
		let trackingCount = max(sourceAnalysis.poseFrames.count, 1)
		let trackingInterval = Self.trackingInterval(forFramesPerSecond: configuration.trackingFramesPerSecond)
		let maximumSubjectJumpDistance = Self.maximumSubjectJumpDistance(for: outputSize)

		for (index, frame) in sourceAnalysis.poseFrames.enumerated() {
			try Task.checkCancellation()
			let pose = Self.primaryPose(
				in: frame.value,
				sourceSize: sourceSize,
				preferredCenter: trackedSubjectCenter,
				maximumDistance: continuityMissCount < Self.maximumContinuityMissCount
					? maximumSubjectJumpDistance
					: nil,
			)
			if pose != nil {
				detectedPoses += 1
			}

			if let subjectCenter = await tracker.subjectCenter(for: pose) {
				trackedSubjectCenter = subjectCenter
				continuityMissCount = 0
			} else {
				continuityMissCount += 1
			}
			selectedPoseFrames.append(FrameData(presentationTime: frame.presentationTime, value: pose))

			await progressHandler?(
				.init(
					stage: .shotTracking,
					fractionCompleted: Self.poseDetectionWeight
						+ (Double(index + 1) / Double(trackingCount)) * Self.shotTrackingWeight,
				),
			)
		}

		guard detectedPoses > 0 else {
			throw VideoReframerError.noDetectedSubject
		}

		let subjectCenterProvider: SubjectCenterProvider? = sourceAnalysis.poseFrameProvider.map { poseFrameProvider in
			{ @Sendable time, preferredCenter in
				guard let frame = try await poseFrameProvider([time]).first else { return nil }
				let pose = Self.primaryPose(
					in: frame.value,
					sourceSize: sourceSize,
					preferredCenter: preferredCenter,
					maximumDistance: maximumSubjectJumpDistance,
				)
				return await tracker.subjectCenter(for: pose)
			}
		}

		let shotStates = try await Self.trackShotStates(
			selectedPoseFrames,
			tracker: tracker,
			trackingInterval: trackingInterval,
			subjectCenterProvider: subjectCenterProvider,
		)

		return ReframingAnalysis(
			sourceSize: sourceSize,
			renderSize: outputSize,
			shotStates: shotStates,
			timeRange: sourceAnalysis.timeRange,
		)
	}

	public func export(
		inputURL: URL,
		outputURL: URL,
		progressHandler: ProgressHandler? = nil,
	) async throws {
		let asset = AVURLAsset(url: inputURL)
		let analysis = try await analyze(asset: asset, progressHandler: progressHandler)
		try await export(asset: asset, analysis: analysis, outputURL: outputURL, progressHandler: progressHandler)
	}

	public func export(
		asset: AVAsset,
		analysis: ReframingAnalysis,
		outputURL: URL,
		progressHandler: ProgressHandler? = nil,
	) async throws {
		await progressHandler?(.init(stage: .buildingExport, fractionCompleted: 0))
		let videoComposition = try await self.makeVideoComposition(asset: asset, analysis: analysis)
		await progressHandler?(.init(stage: .buildingExport, fractionCompleted: 1))

		guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
			throw VideoReframerError.exportSessionUnavailable
		}

		if FileManager.default.fileExists(atPath: outputURL.path) {
			try FileManager.default.removeItem(at: outputURL)
		}

		exportSession.videoComposition = videoComposition
		exportSession.shouldOptimizeForNetworkUse = true
		if let timeRange = analysis.timeRange {
			exportSession.timeRange = timeRange
		}
		await progressHandler?(.init(stage: .exporting, fractionCompleted: 0))
		try await exportSession.export(to: outputURL, as: Self.outputFileType(for: outputURL))
		await progressHandler?(.init(stage: .exporting, fractionCompleted: 1))
	}

	public func makeOutputVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVVideoComposition {
		try await makeVideoComposition(
			asset: asset,
			analysis: analysis.previewAnalysis(maximumShotStateCount: Self.maximumPreviewShotStateCount),
		)
	}

	public func makeComparisonVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVVideoComposition {
		try await buildComparisonVideoComposition(
			asset: asset,
			analysis: analysis.previewAnalysis(maximumShotStateCount: Self.maximumPreviewShotStateCount),
		)
	}

	public static func makeComparisonAsset(from asset: AVAsset) async throws -> AVAsset {
		guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}

		let duration = try await asset.load(.duration)
		let preferredTransform = try await sourceTrack.load(.preferredTransform)

		let composition = AVMutableComposition()
		guard
			let leftTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
			let rightTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
		else {
			throw VideoReframerError.exportSessionUnavailable
		}

		let timeRange = CMTimeRange(start: .zero, duration: duration)
		try leftTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
		try rightTrack.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
		leftTrack.preferredTransform = preferredTransform
		rightTrack.preferredTransform = preferredTransform

		return composition
	}

	private func makeVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVVideoComposition {
		try await buildConfiguredOutputVideoComposition(asset: asset, analysis: analysis)
	}

	private func buildConfiguredOutputVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVVideoComposition {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}

		var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
		await Self.configureReframingTransforms(
			&layerConfiguration,
			shotStates: analysis.shotStates,
			sourceSize: analysis.sourceSize,
			renderSize: analysis.renderSize,
		)

		let instruction = try await AVVideoCompositionInstruction(
			configuration: .init(
				backgroundColor: CGColor(gray: 0, alpha: 1),
				layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerConfiguration)],
				timeRange: CMTimeRange(start: .zero, duration: asset.load(.duration)),
			),
		)

		var configuration = try await AVVideoComposition.Configuration(for: asset)
		configuration.frameDuration = try await Self.frameDuration(for: track)
		configuration.instructions = [instruction]
		configuration.renderSize = analysis.renderSize
		configuration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
		return AVVideoComposition(configuration: configuration)
	}

	private func buildComparisonVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVVideoComposition {
		try await buildConfiguredComparisonVideoComposition(asset: asset, analysis: analysis)
	}

	private func buildConfiguredComparisonVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVVideoComposition {
		let tracks = try await asset.loadTracks(withMediaType: .video)
		guard tracks.count >= 2 else {
			throw VideoReframerError.noVideoTrackFound
		}
		let leftTrack = tracks[0]
		let rightTrack = tracks[1]

		let comparisonHeight = max(1, min(analysis.sourceSize.height, analysis.renderSize.height))
		let originalAspect = analysis.sourceSize.width / max(analysis.sourceSize.height, 1)
		let outputAspect = analysis.renderSize.width / max(analysis.renderSize.height, 1)
		let originalPanelSize = CGSize(
			width: (comparisonHeight * originalAspect).rounded(),
			height: comparisonHeight.rounded(),
		)
		let outputPanelSize = CGSize(
			width: (comparisonHeight * outputAspect).rounded(),
			height: comparisonHeight.rounded(),
		)
		let comparisonRenderSize = CGSize(
			width: originalPanelSize.width + outputPanelSize.width,
			height: comparisonHeight.rounded(),
		)

		var leftLayerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: leftTrack)
		leftLayerConfiguration.setTransform(
			Self.aspectFittedTransform(
				sourceSize: analysis.sourceSize,
				destinationRect: CGRect(origin: .zero, size: originalPanelSize),
			),
			at: .zero,
		)

		var rightLayerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: rightTrack)
		await Self.configureReframingTransforms(
			&rightLayerConfiguration,
			shotStates: analysis.shotStates,
			sourceSize: analysis.sourceSize,
			renderSize: outputPanelSize,
			xOffset: originalPanelSize.width,
		)
		Self.configureCropRectangles(
			&rightLayerConfiguration,
			shotStates: analysis.shotStates,
			sourceSize: analysis.sourceSize,
		)

		let instruction = try await AVVideoCompositionInstruction(
			configuration: .init(
				backgroundColor: CGColor(gray: 0, alpha: 1),
				layerInstructions: [
					AVVideoCompositionLayerInstruction(configuration: rightLayerConfiguration),
					AVVideoCompositionLayerInstruction(configuration: leftLayerConfiguration),
				],
				timeRange: CMTimeRange(start: .zero, duration: asset.load(.duration)),
			),
		)

		var configuration = try await AVVideoComposition.Configuration(for: asset)
		configuration.frameDuration = try await Self.frameDuration(for: leftTrack)
		configuration.instructions = [instruction]
		configuration.renderSize = comparisonRenderSize
		configuration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
		return AVVideoComposition(configuration: configuration)
	}

	private static func frameDuration(for track: AVAssetTrack) async throws -> CMTime {
		let nominalFrameRate = try await track.load(.nominalFrameRate)
		if nominalFrameRate > 0 {
			return CMTime(value: 1, timescale: CMTimeScale(nominalFrameRate.rounded()))
		} else {
			return CMTime(value: 1, timescale: 30)
		}
	}

	static func trackingInterval(forFramesPerSecond framesPerSecond: Double) -> CMTime {
		let framesPerSecond = if framesPerSecond.isFinite, framesPerSecond > 0 {
			framesPerSecond
		} else {
			ReframingConfiguration.defaultTrackingFramesPerSecond
		}
		return CMTime(seconds: 1 / framesPerSecond, preferredTimescale: 600)
	}

	static func trackingTimes(from startTime: CMTime, to endTime: CMTime, interval: CMTime) -> [CMTime] {
		guard endTime > startTime else { return [] }
		guard interval > .zero else { return [endTime] }

		var times: [CMTime] = []
		var time = startTime + interval
		while time < endTime {
			times.append(time)
			time = time + interval
		}
		times.append(endTime)
		return times
	}

	static func trackShotStates(
		_ selectedPoseFrames: [FrameData<HumanBodyPoseObservation?>],
		tracker: ShotTracker,
		trackingInterval: CMTime,
		subjectCenterProvider: SubjectCenterProvider? = nil,
	) async throws -> [FrameData<ShotState>] {
		var subjectFrames: [FrameData<CGPoint?>] = []
		for frame in selectedPoseFrames {
			await subjectFrames.append(FrameData(
				presentationTime: frame.presentationTime,
				value: tracker.subjectCenter(for: frame.value),
			))
		}
		return try await trackSubjectCenters(
			subjectFrames,
			tracker: tracker,
			trackingInterval: trackingInterval,
			subjectCenterProvider: subjectCenterProvider,
		)
	}

	static func trackSubjectCenters(
		_ subjectFrames: [FrameData<CGPoint?>],
		tracker: ShotTracker,
		trackingInterval: CMTime,
		subjectCenterProvider: SubjectCenterProvider? = nil,
	) async throws -> [FrameData<ShotState>] {
		guard let firstFrame = subjectFrames.first else { return [] }

		var shotStates = await [
			FrameData(
				presentationTime: firstFrame.presentationTime,
				value: tracker.track(subjectCenter: firstFrame.value, at: firstFrame.presentationTime),
			),
		]
		let motionPlan = try await cropMotionPlan(
			for: subjectFrames,
			tracker: tracker,
			initialOrigin: shotStates[0].value.bounds.origin,
			precision: trackingInterval,
			subjectCenterProvider: subjectCenterProvider,
		)

		for (previousFrame, nextFrame) in zip(subjectFrames, subjectFrames.dropFirst()) {
			for presentationTime in trackingTimes(
				from: previousFrame.presentationTime,
				to: nextFrame.presentationTime,
				interval: trackingInterval,
			) {
				let subjectCenter: CGPoint?
				if let previous = previousFrame.value, let next = nextFrame.value {
					// Sparse detections describe positions at their own timestamps.
					// Feeding the next pose to every spring step completes the pan early.
					let progress = CGFloat(
						(presentationTime - previousFrame.presentationTime).seconds
							/ (nextFrame.presentationTime - previousFrame.presentationTime).seconds,
					)
					subjectCenter = CGPoint(
						x: previous.x + (next.x - previous.x) * progress,
						y: previous.y + (next.y - previous.y) * progress,
					)
				} else {
					// Do not invent a path through a missing detection or acquire a
					// future subject before its first observed timestamp.
					subjectCenter = presentationTime < nextFrame.presentationTime ? previousFrame.value : nextFrame.value
				}
				let framingOrigin = motionPlan.origin(at: presentationTime)
				await shotStates.append(
					FrameData(
						presentationTime: presentationTime,
						value: tracker.track(subjectCenter: subjectCenter, at: presentationTime, framingOrigin: framingOrigin),
					),
				)
			}
		}

		return shotStates
	}

	static func cropMotionPlan(
		for subjectFrames: [FrameData<CGPoint?>],
		tracker: ShotTracker,
		initialOrigin: CGPoint,
		precision: CMTime,
		subjectCenterProvider: SubjectCenterProvider? = nil,
	) async throws -> CropMotionPlan {
		let motionFrames = subjectFrames.filter { $0.value != nil }
		guard let acquisitionFrame = motionFrames.first,
		      let acquisitionCenter = acquisitionFrame.value
		else {
			return CropMotionPlan(
				initialOrigin: initialOrigin,
				acquisitionTime: nil,
				acquisitionOrigin: nil,
				animations: [],
			)
		}

		let acquisitionOrigin = await tracker.compositionOrigin(for: acquisitionCenter)
		var animations: [CropAnimation] = []
		var plannedOrigin = acquisitionOrigin
		var index = 1
		let continuationThreshold = min(
			tracker.targetOutput.width,
			tracker.targetOutput.height,
		) * 0.02

		while index < motionFrames.count {
			guard
				let previousCenter = motionFrames[index - 1].value,
				let center = motionFrames[index].value
			else {
				index += 1
				continue
			}

			let proposedOrigin = await tracker.framingOrigin(for: center, relativeTo: plannedOrigin)
			let initialMovement = proposedOrigin - plannedOrigin
			guard initialMovement.length > 0.5 else {
				index += 1
				continue
			}

			let startTime = try await cropAnimationStartTime(
				from: motionFrames[index - 1].presentationTime,
				center: previousCenter,
				to: motionFrames[index].presentationTime,
				center: center,
				framingOrigin: plannedOrigin,
				tracker: tracker,
				precision: precision,
				movementThreshold: continuationThreshold,
				subjectCenterProvider: subjectCenterProvider,
			)
			var endIndex = index
			var endOrigin = proposedOrigin

			while endIndex + 1 < motionFrames.count,
			      let nextCenter = motionFrames[endIndex + 1].value
			{
				let nextOrigin = await tracker.framingOrigin(for: nextCenter, relativeTo: plannedOrigin)
				let continuation = nextOrigin - endOrigin
				guard continuation.length > continuationThreshold,
				      continuation.dot(initialMovement) > 0
				else {
					break
				}
				endIndex += 1
				endOrigin = nextOrigin
			}

			let endTime = if endIndex > 0 {
				try await cropAnimationEndTime(
					from: motionFrames[endIndex - 1],
					to: motionFrames[endIndex],
					framingOrigin: plannedOrigin,
					endOrigin: endOrigin,
					tracker: tracker,
					precision: precision,
					continuationThreshold: continuationThreshold,
					subjectCenterProvider: subjectCenterProvider,
				)
			} else {
				motionFrames[endIndex].presentationTime
			}

			animations.append(CropAnimation(
				startTime: startTime,
				endTime: endTime,
				startOrigin: plannedOrigin,
				endOrigin: endOrigin,
			))
			plannedOrigin = endOrigin
			index = endIndex + 1
		}

		return CropMotionPlan(
			initialOrigin: initialOrigin,
			acquisitionTime: acquisitionFrame.presentationTime,
			acquisitionOrigin: acquisitionOrigin,
			animations: animations,
		)
	}

	private static func cropAnimationStartTime(
		from startTime: CMTime,
		center startCenter: CGPoint,
		to endTime: CMTime,
		center endCenter: CGPoint,
		framingOrigin: CGPoint,
		tracker: ShotTracker,
		precision: CMTime,
		movementThreshold: CGFloat,
		subjectCenterProvider: SubjectCenterProvider?,
	) async throws -> CMTime {
		guard endTime > startTime else { return endTime }
		let startOrigin = await tracker.framingOrigin(for: startCenter, relativeTo: framingOrigin)
		if (startOrigin - framingOrigin).length > 0.5 {
			return startTime
		}

		var lowerBound = startTime
		var upperBound = endTime
		let expectedMovement = endCenter - startCenter
		let precisionSeconds = max(precision.seconds, 1.0 / 60.0)
		while (upperBound - lowerBound).seconds > precisionSeconds {
			let midpoint = lowerBound + CMTimeMultiplyByFloat64(upperBound - lowerBound, multiplier: 0.5)
			let progress = CGFloat((midpoint - startTime).seconds / (endTime - startTime).seconds)
			let estimatedCenter = CGPoint(
				x: startCenter.x + (endCenter.x - startCenter.x) * progress,
				y: startCenter.y + (endCenter.y - startCenter.y) * progress,
			)
			let center: CGPoint
			if let subjectCenterProvider {
				guard let detectedCenter = try await subjectCenterProvider(midpoint, estimatedCenter) else {
					upperBound = midpoint
					continue
				}
				center = detectedCenter
			} else {
				center = estimatedCenter
			}
			let movement = center - startCenter
			if movement.length > movementThreshold, movement.dot(expectedMovement) > 0 {
				upperBound = midpoint
			} else {
				lowerBound = midpoint
			}
		}
		return upperBound
	}

	private static func cropAnimationEndTime(
		from startFrame: FrameData<CGPoint?>,
		to endFrame: FrameData<CGPoint?>,
		framingOrigin: CGPoint,
		endOrigin: CGPoint,
		tracker: ShotTracker,
		precision: CMTime,
		continuationThreshold: CGFloat,
		subjectCenterProvider: SubjectCenterProvider?,
	) async throws -> CMTime {
		guard
			let startCenter = startFrame.value,
			let endCenter = endFrame.value,
			endFrame.presentationTime > startFrame.presentationTime,
			let subjectCenterProvider
		else {
			return endFrame.presentationTime
		}

		var lowerBound = startFrame.presentationTime
		var upperBound = endFrame.presentationTime
		let precisionSeconds = max(precision.seconds, 1.0 / 60.0)
		while (upperBound - lowerBound).seconds > precisionSeconds {
			let midpoint = lowerBound + CMTimeMultiplyByFloat64(upperBound - lowerBound, multiplier: 0.5)
			let progress = CGFloat(
				(midpoint - startFrame.presentationTime).seconds
					/ (endFrame.presentationTime - startFrame.presentationTime).seconds,
			)
			let estimatedCenter = CGPoint(
				x: startCenter.x + (endCenter.x - startCenter.x) * progress,
				y: startCenter.y + (endCenter.y - startCenter.y) * progress,
			)
			guard let center = try await subjectCenterProvider(midpoint, estimatedCenter) else {
				lowerBound = midpoint
				continue
			}
			let origin = await tracker.framingOrigin(for: center, relativeTo: framingOrigin)
			if (origin - endOrigin).length <= continuationThreshold {
				upperBound = midpoint
			} else {
				lowerBound = midpoint
			}
		}
		return upperBound
	}

	@concurrent
	private static func configureReframingTransforms(
		_ configuration: inout AVVideoCompositionLayerInstruction.Configuration,
		shotStates: [FrameData<ShotState>],
		sourceSize: CGSize,
		renderSize: CGSize,
		xOffset: CGFloat = 0,
		yOffset: CGFloat = 0,
	) async {
		guard let firstState = shotStates.first else { return }

		configuration.setTransform(
			transform(for: firstState.value.bounds, sourceSize: sourceSize, renderSize: renderSize, xOffset: xOffset, yOffset: yOffset),
			at: .zero,
		)

		for (from, to) in zip(shotStates, shotStates.dropFirst()) {
			for (startTime, endTime, startBounds, endBounds) in transitionSegments(
				from: from,
				to: to,
			) {
				configuration.addTransformRamp(
					.init(
						timeRange: CMTimeRange(start: startTime, end: endTime),
						start: transform(
							for: startBounds,
							sourceSize: sourceSize,
							renderSize: renderSize,
							xOffset: xOffset,
							yOffset: yOffset,
						),
						end: transform(
							for: endBounds,
							sourceSize: sourceSize,
							renderSize: renderSize,
							xOffset: xOffset,
							yOffset: yOffset,
						),
					),
				)
			}
		}
	}

	private static func configureCropRectangles(
		_ configuration: inout AVVideoCompositionLayerInstruction.Configuration,
		shotStates: [FrameData<ShotState>],
		sourceSize: CGSize,
	) {
		guard let firstState = shotStates.first else { return }

		configuration.setCropRectangle(videoSpaceRect(for: firstState.value.bounds, sourceSize: sourceSize), at: .zero)

		for (from, to) in zip(shotStates, shotStates.dropFirst()) {
			for (startTime, endTime, startBounds, endBounds) in transitionSegments(
				from: from,
				to: to,
			) {
				configuration.addCropRectangleRamp(
					.init(
						timeRange: CMTimeRange(start: startTime, end: endTime),
						start: videoSpaceRect(for: startBounds, sourceSize: sourceSize),
						end: videoSpaceRect(for: endBounds, sourceSize: sourceSize),
					),
				)
			}
		}
	}

	static func transitionSegments(
		from: FrameData<ShotState>,
		to: FrameData<ShotState>,
	) -> [(startTime: CMTime, endTime: CMTime, startBounds: CGRect, endBounds: CGRect)] {
		let timeRange = CMTimeRange(start: from.presentationTime, end: to.presentationTime)
		guard timeRange.duration > .zero else { return [] }

		return [(
			startTime: timeRange.start,
			endTime: timeRange.end,
			startBounds: from.value.bounds,
			endBounds: to.value.bounds,
		)]
	}

	private static func transform(
		for bounds: CGRect,
		sourceSize: CGSize,
		renderSize: CGSize,
		xOffset: CGFloat = 0,
		yOffset: CGFloat = 0,
	) -> CGAffineTransform {
		let videoRect = videoSpaceRect(for: bounds, sourceSize: sourceSize)
		let scaleX = renderSize.width / max(videoRect.width, 1)
		let scaleY = renderSize.height / max(videoRect.height, 1)
		return .init(
			a: scaleX,
			b: 0,
			c: 0,
			d: scaleY,
			tx: xOffset - videoRect.minX * scaleX,
			ty: yOffset - videoRect.minY * scaleY,
		)
	}

	private static func videoSpaceRect(for bounds: CGRect, sourceSize: CGSize) -> CGRect {
		CGRect(
			x: bounds.minX,
			y: sourceSize.height - bounds.maxY,
			width: bounds.width,
			height: bounds.height,
		)
	}

	private static func aspectFittedTransform(sourceSize: CGSize, destinationRect: CGRect) -> CGAffineTransform {
		let scale = min(destinationRect.width / sourceSize.width, destinationRect.height / sourceSize.height)
		let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
		return .init(
			a: scale,
			b: 0,
			c: 0,
			d: scale,
			tx: destinationRect.minX + (destinationRect.width - scaledSize.width) / 2,
			ty: destinationRect.minY + (destinationRect.height - scaledSize.height) / 2,
		)
	}

	private static func reframedImage(_ image: CIImage, cropRect: CGRect, renderSize: CGSize) -> CIImage {
		let cropped = image.cropped(to: cropRect)
		let translated = cropped.transformed(by: .init(translationX: -cropRect.minX, y: -cropRect.minY))
		let scaleTransform = CGAffineTransform(
			scaleX: renderSize.width / cropRect.width,
			y: renderSize.height / cropRect.height,
		)
		return translated.transformed(by: scaleTransform)
	}

	private static func aspectFittedImage(_ image: CIImage, into destinationRect: CGRect) -> CIImage {
		let extent = image.extent
		let normalized = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY))
		let scale = min(destinationRect.width / extent.width, destinationRect.height / extent.height)
		let scaledSize = CGSize(width: extent.width * scale, height: extent.height * scale)
		let scaled = normalized.transformed(by: .init(scaleX: scale, y: scale))
		let x = destinationRect.minX + (destinationRect.width - scaledSize.width) / 2
		let y = destinationRect.minY + (destinationRect.height - scaledSize.height) / 2
		return scaled.transformed(by: .init(translationX: x, y: y))
	}

	private static func outputFileType(for outputURL: URL) throws -> AVFileType {
		switch outputURL.pathExtension.lowercased() {
		case "mov":
			return .mov
		case "mp4":
			return .mp4
		default:
			throw VideoReframerError.unsupportedOutputFileType(outputURL.pathExtension)
		}
	}

	private static func primaryPose(
		in poses: [HumanBodyPoseObservation],
		sourceSize: CGSize,
		preferredCenter: CGPoint?,
		maximumDistance: CGFloat?,
	) -> HumanBodyPoseObservation? {
		let candidates = poses.enumerated().map { index, pose in
			let rect = boundingRect(for: pose, sourceSize: sourceSize)
			return PoseCandidate(
				index: index,
				center: CGPoint(x: rect.midX, y: rect.midY),
				area: rect.width * rect.height,
			)
		}

		guard let index = selectedPoseCandidateIndex(
			in: candidates,
			preferredCenter: preferredCenter,
			maximumDistance: maximumDistance,
		) else { return nil }

		return poses[index]
	}

	static func selectedPoseCandidateIndex(
		in candidates: [PoseCandidate],
		preferredCenter: CGPoint?,
		maximumDistance: CGFloat?,
	) -> Int? {
		guard let preferredCenter else {
			return candidates.max { $0.area < $1.area }?.index
		}

		let nearbyCandidates: [PoseCandidate]
		if let maximumDistance {
			nearbyCandidates = candidates.filter {
				hypot($0.center.x - preferredCenter.x, $0.center.y - preferredCenter.y) <= maximumDistance
			}
		} else {
			nearbyCandidates = candidates
		}

		return nearbyCandidates
			.max { lhs, rhs in
				let lhsDistance = hypot(lhs.center.x - preferredCenter.x, lhs.center.y - preferredCenter.y)
				let rhsDistance = hypot(rhs.center.x - preferredCenter.x, rhs.center.y - preferredCenter.y)
				let lhsScore = lhs.area / max(lhsDistance, 1)
				let rhsScore = rhs.area / max(rhsDistance, 1)
				return lhsScore < rhsScore
			}?
			.index
	}

	static func maximumSubjectJumpDistance(for outputSize: CGSize) -> CGFloat {
		hypot(outputSize.width, outputSize.height)
	}

	private static func boundingRect(for pose: HumanBodyPoseObservation, sourceSize: CGSize) -> CGRect {
		let points = pose.allJoints().values.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) }
		return CGRect.boundingRect(of: points)
	}

	private static func sourceSize(for track: AVAssetTrack) async throws -> CGSize {
		let (naturalSize, preferredTransform) = try await track.load(.naturalSize, .preferredTransform)
		let rect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
		return CGSize(width: abs(rect.width), height: abs(rect.height))
	}
}

private extension CGRect {
	func interpolated(to other: CGRect, progress: Double) -> CGRect {
		let progress = CGFloat(progress)

		return CGRect(
			x: origin.x + (other.origin.x - origin.x) * progress,
			y: origin.y + (other.origin.y - origin.y) * progress,
			width: size.width + (other.size.width - size.width) * progress,
			height: size.height + (other.size.height - size.height) * progress,
		)
	}
}

private extension CGPoint {
	static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
		CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
	}

	var length: CGFloat {
		hypot(x, y)
	}

	func dot(_ other: CGPoint) -> CGFloat {
		x * other.x + y * other.y
	}
}
