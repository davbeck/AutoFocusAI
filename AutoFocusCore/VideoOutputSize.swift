import CoreGraphics
import Foundation

public enum VideoOutputSize: Hashable, Sendable {
	case maximum9By16
	case fixed(width: Int, height: Int)

	public static let fullHDLandscape = Self.fixed(width: 1920, height: 1080)
	public static let fullHDVertical = Self.fixed(width: 1080, height: 1920)

	public func validate() throws {
		guard case let .fixed(width, height) = self else { return }
		guard width > 0, height > 0, width.isMultiple(of: 2), height.isMultiple(of: 2) else {
			throw VideoReframerError.invalidOutputSize(width: width, height: height)
		}
	}

	public func resolve(for sourceSize: CGSize) throws -> CGSize {
		try validate()

		switch self {
		case .maximum9By16:
			return Self.maximumNativeCropSize(
				for: sourceSize,
				aspectRatio: ShotTracker.defaultAspectRatio,
			)
		case let .fixed(width, height):
			let outputSize = CGSize(width: width, height: height)
			guard outputSize.width <= sourceSize.width, outputSize.height <= sourceSize.height else {
				throw VideoReframerError.outputSizeExceedsSource(
					outputWidth: width,
					outputHeight: height,
					sourceWidth: Int(sourceSize.width.rounded()),
					sourceHeight: Int(sourceSize.height.rounded()),
				)
			}
			return outputSize
		}
	}

	static func maximumNativeCropSize(for sourceSize: CGSize, aspectRatio: CGSize) -> CGSize {
		guard
			sourceSize.width >= 2,
			sourceSize.height >= 2,
			aspectRatio.width > 0,
			aspectRatio.height > 0
		else {
			return .zero
		}

		let targetAspect = aspectRatio.width / aspectRatio.height
		let sourceAspect = sourceSize.width / sourceSize.height
		if sourceAspect > targetAspect {
			let height = evenPixelFloor(sourceSize.height)
			let width = nearestEvenPixel(height * targetAspect, maximum: sourceSize.width)
			return CGSize(width: width, height: height)
		} else {
			let width = evenPixelFloor(sourceSize.width)
			let height = nearestEvenPixel(width / targetAspect, maximum: sourceSize.height)
			return CGSize(width: width, height: height)
		}
	}

	private static func nearestEvenPixel(_ value: CGFloat, maximum: CGFloat) -> CGFloat {
		let lower = evenPixelFloor(value)
		let upper = lower + 2
		guard upper <= maximum, abs(upper - value) < abs(value - lower) else { return lower }
		return upper
	}

	private static func evenPixelFloor(_ value: CGFloat) -> CGFloat {
		max(2, floor(value / 2) * 2)
	}
}
