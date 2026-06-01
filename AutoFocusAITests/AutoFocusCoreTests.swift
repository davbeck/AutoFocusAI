import CoreGraphics
import CoreMedia
import Testing
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
	func poseAnalysisDefaultsToOneFramePerSecond() {
		#expect(PoseVideoAnalysisConfiguration().maximumFramesPerSecond == 1)
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
	func shotTrackerDeadZoneIgnoresSmallHorizontalOffsets() {
		#expect(ShotTracker.deadZoneOverflow(offset: 40, halfWidth: 60) == 0)
		#expect(ShotTracker.deadZoneOverflow(offset: 120, halfWidth: 60) == 60)
		#expect(ShotTracker.deadZoneOverflow(offset: -120, halfWidth: 60) == -60)
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
	func easedProgressStartsAndEndsSmoothly() {
		#expect(VideoReframer.easedProgress(0) == 0)
		#expect(VideoReframer.easedProgress(0.5) == 0.5)
		#expect(VideoReframer.easedProgress(1) == 1)
		#expect(VideoReframer.easedProgress(0.25) < 0.25)
		#expect(VideoReframer.easedProgress(0.75) > 0.75)
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
}
