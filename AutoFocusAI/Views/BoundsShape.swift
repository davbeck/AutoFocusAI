import SwiftUI
import Vision

struct BoundsShape: Shape {
	var bounds: CGRect
	var source: CGSize

	nonisolated func path(in rect: CGRect) -> Path {
		var path = Path()

		path.addRect(
			bounds
				.applying(
					CGAffineTransform.identity
						.scaledBy(x: rect.width / source.width, y: rect.height / source.height)
						.scaledBy(x: 1, y: -1)
						.translatedBy(x: 0, y: -source.height)
				)
		)

		return path
	}
}
