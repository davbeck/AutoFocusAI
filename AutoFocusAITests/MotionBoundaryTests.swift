import CoreGraphics
import CoreMedia
import Testing
@testable import AutoFocusCore

struct MotionBoundaryTests {
	@Test
	func slowDeadZoneCrossingUsesPrecedingWalkForPan() async throws {
		// Rounded horizontal anchors measured in the November 8 sermon, with
		// a fixed eye line to isolate the pan. The speaker walks left, then
		// only drifts across the old crop's dead zone.
		let centers: [(Double, CGPoint)] = [
			(305, CGPoint(x: 2646, y: 1620)),
			(306, CGPoint(x: 2646, y: 1620)),
			(307, CGPoint(x: 2600, y: 1620)),
			(308, CGPoint(x: 2189, y: 1620)),
			(309, CGPoint(x: 2175, y: 1620)),
			(310, CGPoint(x: 2161, y: 1620)),
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
