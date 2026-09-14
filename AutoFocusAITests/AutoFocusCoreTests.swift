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
	func maximum9By16UsesNativeSourcePixels() throws {
		let renderSize = try VideoOutputSize.maximum9By16.resolve(
			for: CGSize(width: 3840, height: 2160),
		)

		#expect(renderSize.width == 1214)
		#expect(renderSize.height == 2160)
	}

	@Test
	func maximum9By16RoundsToEvenPixelsWithoutScaling() throws {
		let renderSize = try VideoOutputSize.maximum9By16.resolve(
			for: CGSize(width: 1920, height: 1080),
		)

		#expect(renderSize.width == 608)
		#expect(renderSize.height == 1080)
	}

	@Test
	func fixedOutputUsesRequestedNativePixelSize() throws {
		let outputSize = try VideoOutputSize.fullHDLandscape.resolve(
			for: CGSize(width: 3840, height: 2160),
		)

		#expect(outputSize == CGSize(width: 1920, height: 1080))
	}

	@Test
	func fixedOutputCannotExceedSourceSize() {
		#expect(throws: VideoReframerError.self) {
			try VideoOutputSize.fullHDVertical.resolve(for: CGSize(width: 1920, height: 1080))
		}
	}

	@Test
	func fixedOutputRequiresEvenPixelDimensions() {
		#expect(throws: VideoReframerError.self) {
			try VideoOutputSize.fixed(width: 721, height: 1280).validate()
		}
	}

	@Test
	func oversizedOutputErrorExplainsAvailableRecovery() {
		let error = VideoReframerError.outputSizeExceedsSource(
			outputWidth: 1080,
			outputHeight: 1920,
			sourceWidth: 1920,
			sourceHeight: 1080,
		)

		#expect(error.errorDescription == "The 1080 × 1920 output is larger than the 1920 × 1080 source video.")
		#expect(error.recoverySuggestion == "Choose a smaller output size or use 9:16 Max.")
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
	func shotTrackerUsesTorsoCenterWhenFaceIsUnavailable() {
		let anchor = ShotTracker.compositionAnchor(
			facePoints: [],
			torsoPoints: [
				CGPoint(x: 10, y: 20),
				CGPoint(x: 210, y: 220),
			],
		)

		#expect(anchor == CGPoint(x: 110, y: 120))
	}

	@Test
	func shotTrackerUsesTorsoForHorizontalCompositionAndFaceForEyeLine() {
		let anchor = ShotTracker.compositionAnchor(
			facePoints: [
				CGPoint(x: 80, y: 90),
				CGPoint(x: 100, y: 110),
			],
			torsoPoints: [
				CGPoint(x: 10, y: 20),
				CGPoint(x: 210, y: 220),
			],
		)

		#expect(anchor == CGPoint(x: 110, y: 100))
	}

	@Test
	func tightCropKeepsSmallEyeLineChangesInsideVerticalDeadZone() async {
		let tracker = ShotTracker(
			sourceSize: CGSize(width: 3840, height: 2160),
			outputSize: CGSize(width: 1080, height: 1920),
		)
		let initialOrigin = await tracker.currentBounds.origin
		let initialAnchor = CGPoint(
			x: initialOrigin.x + 540,
			y: initialOrigin.y + 1280,
		)

		_ = await tracker.track(subjectCenter: initialAnchor, at: .zero)
		let state = await tracker.track(
			subjectCenter: CGPoint(x: initialAnchor.x, y: initialAnchor.y + 80),
			at: CMTime(seconds: 0.125, preferredTimescale: 600),
		)

		#expect(state.bounds.origin == initialOrigin)
	}

	@Test
	func tightCropStartsComposedAroundFirstDetectedSubject() async {
		let tracker = ShotTracker(
			sourceSize: CGSize(width: 3840, height: 2160),
			outputSize: CGSize(width: 720, height: 1280),
		)
		let subject = CGPoint(x: 610, y: 1674)

		let state = await tracker.track(subjectCenter: subject, at: .zero)

		#expect(state.bounds.contains(subject))
		#expect(subject.y - state.bounds.minY > state.bounds.height * 0.6)
		#expect(subject.y - state.bounds.minY < state.bounds.height * 0.75)
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
	func poseAnalysisDefaultsToOneFrameEveryFiveSeconds() {
		#expect(PoseVideoAnalysisConfiguration().maximumFramesPerSecond == 0.2)
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
	func cropKeyframesFileIncludesMultipleOutputConfigurations() throws {
		let timelineOrigin = CMTime(seconds: 4, preferredTimescale: 600)
		let timeRange = CMTimeRange(
			start: CMTime(seconds: 14, preferredTimescale: 600),
			end: CMTime(seconds: 24, preferredTimescale: 600),
		)
		let analyses = [
			ReframingAnalysis(
				sourceSize: CGSize(width: 3840, height: 2160),
				renderSize: CGSize(width: 1920, height: 1080),
				shotStates: [
					FrameData(
						presentationTime: CMTime(seconds: 14, preferredTimescale: 600),
						value: ShotState(
							bounds: CGRect(x: 120, y: 240, width: 1920, height: 1080),
							target: .zero,
							subjectCenter: nil,
						),
					),
				],
			),
			ReframingAnalysis(
				sourceSize: CGSize(width: 3840, height: 2160),
				renderSize: CGSize(width: 1080, height: 1920),
				shotStates: [
					FrameData(
						presentationTime: CMTime(seconds: 19, preferredTimescale: 600),
						value: ShotState(
							bounds: CGRect(x: 360, y: 120, width: 1080, height: 1920),
							target: .zero,
							subjectCenter: nil,
						),
					),
				],
			),
		]

		let file = CropKeyframesFile(
			analyses: analyses,
			timeRange: timeRange,
			timelineOrigin: timelineOrigin,
		)

		#expect(file.schemaVersion == 1)
		#expect(file.coordinateSystem == "source pixels, upper-left origin")
		#expect(file.sourceWidth == 3840)
		#expect(file.sourceHeight == 2160)
		#expect(file.timeRange.startTime == 10)
		#expect(file.timeRange.endTime == 20)
		#expect(file.configurations.count == 2)
		#expect(file.configurations[0].outputWidth == 1920)
		#expect(file.configurations[0].outputHeight == 1080)
		#expect(file.configurations[0].keyframes[0].timestamp == 10)
		#expect(file.configurations[0].keyframes[0].x == 120)
		#expect(file.configurations[0].keyframes[0].y == 840)
		#expect(file.configurations[1].outputWidth == 1080)
		#expect(file.configurations[1].outputHeight == 1920)
		#expect(file.configurations[1].keyframes[0].timestamp == 15)
		#expect(file.configurations[1].keyframes[0].y == 120)
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
		let target = CGPoint(x: 1030, y: 0)
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
				.init(index: 1, center: CGPoint(x: 900, y: 100), area: 1000),
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
				.init(index: 0, center: CGPoint(x: 900, y: 100), area: 1000),
			],
			preferredCenter: CGPoint(x: 100, y: 100),
			maximumDistance: 300,
		)

		#expect(index == nil)
	}

	@Test
	func poseSelectionAllowsMovementAcrossHorizontalCropDiagonal() {
		let index = VideoReframer.selectedPoseCandidateIndex(
			in: [
				.init(index: 0, center: CGPoint(x: 2079, y: 100), area: 1000),
			],
			preferredCenter: CGPoint(x: 100, y: 100),
			maximumDistance: VideoReframer.maximumSubjectJumpDistance(
				for: CGSize(width: 1920, height: 1080),
			),
		)

		#expect(index == 0)
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
	func trackShotStatesEmitsDenseSpringStatesBetweenPoseSamples() async throws {
		let tracker = ShotTracker(sourceSize: CGSize(width: 1920, height: 1080))
		let shotStates = try await VideoReframer.trackShotStates(
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
	func landscapeOpeningHoldsCompositionWhileSpeakerRaisesHead() async throws {
		let states = try await landscapeTracking([
			(0, CGPoint(x: 610, y: 1588)),
			(5, CGPoint(x: 936, y: 1674)),
		])
		let first = try #require(states.first)
		#expect(abs(first.value.bounds.minY - (1588 - 720)) < 0.01)
		#expect(states.allSatisfy { abs($0.value.bounds.minY - first.value.bounds.minY) < 0.01 })
	}

	@Test
	func landscapeAllowsSpeakerToMoveWithinMiddleHalfOfFrame() async throws {
		let states = try await landscapeTracking([
			(0, CGPoint(x: 1920, y: 1620)),
			(5, CGPoint(x: 2320, y: 1620)),
		])
		#expect(states.allSatisfy { abs($0.value.bounds.minX - 960) < 0.01 })
	}

	@Test
	func sparsePosesMoveAcrossTheirActualFiveSecondInterval() async throws {
		let states = try await landscapeTracking([
			(30, CGPoint(x: 2100, y: 1620)),
			(35, CGPoint(x: 1200, y: 1620)),
		])
		let at31 = try #require(states.first { abs($0.presentationTime.seconds - 31) < 0.01 })
		let at34 = try #require(states.first { abs($0.presentationTime.seconds - 34) < 0.01 })
		#expect(try abs(#require(at31.value.subjectCenter).x - 1920) < 0.01)
		#expect(try abs(#require(at34.value.subjectCenter).x - 1380) < 0.01)
		#expect(at31.value.bounds.minX - at34.value.bounds.minX > 100)
	}

	@Test
	func cropAnimationMatchesKeyframeSpeedThroughoutMovement() {
		let animation = VideoReframer.CropAnimation(
			startTime: CMTime(seconds: 4, preferredTimescale: 600),
			endTime: CMTime(seconds: 8, preferredTimescale: 600),
			startOrigin: CGPoint(x: 1600, y: 900),
			endOrigin: CGPoint(x: 400, y: 500),
		)

		// A speaker moving 300 px/s horizontally and 100 px/s vertically
		// should retain the same composition throughout the pan.
		for step in 0 ... 16 {
			let elapsed = Double(step) / 4
			let origin = animation.origin(at: CMTime(seconds: 4 + elapsed, preferredTimescale: 600))
			#expect(abs(origin.x - (1600 - 300 * elapsed)) < 0.01)
			#expect(abs(origin.y - (900 - 100 * elapsed)) < 0.01)
		}
		#expect(abs(animation.origin(at: .zero).x - 1600) < 0.01)
		#expect(abs(animation.origin(at: CMTime(seconds: 10, preferredTimescale: 600)).x - 400) < 0.01)
	}

	@Test
	func plannedFastPanKeepsUpWithSpeakerAndStopsWithThem() async throws {
		let states = try await landscapeTracking([
			(0, CGPoint(x: 1500, y: 1620)),
			(1, CGPoint(x: 2700, y: 1620)),
			(2, CGPoint(x: 2700, y: 1620)),
		])
		let early = try #require(states.first { abs($0.presentationTime.seconds - 0.25) < 0.01 })
		let late = try #require(states.first { abs($0.presentationTime.seconds - 0.75) < 0.01 })
		// Boundary refinement is accurate to one tracking interval. Even a fast
		// pan must follow the planned velocity without spring or easing lag.
		#expect(early.value.bounds.minX > 650)
		#expect(late.value.bounds.minX < 1450)
		#expect(states.filter { $0.presentationTime.seconds >= 1 }.allSatisfy {
			abs($0.value.bounds.minX - 1740) < 0.01
		})
	}

	@Test
	func cropAnimationStartsNearBeginningOfInterpolatedMovement() async throws {
		let tracker = ShotTracker(
			sourceSize: CGSize(width: 3840, height: 2160),
			outputSize: CGSize(width: 1920, height: 1080),
		)
		let plan = try await VideoReframer.cropMotionPlan(
			for: subjectFrames([
				(0, CGPoint(x: 1920, y: 1620)),
				(5, CGPoint(x: 2880, y: 1620)),
			]),
			tracker: tracker,
			initialOrigin: CGPoint(x: 960, y: 540),
			precision: CMTime(seconds: 0.125, preferredTimescale: 600),
		)

		let animation = try #require(plan.animations.first)
		#expect(plan.animations.count == 1)
		#expect(animation.startTime.seconds >= 0.0)
		#expect(animation.startTime.seconds <= 0.25)
		#expect(animation.endTime.seconds == 5)
		#expect(animation.startOrigin.x == 960)
		#expect(animation.endOrigin.x == 1920)
	}

	@Test
	func cropAnimationSpansContinuingMovementAndEndsAtFinalLocation() async throws {
		let tracker = ShotTracker(
			sourceSize: CGSize(width: 3840, height: 2160),
			outputSize: CGSize(width: 1920, height: 1080),
		)
		let plan = try await VideoReframer.cropMotionPlan(
			for: subjectFrames([
				(0, CGPoint(x: 1920, y: 1620)),
				(5, CGPoint(x: 2600, y: 1620)),
				(10, CGPoint(x: 3000, y: 1620)),
				(15, CGPoint(x: 3000, y: 1620)),
			]),
			tracker: tracker,
			initialOrigin: CGPoint(x: 960, y: 540),
			precision: CMTime(seconds: 0.125, preferredTimescale: 600),
		)

		let animation = try #require(plan.animations.first)
		#expect(plan.animations.count == 1)
		#expect(animation.endTime.seconds == 10)
		#expect(animation.endOrigin.x == 1920)

		let beforeBoundary = plan.origin(at: CMTime(seconds: 4.9, preferredTimescale: 600)).x
		let atBoundary = plan.origin(at: CMTime(seconds: 5, preferredTimescale: 600)).x
		let afterBoundary = plan.origin(at: CMTime(seconds: 5.1, preferredTimescale: 600)).x
		#expect(beforeBoundary < atBoundary)
		#expect(atBoundary < afterBoundary)
		#expect(abs((atBoundary - beforeBoundary) - (afterBoundary - atBoundary)) < 1)
	}

	@Test
	func cropAnimationRefinesMovementBoundariesFromVideoFrames() async throws {
		let tracker = ShotTracker(
			sourceSize: CGSize(width: 5000, height: 2160),
			outputSize: CGSize(width: 1920, height: 1080),
		)
		let plan = try await VideoReframer.cropMotionPlan(
			for: subjectFrames([
				(0, CGPoint(x: 1920, y: 1620)),
				(5, CGPoint(x: 2600, y: 1620)),
				(10, CGPoint(x: 3000, y: 1620)),
				(15, CGPoint(x: 3000, y: 1620)),
			]),
			tracker: tracker,
			initialOrigin: CGPoint(x: 1540, y: 540),
			precision: CMTime(seconds: 0.125, preferredTimescale: 600),
			subjectCenterProvider: { time, _ in
				let x = if time.seconds < 4 {
					1920.0
				} else if time.seconds < 5 {
					1920 + (time.seconds - 4) * 680
				} else if time.seconds < 8 {
					2600 + (time.seconds - 5) / 3 * 400
				} else {
					3000.0
				}
				return CGPoint(x: x, y: 1620)
			},
		)

		let animation = try #require(plan.animations.first)
		#expect(animation.startTime.seconds >= 4)
		#expect(animation.startTime.seconds <= 4.125)
		#expect(animation.endTime.seconds >= 7.75)
		#expect(animation.endTime.seconds <= 8)
	}

	@Test
	func landscapePanLeavesRoomForSubsequentSmallMovements() async throws {
		// Rounded composition anchors measured from TrackingExample.mov.
		let states = try await landscapeTracking([
			(0, CGPoint(x: 610, y: 1588)),
			(5, CGPoint(x: 936, y: 1674)),
			(10, CGPoint(x: 1932, y: 1646)),
			(15, CGPoint(x: 1935, y: 1626)),
			(20, CGPoint(x: 2107, y: 1638)),
		])
		let at15 = try #require(states.first { abs($0.presentationTime.seconds - 15) < 0.01 })
		#expect(states.filter { $0.presentationTime.seconds >= 15 }.allSatisfy {
			abs($0.value.bounds.minX - at15.value.bounds.minX) < 1
		})
	}

	@Test
	func missingPoseDoesNotAcquireFutureSubjectEarly() async throws {
		let states = try await landscapeTracking([
			(0, nil),
			(5, CGPoint(x: 610, y: 1588)),
			(10, nil),
		])
		#expect(states.filter { $0.presentationTime.seconds < 5 }.allSatisfy { $0.value.subjectCenter == nil })
		let at5 = try #require(states.first { abs($0.presentationTime.seconds - 5) < 0.01 })
		#expect(at5.value.subjectCenter != nil)
		let at10 = try #require(states.last)
		#expect(at10.value.subjectCenter == nil)
	}

	@Test
	func cropAnimationBridgesMissingPoseSample() async throws {
		let frames = subjectFrames([
			(80, CGPoint(x: 3326, y: 1638)),
			(85, nil),
			(90, CGPoint(x: 1479, y: 1555)),
			(95, CGPoint(x: 1802, y: 1754)),
		])
		let subjectCenterProvider: VideoReframer.SubjectCenterProvider = { time, _ in
			if time.seconds < 82 {
				return CGPoint(x: 3326, y: 1638)
			} else if time.seconds < 88 {
				return nil
			} else {
				return CGPoint(x: 1479, y: 1555)
			}
		}
		let plan = try await VideoReframer.cropMotionPlan(
			for: frames,
			tracker: ShotTracker(
				sourceSize: CGSize(width: 3840, height: 2160),
				outputSize: CGSize(width: 1920, height: 1080),
			),
			initialOrigin: CGPoint(x: 1920, y: 916),
			precision: CMTime(seconds: 0.125, preferredTimescale: 600),
			subjectCenterProvider: subjectCenterProvider,
		)

		let animation = try #require(plan.animations.first)
		#expect(animation.startTime.seconds >= 82)
		#expect(animation.startTime.seconds <= 82.125)
		#expect(animation.endTime.seconds >= 88)
		#expect(animation.endTime.seconds <= 88.125)
		#expect(plan.origin(at: CMTime(seconds: 83, preferredTimescale: 600)).x < 1920)

		let states = try await VideoReframer.trackSubjectCenters(
			frames,
			tracker: ShotTracker(
				sourceSize: CGSize(width: 3840, height: 2160),
				outputSize: CGSize(width: 1920, height: 1080),
			),
			trackingInterval: CMTime(seconds: 0.125, preferredTimescale: 600),
			subjectCenterProvider: subjectCenterProvider,
		)
		let at83 = try #require(states.first { $0.presentationTime.seconds >= 83 })
		let at85 = try #require(states.first { $0.presentationTime.seconds >= 85 })
		#expect(at83.value.bounds.minX < 1920)
		#expect(at85.value.bounds.minX < at83.value.bounds.minX)
	}

	@Test
	func landscapeHoldsVerticalFramingThroughBriefHeadDip() async throws {
		let states = try await landscapeTracking([
			(110, CGPoint(x: 1920, y: 1655)),
			(115, CGPoint(x: 1920, y: 1645)),
			(120, CGPoint(x: 1920, y: 1561)),
			(125, CGPoint(x: 1920, y: 1709)),
		])
		let first = try #require(states.first)
		#expect(states.allSatisfy { abs($0.value.bounds.minY - first.value.bounds.minY) < 0.01 })
	}

	private func landscapeTracking(_ centers: [(Double, CGPoint?)]) async throws -> [FrameData<ShotState>] {
		try await VideoReframer.trackSubjectCenters(
			subjectFrames(centers),
			tracker: ShotTracker(sourceSize: CGSize(width: 3840, height: 2160), outputSize: CGSize(width: 1920, height: 1080)),
			trackingInterval: CMTime(seconds: 0.125, preferredTimescale: 600),
		)
	}

	private func subjectFrames(_ centers: [(Double, CGPoint?)]) -> [FrameData<CGPoint?>] {
		centers.map { time, center in
			FrameData(presentationTime: CMTime(seconds: time, preferredTimescale: 600), value: center)
		}
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
