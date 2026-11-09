import CoreGraphics
import CoreMedia
import Testing
@testable import AutoFocusCore

struct MultiScenarioTrackingTests {
	@Test(
		arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)],
		[
			[1000.0, 1800, 1900, 2000, 2000],
			[2800.0, 2000, 1900, 1800, 1800],
			[1000.0, 1100, 1200, 2000, 2000],
			[2800.0, 2700, 2600, 1800, 1800],
		],
	)
	func changingWalkingSpeedKeepsFaceInsideCrop(outputSize: CGSize, xs: [Double]) async throws {
		// A fast first step followed by a slow continuation must not become
		// one averaged-speed pan that lets the face outrun the portrait crop.
		let states = try await track(xs: xs, outputSize: outputSize)
		for state in states {
			let center = try #require(state.value.subjectCenter)
			#expect(state.value.bounds.insetBy(dx: 90, dy: 90).contains(center))
		}
	}

	@Test(arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)])
	func walkReversalAndHeadDipsStayWithinNativeCrop(outputSize: CGSize) async throws {
		let states = try await track(
			xs: [1500, 1500, 2100, 2700, 2700, 2100, 1500, 1500],
			ys: [1620, 1560, 1620, 1660, 1600, 1620, 1560, 1620],
			outputSize: outputSize,
		)
		let sourceBounds = CGRect(x: 0, y: 0, width: 3840, height: 2160)
		for state in states {
			#expect(state.value.bounds.size == outputSize)
			#expect(sourceBounds.contains(state.value.bounds))
			#expect(try state.value.bounds.contains(#require(state.value.subjectCenter)))
		}
	}

	@Test(arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)])
	func emptyOpeningAcquiresSubjectAtObservedTime(outputSize: CGSize) async throws {
		let frames = [nil, nil, CGPoint(x: 3400, y: 1620), CGPoint(x: 2800, y: 1620), CGPoint(x: 2200, y: 1620)]
			.enumerated().map { index, center in
				FrameData<CGPoint?>(presentationTime: CMTime(value: Int64(index), timescale: 1), value: center)
			}
		let states = try await VideoReframer.trackSubjectCenters(
			frames,
			tracker: ShotTracker(sourceSize: CGSize(width: 3840, height: 2160), outputSize: outputSize),
			trackingInterval: CMTime(value: 1, timescale: 8),
		)
		#expect(states.filter { $0.presentationTime.seconds < 2 }.allSatisfy { $0.value.subjectCenter == nil })
		for state in states where state.presentationTime.seconds >= 2 {
			#expect(try state.value.bounds.contains(#require(state.value.subjectCenter)))
		}
	}

	private func track(xs: [Double], ys: [Double]? = nil, outputSize: CGSize) async throws -> [FrameData<ShotState>] {
		let points = xs.enumerated().map { index, x in CGPoint(x: x, y: ys?[index] ?? 1620) }
		return try await VideoReframer.trackSubjectCenters(
			points.enumerated().map { index, point in
				FrameData<CGPoint?>(presentationTime: CMTime(value: Int64(index), timescale: 1), value: point)
			},
			tracker: ShotTracker(sourceSize: CGSize(width: 3840, height: 2160), outputSize: outputSize),
			trackingInterval: CMTime(value: 1, timescale: 8),
			subjectCenterProvider: { time, _ in
				let index = min(Int(time.seconds), points.count - 2)
				let progress = time.seconds - Double(index)
				return CGPoint(
					x: points[index].x + (points[index + 1].x - points[index].x) * progress,
					y: points[index].y + (points[index + 1].y - points[index].y) * progress,
				)
			},
		)
	}
}
