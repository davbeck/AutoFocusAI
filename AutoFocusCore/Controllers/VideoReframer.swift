import AVFoundation
import CoreImage
import Foundation
import Vision

public struct ReframingConfiguration: Sendable {
	public var aspectRatio: CGSize
	public var renderSize: CGSize

	public init(
		aspectRatio: CGSize = ShotTracker.defaultAspectRatio,
		renderSize: CGSize = CGSize(width: 1080, height: 1920)
	) {
		self.aspectRatio = aspectRatio
		self.renderSize = renderSize
	}
}

public struct ReframingAnalysis: Sendable {
	public var sourceSize: CGSize
	public var renderSize: CGSize
	public var shotStates: [FrameData<ShotState>]

	public init(sourceSize: CGSize, renderSize: CGSize, shotStates: [FrameData<ShotState>]) {
		self.sourceSize = sourceSize
		self.renderSize = renderSize
		self.shotStates = shotStates
	}

	func interpolatedBounds(at compositionTime: CMTime) -> CGRect? {
		switch shotStates.binarySearch(for: compositionTime, transform: { $0.presentationTime }) {
		case .found(index: _, value: let frame):
			return frame.value.bounds
		case .insert(at: let index):
			guard !shotStates.isEmpty else { return nil }
			guard index != shotStates.startIndex else { return shotStates.first?.value.bounds }
			guard index != shotStates.endIndex else { return shotStates.last?.value.bounds }

			let previousFrame = shotStates[shotStates.index(before: index)]
			let nextFrame = shotStates[index]
			let duration = nextFrame.presentationTime.seconds - previousFrame.presentationTime.seconds

			guard duration > 0 else { return previousFrame.value.bounds }

			let progress = max(
				0,
				min(1, (compositionTime.seconds - previousFrame.presentationTime.seconds) / duration)
			)
			return previousFrame.value.bounds.interpolated(to: nextFrame.value.bounds, progress: progress)
		}
	}
}

public enum ReframingProgressStage: String, Sendable {
	case poseDetection
	case shotTracking
	case buildingPreview
	case exporting

