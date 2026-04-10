import SwiftUI

struct DropTargetView: View {
	@State private var phase = 0.0

	var body: some View {
		VStack(spacing: 10) {
			Image(systemName: "movieclapper")
				.imageScale(.large)
				.padding(30)
				.font(.title)
				.background {
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.stroke(
							Color.gray.opacity(0.5),
							style: .init(
								lineWidth: 3,
								lineCap: .round,
								dash: [15, 10],
								dashPhase: phase
							)
						)
				}

			Text("Drop video")
				.font(.headline)
		}
		.foregroundStyle(.secondary)
		.padding()
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onAppear {
			withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
				phase -= 25
			}
		}
	}
}

#Preview {
	DropTargetView()
}
