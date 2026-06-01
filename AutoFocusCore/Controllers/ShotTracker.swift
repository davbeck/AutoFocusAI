import Foundation
import Vision

public struct ShotState: Sendable {
	public var bounds: CGRect
	public var target: CGRect
	public var subjectCenter: CGPoint?

	public init(bounds: CGRect, target: CGRect, subjectCenter: CGPoint?) {
		self.bounds = bounds
		self.target = target
		self.subjectCenter = subjectCenter
	}
}

public actor ShotTracker {
	public static let defaultAspectRatio = CGSize(width: 9, height: 16)
	static let targetAnchor = CGPoint(x: 0.5, y: 0.65)

	public let sourceSize: CGSize

	public let targetOutput: CGSize

	public var currentBounds: CGRect

	public var currentSpeed: CGPoint = .zero

	public var currentTime: CMTime?

	public let springStiffness: CGFloat = 18

	public let dampingCoefficient: CGFloat = 6

	public let horizontalDeadZoneHalfWidthFactor: CGFloat = 0.1

	public let maximumOriginTravelPerSecondFactor: CGFloat = 0.6

	private static let initialTrackingDelta = 1.0
	private static let maximumTrackingStepDuration = 1.0

	public init(sourceSize: CGSize, aspectRatio: CGSize = ShotTracker.defaultAspectRatio) {
		self.sourceSize = sourceSize
		self.targetOutput = Self.cropSize(for: sourceSize, aspectRatio: aspectRatio)

		self.currentBounds = CGRect(
			origin: .init(
				x: sourceSize.width / 2 - targetOutput.width / 2,
				y: sourceSize.height / 2 - targetOutput.height / 2,
			),
			size: targetOutput,
		)
	}

	public static func cropSize(for sourceSize: CGSize, aspectRatio: CGSize = ShotTracker.defaultAspectRatio) -> CGSize {
		guard
			sourceSize.width > 0,
			sourceSize.height > 0,
			aspectRatio.width > 0,
			aspectRatio.height > 0
		else {
			return .zero
		}

		let targetAspect = aspectRatio.width / aspectRatio.height
		let sourceAspect = sourceSize.width / sourceSize.height

		if sourceAspect > targetAspect {
			let height = sourceSize.height
			return CGSize(width: height * targetAspect, height: height)
		} else {
			let width = sourceSize.width
			return CGSize(width: width, height: width / targetAspect)
		}
	}

	private func target(for bounds: CGRect) -> CGRect {
		CGRect(
			origin: .init(
				x: bounds.minX + bounds.width * 0.15,
				y: bounds.minY + bounds.height * 0.4,
			),
			size: .init(
				width: bounds.width * 0.7,
				height: bounds.height * 0.5,
			),
		)
	}

	private func desiredOrigin(for subjectCenter: CGPoint) -> CGPoint {
		let currentTargetX = currentBounds.minX + targetOutput.width * Self.targetAnchor.x
		let deadZoneHalfWidth = targetOutput.width * horizontalDeadZoneHalfWidthFactor
		let horizontalOverflow = Self.deadZoneOverflow(
			offset: subjectCenter.x - currentTargetX,
			halfWidth: deadZoneHalfWidth,
		)

		return CGPoint(
			x: currentBounds.origin.x + horizontalOverflow,
			y: subjectCenter.y - targetOutput.height * Self.targetAnchor.y,
		)
	}

	private func clampedOrigin(_ origin: CGPoint) -> CGPoint {
		CGPoint(
			x: min(max(origin.x, 0), sourceSize.width - targetOutput.width),
			y: min(max(origin.y, 0), sourceSize.height - targetOutput.height),
		)
	}

	private func trackingDelta(at compositionTime: CMTime) -> Double? {
		guard let currentTime, compositionTime > currentTime else { return nil }
		return min(compositionTime.seconds - currentTime.seconds, Self.maximumTrackingStepDuration)
	}

	private func advanceTracking(target desiredOrigin: CGPoint?, deltaTime: Double) {
		let step = Self.springStep(
			position: currentBounds.origin,
			velocity: currentSpeed,
			target: desiredOrigin,
			deltaTime: deltaTime,
			springStiffness: springStiffness,
			dampingCoefficient: dampingCoefficient,
			maximumTravelDistance: targetOutput.width * maximumOriginTravelPerSecondFactor * CGFloat(deltaTime),
		)
		let origin = clampedOrigin(step.position)
		currentBounds.origin = origin
		currentSpeed = step.velocity
		if origin.x != step.position.x {
			currentSpeed.x = 0
		}
		if origin.y != step.position.y {
			currentSpeed.y = 0
		}
	}

	public func track(_ pose: HumanBodyPoseObservation?, at compositionTime: CMTime) -> ShotState {
		guard let pose else {
			if let deltaTime = trackingDelta(at: compositionTime) {
				advanceTracking(target: nil, deltaTime: deltaTime)
			}

			self.currentTime = compositionTime
			return ShotState(
				bounds: currentBounds,
				target: self.target(for: currentBounds),
				subjectCenter: nil,
			)
		}

		let faceJoints = Array(pose.allJoints(in: .face).values)
		let torsoJoints = Array(pose.allJoints(in: .torso).values)
		let joints = faceJoints + torsoJoints
		let targetBounds = self.target(for: currentBounds)

		var boundingRect = CGRect.boundingRect(
			of: joints.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) },
		)
		if boundingRect.size.width > targetBounds.size.width || boundingRect.size.height > targetBounds.size.height {
			boundingRect = CGRect.boundingRect(
				of: faceJoints.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) },
			)
		}

		let subjectCenter = CGPoint(x: boundingRect.midX, y: boundingRect.midY)
		let desiredOrigin = clampedOrigin(self.desiredOrigin(for: subjectCenter))

		if let deltaTime = trackingDelta(at: compositionTime) {
			advanceTracking(target: desiredOrigin, deltaTime: deltaTime)
		} else {
			advanceTracking(target: desiredOrigin, deltaTime: Self.initialTrackingDelta)
		}

		self.currentTime = compositionTime

		return ShotState(
			bounds: currentBounds,
			target: self.target(for: currentBounds),
			subjectCenter: subjectCenter,
		)
	}

	static func springStep(
		position: CGPoint,
		velocity: CGPoint,
		target: CGPoint?,
		deltaTime: Double,
		springStiffness: CGFloat,
		dampingCoefficient: CGFloat,
		maximumTravelDistance: CGFloat? = nil,
	) -> (position: CGPoint, velocity: CGPoint) {
		guard deltaTime > 0 else {
			return (position, velocity)
		}

		let deltaTime = CGFloat(deltaTime)
		let startPosition = position
		var acceleration = CGPoint(
			x: -velocity.x * dampingCoefficient,
			y: -velocity.y * dampingCoefficient,
		)

		if let target {
			acceleration.x += (target.x - position.x) * springStiffness
			acceleration.y += (target.y - position.y) * springStiffness
		}

		var velocity = velocity
		velocity.x += acceleration.x * deltaTime
		velocity.y += acceleration.y * deltaTime

		var position = position
		position.x += velocity.x * deltaTime
		position.y += velocity.y * deltaTime

		if let maximumTravelDistance {
			return limitedMovement(
				from: startPosition,
				to: position,
				velocity: velocity,
				deltaTime: deltaTime,
				maximumTravelDistance: maximumTravelDistance,
			)
		}

		return (position, velocity)
	}

	private static func limitedMovement(
		from startPosition: CGPoint,
		to proposedPosition: CGPoint,
		velocity: CGPoint,
		deltaTime: CGFloat,
		maximumTravelDistance: CGFloat,
	) -> (position: CGPoint, velocity: CGPoint) {
		guard maximumTravelDistance >= 0 else {
			return (proposedPosition, velocity)
		}

		let delta = CGPoint(
			x: proposedPosition.x - startPosition.x,
			y: proposedPosition.y - startPosition.y,
		)
		let distance = hypot(delta.x, delta.y)
		guard distance > maximumTravelDistance, distance > 0 else {
			return (proposedPosition, velocity)
		}

		let scale = maximumTravelDistance / distance
		let position = CGPoint(
			x: startPosition.x + delta.x * scale,
			y: startPosition.y + delta.y * scale,
		)
		return (
			position,
			CGPoint(
				x: (position.x - startPosition.x) / deltaTime,
				y: (position.y - startPosition.y) / deltaTime,
			)
		)
	}

	static func deadZoneOverflow(offset: CGFloat, halfWidth: CGFloat) -> CGFloat {
		guard abs(offset) > halfWidth else {
			return 0
		}

		if offset > 0 {
			return offset - halfWidth
		} else {
			return offset + halfWidth
		}
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
