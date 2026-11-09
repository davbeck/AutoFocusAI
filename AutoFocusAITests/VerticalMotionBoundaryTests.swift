import CoreGraphics
import CoreMedia
import Testing
@testable import AutoFocusCore

struct VerticalMotionBoundaryTests {
	@Test
	func unresolvedEndpointMovementRetainsItsObservationBracket() async throws {
		let movementTime = CMTime(value: 3, timescale: 1)
		let stationary = CGPoint(x: 1920, y: 1660)
		let moving = CGPoint(x: 1920, y: 1860)
		let frames: [FrameData<CGPoint?>] = [
			.init(presentationTime: .zero, value: stationary),
			.init(presentationTime: CMTime(value: 2, timescale: 1), value: stationary),
			.init(presentationTime: movementTime, value: moving),
			.init(presentationTime: CMTime(value: 4, timescale: 1), value: stationary),
		]
		let initialOrigin = CGPoint(x: 960, y: 940)
		let precision = CMTime(value: 1, timescale: 8)
		let plan = try await VideoReframer.cropMotionPlan(
			for: frames,
			tracker: ShotTracker(sourceSize: CGSize(width: 3840, height: 2160), outputSize: CGSize(width: 1920, height: 1080)),
			initialOrigin: initialOrigin,
			precision: precision,
			subjectCenterProvider: { time, _ in time < movementTime ? stationary : moving },
		)

		let pan = try #require(plan.animations.first)
		#expect(pan.endTime > pan.startTime)
		#expect(pan.startTime >= movementTime - precision)
		let beforeEnd = plan.origin(at: movementTime - CMTime(value: 1, timescale: 30))
		let end = plan.origin(at: movementTime)
		// At source cadence, the final observation must have an intermediate
		// crop position instead of moving the entire 90px in one video frame.
		#expect(beforeEnd.y > initialOrigin.y)
		#expect(beforeEnd.y < end.y)
	}
}
