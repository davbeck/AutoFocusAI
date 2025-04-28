import SwiftUI
import Vision

struct BodyPoseView: View {
	var pose: HumanBodyPoseObservation

	var body: some View {
		ZStack {
			ForEach(Array(pose.allJoints().values), id: \.jointName) { joint in
				JointShape(joint: joint)
					.fill(Color.blue.opacity(Double(joint.confidence)))
					.stroke(Color.white, lineWidth: 1)
			}
		}
	}
}

struct JointShape: Shape {
	var joint: Joint

	nonisolated func path(in rect: CGRect) -> Path {
		var path = Path()

		path.addArc(
			center: joint.location.toImageCoordinates(rect.size, origin: .upperLeft),
			radius: 3,
			startAngle: .degrees(0),
			endAngle: .degrees(360),
			clockwise: true
		)

		return path
	}
}
