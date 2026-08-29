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
	static let targetAnchor = CGPoint(x: 0.5, y: 2.0 / 3.0)

	public let sourceSize: CGSize

	public let targetOutput: CGSize

	public var currentBounds: CGRect

	public var currentSpeed: CGPoint = .zero

	public var currentTime: CMTime?

	private var hasTrackedSubject = false

	public let springStiffness: CGFloat = 18

	public let dampingCoefficient: CGFloat = 6

	public let horizontalDeadZoneHalfWidthFactor: CGFloat = 0.1

	public let verticalDeadZoneHalfHeightFactor: CGFloat = 0.05

	public let maximumOriginTravelPerSecondFactor: CGFloat = 0.6

	private static let initialTrackingDelta = 1.0
	private static let maximumTrackingStepDuration = 1.0
	private static let maximumSpringStepDuration = 0.1

	public init(sourceSize: CGSize, outputSize: CGSize) {
		self.sourceSize = sourceSize
		self.targetOutput = outputSize

		self.currentBounds = CGRect(
			origin: .init(
				x: sourceSize.width / 2 - targetOutput.width / 2,
				y: sourceSize.height / 2 - targetOutput.height / 2,
			),
			size: targetOutput,
		)
	}

	public init(sourceSize: CGSize, aspectRatio: CGSize = ShotTracker.defaultAspectRatio) {
		self.init(sourceSize: sourceSize, outputSize: Self.cropSize(for: sourceSize, aspectRatio: aspectRatio))
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
		let currentTargetY = currentBounds.minY + targetOutput.height * Self.targetAnchor.y
		let deadZoneHalfWidth = targetOutput.width * horizontalDeadZoneHalfWidthFactor
		let horizontalOverflow = Self.deadZoneOverflow(
			offset: subjectCenter.x - currentTargetX,
			halfWidth: deadZoneHalfWidth,
		)
		let verticalOverflow = Self.deadZoneOverflow(
			offset: subjectCenter.y - currentTargetY,
			halfWidth: targetOutput.height * verticalDeadZoneHalfHeightFactor,
		)

		return CGPoint(
			x: currentBounds.origin.x + horizontalOverflow,
			y: currentBounds.origin.y + verticalOverflow,
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

	func subjectCenter(for pose: HumanBodyPoseObservation?) -> CGPoint? {
		guard let pose else { return nil }

		let facePoints = pose.allJoints(in: .face).values
			.filter { $0.confidence > 0.1 }
			.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) }
		let torsoPoints = pose.allJoints(in: .torso).values
			.filter { $0.confidence > 0.1 }
			.map { $0.location.toImageCoordinates(sourceSize, origin: .lowerLeft) }

		return Self.compositionAnchor(facePoints: facePoints, torsoPoints: torsoPoints)
	}

	func track(subjectCenter: CGPoint?, at compositionTime: CMTime) -> ShotState {
		guard let subjectCenter else {
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

		let desiredOrigin = clampedOrigin(self.desiredOrigin(for: subjectCenter))

		if !hasTrackedSubject {
			currentBounds.origin = desiredOrigin
			currentSpeed = .zero
			hasTrackedSubject = true
		} else if let deltaTime = trackingDelta(at: compositionTime) {
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

	public func track(_ pose: HumanBodyPoseObservation?, at compositionTime: CMTime) -> ShotState {
		track(subjectCenter: subjectCenter(for: pose), at: compositionTime)
	}

	static func compositionAnchor(
		facePoints: [CGPoint],
		torsoPoints: [CGPoint],
	) -> CGPoint? {
		let faceBounds = facePoints.isEmpty ? nil : CGRect.boundingRect(of: facePoints)
		let torsoBounds = torsoPoints.isEmpty ? nil : CGRect.boundingRect(of: torsoPoints)

		switch (faceBounds, torsoBounds) {
		case let (faceBounds?, torsoBounds?):
			return CGPoint(x: torsoBounds.midX, y: faceBounds.midY)
		case let (faceBounds?, nil):
			return CGPoint(x: faceBounds.midX, y: faceBounds.midY)
		case let (nil, torsoBounds?):
			return CGPoint(x: torsoBounds.midX, y: torsoBounds.midY)
		case (nil, nil):
			return nil
		}
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

		if deltaTime > Self.maximumSpringStepDuration {
			var position = position
			var velocity = velocity
			var remainingTime = deltaTime

			while remainingTime > 0 {
				let stepDuration = min(remainingTime, Self.maximumSpringStepDuration)
				let step = singleSpringStep(
					position: position,
					velocity: velocity,
					target: target,
					deltaTime: stepDuration,
					springStiffness: springStiffness,
					dampingCoefficient: dampingCoefficient,
					maximumTravelDistance: maximumTravelDistance.map {
						$0 * CGFloat(stepDuration / deltaTime)
					},
				)
				position = step.position
				velocity = step.velocity
				remainingTime -= stepDuration
			}

			return (position, velocity)
		}

		return singleSpringStep(
			position: position,
			velocity: velocity,
			target: target,
			deltaTime: deltaTime,
			springStiffness: springStiffness,
			dampingCoefficient: dampingCoefficient,
			maximumTravelDistance: maximumTravelDistance,
		)
	}

	private static func singleSpringStep(
		position: CGPoint,
		velocity: CGPoint,
		target: CGPoint?,
		deltaTime: Double,
		springStiffness: CGFloat,
		dampingCoefficient: CGFloat,
		maximumTravelDistance: CGFloat?,
	) -> (position: CGPoint, velocity: CGPoint) {
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
			.zero,
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
