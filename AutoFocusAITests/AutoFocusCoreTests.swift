import CoreGraphics
import CoreMedia
import Testing
import Vision
@testable import AutoFocusCore

struct AutoFocusCoreTests {
	@Test
	func cropSizeForLandscapeSourceFitsInsideFrame() {
		let cropSize = ShotTracker.cropSize(for: CGSize(width: 1920, height: 1080))

		#expect(cropSize.width == 607.5)
		#expect(cropSize.height == 1080)
	}

	@Test
	func renderSizeUsesNativeSourcePixelsForTargetAspectRatio() {
		let renderSize = VideoReframer.renderSize(
			for: CGSize(width: 3840, height: 2160),
			aspectRatio: ShotTracker.defaultAspectRatio,
		)

		#expect(renderSize.width == 1215)
		#expect(renderSize.height == 2160)
	}

	@Test
	func renderSizeRoundsFractionalCropPixels() {
		let renderSize = VideoReframer.renderSize(
			for: CGSize(width: 1920, height: 1080),
			aspectRatio: ShotTracker.defaultAspectRatio,
		)

		#expect(renderSize.width == 608)
		#expect(renderSize.height == 1080)
	}

	@Test
	func shotTrackerStartsCenteredAndClamped() async {
		let tracker = ShotTracker(sourceSize: CGSize(width: 1920, height: 1080))
		let bounds = await tracker.currentBounds

		#expect(bounds.minX == 656.25)
		#expect(bounds.minY == 0)
		#expect(bounds.maxX == 1263.75)
		#expect(bounds.maxY == 1080)
	}

	@Test
	func shotTrackerUsesTorsoBoundsWhenOversizedPoseHasNoFaceJoints() {
		let bounds = ShotTracker.subjectBoundingRect(
			facePoints: [],
			torsoPoints: [
				CGPoint(x: 10, y: 20),
				CGPoint(x: 210, y: 220),
			],
			targetBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
		)

		#expect(bounds == CGRect(x: 10, y: 20, width: 200, height: 200))
	}

	@Test
	func shotTrackerUsesFaceBoundsWhenOversizedPoseHasFaceJoints() {
		let bounds = ShotTracker.subjectBoundingRect(
			facePoints: [
				CGPoint(x: 80, y: 90),
				CGPoint(x: 100, y: 110),
			],
			torsoPoints: [
				CGPoint(x: 10, y: 20),
				CGPoint(x: 210, y: 220),
			],
			targetBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
		)

		#expect(bounds == CGRect(x: 80, y: 90, width: 20, height: 20))
	}

	@Test
	func valueAtOrBeforeReturnsNearestPreviousFrame() {
		let frames = [
			FrameData(presentationTime: CMTime(seconds: 1, preferredTimescale: 600), value: 10),
			FrameData(presentationTime: CMTime(seconds: 2, preferredTimescale: 600), value: 20),
			FrameData(presentationTime: CMTime(seconds: 3, preferredTimescale: 600), value: 30),
		]

		let value = frames.value(
			atOrBefore: CMTime(seconds: 2.5, preferredTimescale: 600),
			transform: { $0.presentationTime },
		)?.value

		#expect(value == 20)
	}

	@Test
	func sampleIntervalCapsAnalysisRate() {
		let interval = PoseVideoAnalyzer.sampleInterval(forNominalFrameRate: 30, maximumFramesPerSecond: 10)

		#expect(interval.seconds == 0.1)
	}

	@Test
	func sampleIntervalFallsBackToConfiguredMaximumWhenTrackRateIsUnknown() {
		let interval = PoseVideoAnalyzer.sampleInterval(forNominalFrameRate: 0, maximumFramesPerSecond: 8)

		#expect(interval.seconds == 0.125)
	}

