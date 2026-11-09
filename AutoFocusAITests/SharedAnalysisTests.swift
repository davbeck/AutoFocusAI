import CoreGraphics
import CoreMedia
import Testing
import Vision
@testable import AutoFocusCore

struct SharedAnalysisTests {
	private actor PoseRequests {
		var times: [CMTime] = []

		func frames(at times: [CMTime]) -> [FrameData<[HumanBodyPoseObservation]>] {
			self.times += times
			return times.filter { $0.seconds != 282 }.map {
				FrameData(presentationTime: $0 + CMTime(value: 1, timescale: 100), value: [])
			}
		}
	}

	@Test
	func sharedObservationsReuseRequestsAndPreserveActualSourceTimestamps() async throws {
		let requests = PoseRequests()
		let provider = SharedPoseFrameProvider { times in await requests.frames(at: times) }
		let times = [280, 281, 282].map { CMTime(seconds: Double($0), preferredTimescale: 600) }

		let first = try await provider.frames(at: times)
		let second = try await provider.frames(at: times.reversed())

		#expect(await requests.times == times)
		#expect(first.map(\.presentationTime.seconds) == [280.01, 281.01])
		#expect(second.map(\.presentationTime) == first.reversed().map(\.presentationTime))
		#expect(first.map(\.value.count) == [0, 0])
		#expect(await provider.statistics.requests == 3)
		#expect(await provider.statistics.reusedRequests == 3)
	}

	@Test
	func overlappingCropRequestsShareInFlightDetection() async throws {
		let requests = PoseRequests()
		let provider = SharedPoseFrameProvider { times in await requests.frames(at: times) }
		let time = CMTime(seconds: 301, preferredTimescale: 600)

		async let landscape = provider.frames(at: [time])
		async let portrait = provider.frames(at: [time])
		let (landscapeFrames, portraitFrames) = try await (landscape, portrait)

		#expect(await requests.times == [time])
		#expect(landscapeFrames.map(\.presentationTime) == portraitFrames.map(\.presentationTime))
	}

	@Test
	func cropShapesCalculateIndependentNativeBoundsOnSharedSourceTimeline() async throws {
		let centers = [(280.0, CGPoint(x: 1500, y: 1600)), (300.0, CGPoint(x: 2400, y: 1600)), (320.0, CGPoint(x: 1700, y: 1600))]
		let frames = centers.map { time, center in
			FrameData<CGPoint?>(presentationTime: CMTime(seconds: time, preferredTimescale: 600), value: center)
		}
		let sourceSize = CGSize(width: 3840, height: 2160)
		let landscapeSize = CGSize(width: 1920, height: 1080)
		let portraitSize = CGSize(width: 1080, height: 1920)
		let interval = CMTime(value: 1, timescale: 8)
		let landscape = try await VideoReframer.trackSubjectCenters(
			frames,
			tracker: ShotTracker(sourceSize: sourceSize, outputSize: landscapeSize),
			trackingInterval: interval,
		)
		let portrait = try await VideoReframer.trackSubjectCenters(
			frames,
			tracker: ShotTracker(sourceSize: sourceSize, outputSize: portraitSize),
			trackingInterval: interval,
		)

		#expect(landscape.map(\.presentationTime) == portrait.map(\.presentationTime))
		#expect(landscape.first?.presentationTime.seconds == 280)
		#expect(landscape.last?.presentationTime.seconds == 320)
		#expect(landscape.allSatisfy { $0.value.bounds.size == landscapeSize })
		#expect(portrait.allSatisfy { $0.value.bounds.size == portraitSize })
		#expect(landscape.map(\.value.bounds.origin) != portrait.map(\.value.bounds.origin))
	}
}
