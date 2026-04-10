import Foundation
import Vision

struct ShotState: Sendable {
	var bounds: CGRect
	var target: CGRect

	var pose: HumanBodyPoseObservation?
}

actor ShotTracker {
	let sourceSize: CGSize

	let targetOutput: CGSize = .init(width: 1080, height: 1920)

	var currentBounds: CGRect

	var currentSpeed: CGPoint = .zero

	var currentTime: CMTime?

	let mass: CGFloat = 0.005

	let damping: CGFloat = 0.01

	init(sourceSize: CGSize) {
		self.sourceSize = sourceSize

		self.currentBounds = CGRect(
			origin: .init(
				x: sourceSize.width / 2 - targetOutput.width / 2,
				y: sourceSize.height / 2 - targetOutput.height / 2
			),
			size: targetOutput
		)
	}

	private func target(for bounds: CGRect) -> CGRect {
		CGRect(
			origin: .init(
				x: bounds.minX + bounds.width * 0.15,
				y: bounds.minY + bounds.height * 0.4,
			),
			size: .init(
				width: bounds.width * 0.7,
				height: bounds.height * 0.5
			)
		)
	}

	func track(_ pose: HumanBodyPoseObservation, at compositionTime: CMTime) -> ShotState {
		let targetBounds = self.target(for: currentBounds)

		let faceJoints = Array(pose.allJoints(in: .face).values)
		let torsoJoints = Array(pose.allJoints(in: .torso).values)
		let joints = faceJoints + torsoJoints

		var boundingRect = CGRect.boundingRect(
			of: joints.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) }
		)
		if boundingRect.size.width > targetBounds.size.width || boundingRect.size.height > targetBounds.size.height {
			boundingRect = CGRect.boundingRect(
				of: faceJoints.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) }
			)
		}

		if let currentTime, compositionTime > currentTime, compositionTime.seconds - currentTime.seconds < 1 {
			let forceRightX = max(boundingRect.maxX - targetBounds.maxX, 0)
			let forceLeftX = min(boundingRect.minX - targetBounds.minX, 0)
			let forceX = forceRightX + forceLeftX

			let forceRightY = max(boundingRect.maxY - targetBounds.maxY, 0)
			let forceLeftY = min(boundingRect.minY - targetBounds.minY, 0)
			let forceY = forceRightY + forceLeftY

			let deltaTime = compositionTime.seconds - currentTime.seconds
			let damping = pow(self.damping, deltaTime)
			currentSpeed.x += (forceX / mass) * deltaTime
			currentSpeed.y += (forceY / mass) * deltaTime

			currentBounds.origin.x += currentSpeed.x * deltaTime
			currentBounds.origin.y += currentSpeed.y * deltaTime

			currentSpeed.x *= damping
			currentSpeed.y *= damping

			// this is working fairly well but...

			// what if it was more like a rubber band pulling to the center
			// have a minimum distance before the camera starts moving, but once it does
			// keep pulling it towards the center of the current position
		} else {
			currentBounds.origin.x -= targetBounds.midX - boundingRect.midX
			currentBounds.origin.y -= targetBounds.midY - boundingRect.midY
		}

		if currentBounds.origin.x < 0 {
			currentBounds.origin.x = 0
		}
		if currentBounds.origin.y < 0 {
			currentBounds.origin.y = 0
		}

		self.currentTime = compositionTime

		return ShotState(
			bounds: currentBounds,
			target: self.target(for: currentBounds),
			pose: pose
		)
	}
}

extension CGRect {
	static func boundingRect(of points: [CGPoint]) -> CGRect {
		guard let first = points.first else {
			return .zero
		}

		var minX = first.x
		var minY = first.y
		var maxX = first.x
		var maxY = first.y

		for point in points.dropFirst() {
			minX = min(minX, point.x)
			minY = min(minY, point.y)
			maxX = max(maxX, point.x)
			maxY = max(maxY, point.y)
		}

		return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
	}
}
