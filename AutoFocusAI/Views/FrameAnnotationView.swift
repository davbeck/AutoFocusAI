import SwiftUI
import Vision

struct FrameAnnotationView: View {
	var poses: [HumanBodyPoseObservation]

	var body: some View {
		ZStack {
			ForEach(poses, id: \.uuid) { pose in
				BodyPoseView(pose: pose)
			}
		}
	}
}
