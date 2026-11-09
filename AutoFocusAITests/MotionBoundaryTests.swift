import CoreGraphics
import CoreMedia
import Testing
@testable import AutoFocusCore

struct MotionBoundaryTests {
	@Test(arguments: [false, true])
	func panDoesNotExtendBackwardThroughStationaryJitter(withHeadMovement: Bool) async throws {
		let xs = [1500.0, 1501, 1502, 1503, 1504, 2300]
		let ys = withHeadMovement ? [1620.0, 1660, 1620, 1660, 1620, 1620] : [Double](repeating: 1620, count: xs.count)
		let frames = xs.enumerated().map { index, x in
			FrameData<CGPoint?>(
				presentationTime: CMTime(seconds: Double(index), preferredTimescale: 600),
				value: CGPoint(x: x, y: ys[index]),
			)
		}
		let states = try await VideoReframer.trackSubjectCenters(
			frames,
			tracker: ShotTracker(
				sourceSize: CGSize(width: 3840, height: 2160),
				outputSize: CGSize(width: 1080, height: 1920),
			),
			trackingInterval: CMTime(value: 1, timescale: 8),
			subjectCenterProvider: { time, _ in
				let index = max(0, min(xs.count - 2, Int(time.seconds)))
				let progress = time.seconds - Double(index)
				return CGPoint(
					x: xs[index] + (xs[index + 1] - xs[index]) * progress,
					y: ys[index] + (ys[index + 1] - ys[index]) * progress,
				)
			},
		)

		for state in states {
			let subject = try #require(state.value.subjectCenter)
			#expect(state.value.bounds.contains(subject))
		}
		#expect(states.filter { $0.presentationTime.seconds <= 4 }.allSatisfy {
			$0.value.bounds.minX == 960
		})
	}

	@Test(arguments: [false, true])
	func slowDeadZoneCrossingUsesPrecedingWalkForPan(withHeadMovement: Bool) async throws {
		// Rounded horizontal anchors measured in the November 8 sermon, with
		// an optional head dip. The speaker walks left, then only drifts
		// across the old crop's dead zone.
		let centers: [(Double, CGPoint)] = [
			(305, CGPoint(x: 2646, y: 1620)),
			(306, CGPoint(x: 2646, y: withHeadMovement ? 1557 : 1620)),
			(307, CGPoint(x: 2600, y: withHeadMovement ? 1635 : 1620)),
			(308, CGPoint(x: 2189, y: withHeadMovement ? 1653 : 1620)),
			(309, CGPoint(x: 2175, y: withHeadMovement ? 1655 : 1620)),
			(310, CGPoint(x: 2161, y: withHeadMovement ? 1611 : 1620)),
		]
		let frames = centers.map { time, center in
			FrameData<CGPoint?>(presentationTime: CMTime(seconds: time, preferredTimescale: 600), value: center)
		}
		let tracker = ShotTracker(
			sourceSize: CGSize(width: 3840, height: 2160),
			outputSize: CGSize(width: 1920, height: 1080),
		)
		let provider: VideoReframer.SubjectCenterProvider = { time, _ in
			let index = max(0, min(centers.count - 2, Int(time.seconds) - 305))
			let (startTime, start) = centers[index]
			let (_, end) = centers[index + 1]
			let progress = time.seconds - startTime
			return CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
		}
		let plan = try await VideoReframer.cropMotionPlan(
			for: frames,
			tracker: tracker,
			initialOrigin: CGPoint(x: 1686, y: 916),
			precision: CMTime(seconds: 0.125, preferredTimescale: 600),
			subjectCenterProvider: provider,
		)

		let animation = try #require(plan.animations.last)
		#expect(animation.endTime > animation.startTime)
		#expect(animation.startTime.seconds < 308)
		let origins = (0 ... 40).map { step in
			plan.origin(at: CMTime(seconds: 305 + Double(step) / 8, preferredTimescale: 600))
		}
		let maximumStep = zip(origins, origins.dropFirst()).map { abs($1.x - $0.x) }.max() ?? 0
		// The observed old path jumped about 480 source pixels in one 125ms
		// step. The pan should follow the measured walk over multiple seconds.
		#expect(maximumStep < 100)
	}
}
