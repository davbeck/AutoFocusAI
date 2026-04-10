import SwiftUI

struct Inspector: View {
	var isProcessing: Bool

	var body: some View {
		ScrollView {}
			.disabled(isProcessing)
			.overlay(alignment: .bottom) {
				if isProcessing {
					Text("Processing...")
						.foregroundStyle(.secondary)
						.padding()
				}
			}
	}
}

#Preview {
	Inspector(isProcessing: false)
}
