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
			transform: { $0.presentationTime }
		)?.value

		#expect(value == 20)
	}

	@Test
	func sampleIntervalCapsAnalysisRate() {
		let interval = VideoProcessor.sampleInterval(forNominalFrameRate: 30, maximumFramesPerSecond: 10)

		#expect(interval.seconds == 0.1)
	}
}