	public var label: String {
		switch self {
		case .poseDetection:
			"Detecting poses..."
		case .shotTracking:
			"Cropping..."
		case .buildingPreview:
			"Building Preview..."
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
	case unsupportedOutputFileType(String)
	case exportSessionUnavailable
	case exportFailed
	case exportCancelled
}

public actor VideoReframer {
	public typealias ProgressHandler = @Sendable (ReframingProgress) async -> Void

	private static let poseDetectionWeight = 0.7
	private static let shotTrackingWeight = 0.25

	public let configuration: ReframingConfiguration

	public init(configuration: ReframingConfiguration = .init()) {
		self.configuration = configuration
	}

	public func analyze(asset: AVAsset, progressHandler: ProgressHandler? = nil) async throws -> ReframingAnalysis {
		guard let track = try await asset.loadTracks(withMediaType: .video).first else {
			throw VideoReframerError.noVideoTrackFound
		}

		let sourceSize = try await Self.sourceSize(for: track)
		await progressHandler?(.init(stage: .poseDetection, fractionCompleted: 0))
		let poseFrames = try await VideoProcessor(asset: asset).process { progress in
			await progressHandler?(
				.init(
					stage: .poseDetection,
					fractionCompleted: progress * Self.poseDetectionWeight
				)
			)
		}
		let tracker = ShotTracker(sourceSize: sourceSize, aspectRatio: configuration.aspectRatio)

		var shotStates: [FrameData<ShotState>] = []
		var detectedPoses = 0
		let trackingCount = max(poseFrames.count, 1)

		for (index, frame) in poseFrames.enumerated() {
			let pose = Self.primaryPose(in: frame.value, sourceSize: sourceSize)
			if pose != nil {
				detectedPoses += 1
			}

			let state = await tracker.track(pose, at: frame.presentationTime)
			shotStates.append(FrameData(presentationTime: frame.presentationTime, value: state))

			await progressHandler?(
				.init(
					stage: .shotTracking,
					fractionCompleted: Self.poseDetectionWeight
						+ (Double(index + 1) / Double(trackingCount)) * Self.shotTrackingWeight
				)
			)
		}

		guard detectedPoses > 0 else {
			throw VideoReframerError.noDetectedSubject
		}

		return ReframingAnalysis(
			sourceSize: sourceSize,
			renderSize: configuration.renderSize,
			shotStates: shotStates
		)
	}

	public func export(
		inputURL: URL,
		outputURL: URL,
		progressHandler: ProgressHandler? = nil
	) async throws {
		let asset = AVURLAsset(url: inputURL)
		let analysis = try await analyze(asset: asset, progressHandler: progressHandler)
		try await export(asset: asset, analysis: analysis, outputURL: outputURL, progressHandler: progressHandler)
	}

	public func export(
		asset: AVAsset,
		analysis: ReframingAnalysis,
		outputURL: URL,
		progressHandler: ProgressHandler? = nil
	) async throws {
		let videoComposition = try await self.makeVideoComposition(asset: asset, analysis: analysis)

		guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
			throw VideoReframerError.exportSessionUnavailable
		}

		if FileManager.default.fileExists(atPath: outputURL.path) {
			try FileManager.default.removeItem(at: outputURL)
		}

		exportSession.videoComposition = videoComposition
		exportSession.shouldOptimizeForNetworkUse = true
		await progressHandler?(.init(stage: .exporting, fractionCompleted: 0))
		try await exportSession.export(to: outputURL, as: Self.outputFileType(for: outputURL))
		await progressHandler?(.init(stage: .exporting, fractionCompleted: 1))
	}

	public func makeOutputVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVVideoComposition {
		try await makeVideoComposition(asset: asset, analysis: analysis)
	}

	public func makeComparisonVideoComposition(asset: AVAsset, analysis: ReframingAnalysis) async throws -> AVVideoComposition {
		try await buildComparisonVideoComposition(asset: asset, analysis: analysis)
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
		Self.configureReframingTransforms(
			&layerConfiguration,
			shotStates: analysis.shotStates,
			sourceSize: analysis.sourceSize,
			renderSize: analysis.renderSize
		)

		let instruction = AVVideoCompositionInstruction(
			configuration: .init(
				backgroundColor: CGColor(gray: 0, alpha: 1),
				layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layerConfiguration)],
				timeRange: CMTimeRange(start: .zero, duration: try await asset.load(.duration))
			)
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
			height: comparisonHeight.rounded()
		)
		let outputPanelSize = CGSize(
			width: (comparisonHeight * outputAspect).rounded(),
			height: comparisonHeight.rounded()
		)
		let comparisonRenderSize = CGSize(
			width: originalPanelSize.width + outputPanelSize.width,
			height: comparisonHeight.rounded()
		)