	@Test
	func requestedTimesStartAtVideoTrackStart() {
		let start = CMTime(seconds: 0.123333, preferredTimescale: 600_000)
		let sampleInterval = CMTime(seconds: 1, preferredTimescale: 600)
		let times = PoseVideoAnalyzer.requestedTimes(
			for: CMTimeRange(
				start: start,
				duration: CMTime(seconds: 3, preferredTimescale: 600),
			),
			sampleInterval: sampleInterval,
		)

		#expect(times == [
			start,
			start + sampleInterval,
			start + sampleInterval + sampleInterval,
		])
	}

	@Test
	func requestedTimesStayInsideSelectedRange() throws {
		let availableTimeRange = CMTimeRange(
			start: .zero,
			duration: CMTime(seconds: 30, preferredTimescale: 600),
		)
		let selectedTimeRange = CMTimeRange(
			start: CMTime(seconds: 10, preferredTimescale: 600),
			end: CMTime(seconds: 22, preferredTimescale: 600),
		)
		let resolvedTimeRange = try PoseVideoAnalyzer.resolvedTimeRange(
			availableTimeRange: availableTimeRange,
			requestedTimeRange: selectedTimeRange,
		)
		let times = PoseVideoAnalyzer.requestedTimes(
			for: resolvedTimeRange,
			sampleInterval: CMTime(seconds: 5, preferredTimescale: 600),
		)

		#expect(resolvedTimeRange == selectedTimeRange)
		#expect(times.map(\.seconds) == [10, 15, 20])
	}

	@Test
	func automaticFrameSelectionUsesIndividualFramesForSparseSamples() {
		let strategy = PoseVideoAnalyzer.resolvedFrameSelectionStrategy(
			.automatic,
			requestedFrameCount: 100,
			sampleInterval: CMTime(seconds: 5, preferredTimescale: 600),
			nominalFrameRate: 30,
		)

		#expect(strategy == .individualFrames)
	}

	@Test
	func automaticFrameSelectionUsesReaderForDenseSamples() {
		let strategy = PoseVideoAnalyzer.resolvedFrameSelectionStrategy(
			.automatic,
			requestedFrameCount: 100,
			sampleInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
			nominalFrameRate: 30,
		)

		#expect(strategy == .sequentialReader)
	}

	@Test
	func automaticFrameSelectionAvoidsReaderSetupForShortRanges() {
		let strategy = PoseVideoAnalyzer.resolvedFrameSelectionStrategy(
			.automatic,
			requestedFrameCount: 10,
			sampleInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
			nominalFrameRate: 30,
		)

		#expect(strategy == .individualFrames)
	}

	@Test
	func poseAnalysisDefaultsToOneFramePerSecond() {
		#expect(PoseVideoAnalysisConfiguration().maximumFramesPerSecond == 1)
	}

	@Test
	func poseDataFileUsesVideoRelativeTimestamps() {
		let timelineOrigin = CMTime(seconds: 4, preferredTimescale: 600)
		let timeRange = CMTimeRange(
			start: CMTime(seconds: 14, preferredTimescale: 600),
			end: CMTime(seconds: 24, preferredTimescale: 600),
		)
		let file = PoseDataFile(
			frames: [],
			timeRange: timeRange,
			timelineOrigin: timelineOrigin,
			sampleInterval: 5,
		)

		#expect(file.schemaVersion == 1)
		#expect(file.sampleInterval == 5)
		#expect(file.timeRange.startTime == 10)
		#expect(file.timeRange.endTime == 20)
	}

	@Test
	func reframingTracksSpringAtEightFramesPerSecondByDefault() {
		#expect(ReframingConfiguration().trackingFramesPerSecond == 8)
		#expect(VideoReframer.trackingInterval(forFramesPerSecond: 8).seconds == 0.125)
	}

	@Test
	func detectionSizeDownscalesLongEdgePreservingAspectRatio() {
		let size = PoseVideoAnalyzer.detectionSize(
			for: CGSize(width: 1920, height: 1080),
			maximumLongEdge: 720,
		)

		#expect(size.width == 720)
		#expect(size.height == 405)
	}

	@Test
	func detectionSizeDoesNotUpscaleSmallerFrames() {
		let size = PoseVideoAnalyzer.detectionSize(
			for: CGSize(width: 640, height: 360),
			maximumLongEdge: 720,
		)

		#expect(size.width == 640)
		#expect(size.height == 360)
	}

	@Test
	func shotTrackerSpringStepKeepsMovingTowardTarget() {
		let dampingCoefficient: CGFloat = 6

		let firstStep = ShotTracker.springStep(
			position: .zero,
			velocity: .zero,
			target: CGPoint(x: 120, y: 0),
			deltaTime: 0.1,
			springStiffness: 18,
			dampingCoefficient: dampingCoefficient,
		)
		let secondStep = ShotTracker.springStep(
			position: firstStep.position,
			velocity: firstStep.velocity,
			target: CGPoint(x: 120, y: 0),
			deltaTime: 0.1,
			springStiffness: 18,
			dampingCoefficient: dampingCoefficient,
		)

		#expect(firstStep.position.x > 0)
		#expect(secondStep.position.x > firstStep.position.x)
		#expect(secondStep.velocity.x > 0)
	}

	@Test
	func shotTrackerSpringStepCoastsWhenTargetDisappears() {
		let dampingCoefficient: CGFloat = 6

		let step = ShotTracker.springStep(
			position: .zero,
			velocity: CGPoint(x: 100, y: 0),
			target: nil,
			deltaTime: 0.1,
			springStiffness: 18,
			dampingCoefficient: dampingCoefficient,
		)

		#expect(step.position.x > 0)
		#expect(step.velocity.x > 0)
		#expect(step.velocity.x < 100)
	}

	@Test
	func shotTrackerSpringStepLimitsSparseSampleMovement() {
		let step = ShotTracker.springStep(
			position: CGPoint(x: 1312.5, y: 0),
			velocity: .zero,
			target: CGPoint(x: 0, y: 0),
			deltaTime: 1,
			springStiffness: 18,
			dampingCoefficient: 6,
			maximumTravelDistance: 729,
		)

		#expect(step.position.x >= 583.49)
		#expect(step.position.x < 1312.5)
		#expect(step.position.y == 0)
		#expect(step.velocity.y == 0)
	}

	@Test
	func shotTrackerSpringStepDoesNotLimitSmallMovement() {
		let unrestrictedStep = ShotTracker.springStep(
			position: .zero,
			velocity: .zero,
			target: CGPoint(x: 120, y: 0),
			deltaTime: 0.1,
			springStiffness: 18,
			dampingCoefficient: 6,
		)
		let limitedStep = ShotTracker.springStep(
			position: .zero,
			velocity: .zero,
			target: CGPoint(x: 120, y: 0),
			deltaTime: 0.1,
			springStiffness: 18,
			dampingCoefficient: 6,
			maximumTravelDistance: 100,
		)

		#expect(limitedStep.position == unrestrictedStep.position)
		#expect(limitedStep.velocity == unrestrictedStep.velocity)
	}

	@Test
	func shotTrackerSpringStepDoesNotOscillateOnSparseSamples() {
		let target = CGPoint(x: 1_030, y: 0)
		let firstStep = ShotTracker.springStep(
			position: CGPoint(x: 794.4, y: 0),
			velocity: .zero,
			target: target,
			deltaTime: 0.933,
			springStiffness: 18,
			dampingCoefficient: 6,
			maximumTravelDistance: 680.4,
		)
		let secondStep = ShotTracker.springStep(
			position: firstStep.position,
			velocity: firstStep.velocity,
			target: target,
			deltaTime: 0.933,
			springStiffness: 18,
			dampingCoefficient: 6,
			maximumTravelDistance: 680.4,
		)

		#expect(firstStep.position.x > 794.4)
		#expect(abs(firstStep.position.x - target.x) < 1)
		#expect(abs(secondStep.position.x - target.x) < abs(firstStep.position.x - target.x))
	}

	@Test
	func shotTrackerDeadZoneIgnoresSmallHorizontalOffsets() {
		#expect(ShotTracker.deadZoneOverflow(offset: 40, halfWidth: 60) == 0)
		#expect(ShotTracker.deadZoneOverflow(offset: 120, halfWidth: 60) == 60)
		#expect(ShotTracker.deadZoneOverflow(offset: -120, halfWidth: 60) == -60)
	}

	@Test
	func poseSelectionStartsWithLargestCandidate() {
		let index = VideoReframer.selectedPoseCandidateIndex(
			in: [
				.init(index: 0, center: CGPoint(x: 100, y: 100), area: 100),
				.init(index: 1, center: CGPoint(x: 900, y: 100), area: 200),
			],
			preferredCenter: nil,
			maximumDistance: nil,
		)

		#expect(index == 1)
	}

	@Test
	func poseSelectionPrefersContinuityOverLargerDistantCandidate() {
		let index = VideoReframer.selectedPoseCandidateIndex(
			in: [
				.init(index: 0, center: CGPoint(x: 110, y: 100), area: 100),
				.init(index: 1, center: CGPoint(x: 900, y: 100), area: 1_000),
			],
			preferredCenter: CGPoint(x: 100, y: 100),
			maximumDistance: 300,
		)

		#expect(index == 0)
	}

	@Test
	func poseSelectionRejectsImplausibleContinuityJump() {
		let index = VideoReframer.selectedPoseCandidateIndex(
			in: [
				.init(index: 0, center: CGPoint(x: 900, y: 100), area: 1_000),
			],
			preferredCenter: CGPoint(x: 100, y: 100),
			maximumDistance: 300,
		)

		#expect(index == nil)
	}

	@Test
	func reframingAnalysisInterpolatesBoundsBetweenTrackedFrames() {
		let analysis = ReframingAnalysis(
			sourceSize: CGSize(width: 1920, height: 1080),
			renderSize: CGSize(width: 1080, height: 1920),
			shotStates: [
				FrameData(
					presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
					value: ShotState(
						bounds: CGRect(x: 100, y: 200, width: 600, height: 1080),
						target: .zero,
						subjectCenter: nil,
					),
				),
				FrameData(
					presentationTime: CMTime(seconds: 2, preferredTimescale: 600),
					value: ShotState(
						bounds: CGRect(x: 220, y: 260, width: 600, height: 1080),
						target: .zero,
						subjectCenter: nil,
					),
				),
			],
		)

		let bounds = analysis.interpolatedBounds(at: CMTime(seconds: 1.25, preferredTimescale: 600))

		#expect(bounds?.origin.x == 130)
		#expect(bounds?.origin.y == 215)
		#expect(bounds?.width == 600)
		#expect(bounds?.height == 1080)
	}

	@Test
	func previewAnalysisLeavesShortTimelinesUnchanged() {
		let shotStates = [
			FrameData(
				presentationTime: CMTime(seconds: 0, preferredTimescale: 600),
				value: ShotState(bounds: CGRect(x: 10, y: 0, width: 600, height: 1080), target: .zero, subjectCenter: nil),
			),
			FrameData(
				presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
				value: ShotState(bounds: CGRect(x: 20, y: 0, width: 600, height: 1080), target: .zero, subjectCenter: nil),
			),
			FrameData(
				presentationTime: CMTime(seconds: 2, preferredTimescale: 600),
				value: ShotState(bounds: CGRect(x: 30, y: 0, width: 600, height: 1080), target: .zero, subjectCenter: nil),
			),
		]
		let analysis = ReframingAnalysis(
			sourceSize: CGSize(width: 1920, height: 1080),
			renderSize: CGSize(width: 1080, height: 1920),
			shotStates: shotStates,
		)

		let previewAnalysis = analysis.previewAnalysis(maximumShotStateCount: 10)

		#expect(previewAnalysis.shotStates.count == shotStates.count)
		#expect(previewAnalysis.shotStates.map(\.presentationTime) == shotStates.map(\.presentationTime))
	}

	@Test
	func previewAnalysisCapsLongTimelinesPreservingEndpoints() {
		let shotStates = (0 ..< 10).map { index in
			FrameData(
				presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
				value: ShotState(
					bounds: CGRect(x: CGFloat(index * 10), y: 0, width: 600, height: 1080),
					target: .zero,
					subjectCenter: nil,
				),
			)
		}
		let analysis = ReframingAnalysis(
			sourceSize: CGSize(width: 1920, height: 1080),
			renderSize: CGSize(width: 1080, height: 1920),
			shotStates: shotStates,
		)

		let previewAnalysis = analysis.previewAnalysis(maximumShotStateCount: 4)

		#expect(previewAnalysis.shotStates.count == 4)
		#expect(previewAnalysis.shotStates.first?.presentationTime == shotStates.first?.presentationTime)
		#expect(previewAnalysis.shotStates.last?.presentationTime == shotStates.last?.presentationTime)
		#expect(previewAnalysis.shotStates.map(\.presentationTime.seconds) == [0, 3, 6, 9])
	}

	@Test
	func trackingTimesFillPoseSampleIntervalAtTrackingCadence() {
		let times = VideoReframer.trackingTimes(
			from: CMTime(seconds: 0, preferredTimescale: 600),
			to: CMTime(seconds: 1, preferredTimescale: 600),
			interval: CMTime(seconds: 0.25, preferredTimescale: 600),
		)

		#expect(times.map(\.seconds) == [0.25, 0.5, 0.75, 1])
	}

	@Test
	func trackShotStatesEmitsDenseSpringStatesBetweenPoseSamples() async {
		let tracker = ShotTracker(sourceSize: CGSize(width: 1920, height: 1080))
		let shotStates = await VideoReframer.trackShotStates(
			[
				FrameData<HumanBodyPoseObservation?>(
					presentationTime: CMTime(seconds: 0, preferredTimescale: 600),
					value: nil,
				),
				FrameData<HumanBodyPoseObservation?>(
					presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
					value: nil,
				),
			],
			tracker: tracker,
			trackingInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
		)

		#expect(shotStates.map(\.presentationTime.seconds) == [0, 0.25, 0.5, 0.75, 1])
	}

	@Test
	func transitionSegmentsUseSingleLinearRampBetweenDenseSpringStates() {
		let from = FrameData(
			presentationTime: CMTime(seconds: 1, preferredTimescale: 600),
			value: ShotState(
				bounds: CGRect(x: 100, y: 0, width: 600, height: 1080),
				target: .zero,
				subjectCenter: nil,
			),
		)
		let to = FrameData(
			presentationTime: CMTime(seconds: 1.125, preferredTimescale: 600),
			value: ShotState(
				bounds: CGRect(x: 130, y: 0, width: 600, height: 1080),
				target: .zero,
				subjectCenter: nil,
			),
		)

		let segments = VideoReframer.transitionSegments(from: from, to: to)

		#expect(segments.count == 1)
		#expect(segments.first?.startTime == from.presentationTime)
		#expect(segments.first?.endTime == to.presentationTime)
		#expect(segments.first?.startBounds == from.value.bounds)
		#expect(segments.first?.endBounds == to.value.bounds)
	}
}