		var leftLayerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: leftTrack)
		leftLayerConfiguration.setTransform(
			Self.aspectFittedTransform(
				sourceSize: analysis.sourceSize,
				destinationRect: CGRect(origin: .zero, size: originalPanelSize)
			),
			at: .zero
		)

		var rightLayerConfiguration = AVVideoCompositionLayerInstruction.Configuration(assetTrack: rightTrack)
		Self.configureReframingTransforms(
			&rightLayerConfiguration,
			shotStates: analysis.shotStates,
			sourceSize: analysis.sourceSize,
			renderSize: outputPanelSize,
			xOffset: originalPanelSize.width
		)
		Self.configureCropRectangles(
			&rightLayerConfiguration,
			shotStates: analysis.shotStates,
			sourceSize: analysis.sourceSize
		)

		let instruction = AVVideoCompositionInstruction(
			configuration: .init(
				backgroundColor: CGColor(gray: 0, alpha: 1),
				layerInstructions: [
					AVVideoCompositionLayerInstruction(configuration: rightLayerConfiguration),
					AVVideoCompositionLayerInstruction(configuration: leftLayerConfiguration),
				],
				timeRange: CMTimeRange(start: .zero, duration: try await asset.load(.duration))
			)
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

	@available(macOS 26, *)
	private static func configureReframingTransforms(
		_ configuration: inout AVVideoCompositionLayerInstruction.Configuration,
		shotStates: [FrameData<ShotState>],
		sourceSize: CGSize,
		renderSize: CGSize,
		xOffset: CGFloat = 0,
		yOffset: CGFloat = 0
	) {
		guard let firstState = shotStates.first else { return }

		configuration.setTransform(
			transform(for: firstState.value.bounds, sourceSize: sourceSize, renderSize: renderSize, xOffset: xOffset, yOffset: yOffset),
			at: .zero
		)

		for (from, to) in zip(shotStates, shotStates.dropFirst()) {
			let timeRange = CMTimeRange(start: from.presentationTime, end: to.presentationTime)
			guard timeRange.duration > .zero else { continue }

			configuration.addTransformRamp(
				.init(
					timeRange: timeRange,
					start: transform(
						for: from.value.bounds,
						sourceSize: sourceSize,
						renderSize: renderSize,
						xOffset: xOffset,
						yOffset: yOffset
					),
					end: transform(
						for: to.value.bounds,
						sourceSize: sourceSize,
						renderSize: renderSize,
						xOffset: xOffset,
						yOffset: yOffset
					)
				)
			)
		}
	}

	@available(macOS 26, *)
	private static func configureCropRectangles(
		_ configuration: inout AVVideoCompositionLayerInstruction.Configuration,
		shotStates: [FrameData<ShotState>],
		sourceSize: CGSize
	) {
		guard let firstState = shotStates.first else { return }

		configuration.setCropRectangle(videoSpaceRect(for: firstState.value.bounds, sourceSize: sourceSize), at: .zero)

		for (from, to) in zip(shotStates, shotStates.dropFirst()) {
			let timeRange = CMTimeRange(start: from.presentationTime, end: to.presentationTime)
			guard timeRange.duration > .zero else { continue }

			configuration.addCropRectangleRamp(
				.init(
					timeRange: timeRange,
					start: videoSpaceRect(for: from.value.bounds, sourceSize: sourceSize),
					end: videoSpaceRect(for: to.value.bounds, sourceSize: sourceSize)
				)
			)
		}
	}

	private static func transform(
		for bounds: CGRect,
		sourceSize: CGSize,
		renderSize: CGSize,
		xOffset: CGFloat = 0,
		yOffset: CGFloat = 0
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
			ty: yOffset - videoRect.minY * scaleY
		)
	}

	private static func videoSpaceRect(for bounds: CGRect, sourceSize: CGSize) -> CGRect {
		CGRect(
			x: bounds.minX,
			y: sourceSize.height - bounds.maxY,
			width: bounds.width,
			height: bounds.height
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
			ty: destinationRect.minY + (destinationRect.height - scaledSize.height) / 2
		)
	}

	private static func reframedImage(_ image: CIImage, cropRect: CGRect, renderSize: CGSize) -> CIImage {
		let cropped = image.cropped(to: cropRect)
		let translated = cropped.transformed(by: .init(translationX: -cropRect.minX, y: -cropRect.minY))
		let scaleTransform = CGAffineTransform(
			scaleX: renderSize.width / cropRect.width,
			y: renderSize.height / cropRect.height
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

	private static func primaryPose(in poses: [HumanBodyPoseObservation], sourceSize: CGSize) -> HumanBodyPoseObservation? {
		poses.max { lhs, rhs in
			boundingArea(for: lhs, sourceSize: sourceSize) < boundingArea(for: rhs, sourceSize: sourceSize)
		}
	}

	private static func boundingArea(for pose: HumanBodyPoseObservation, sourceSize: CGSize) -> CGFloat {
		let points = pose.allJoints().values.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) }
		let rect = CGRect.boundingRect(of: points)
		return rect.width * rect.height
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
			height: size.height + (other.size.height - size.height) * progress
		)
	}
}
