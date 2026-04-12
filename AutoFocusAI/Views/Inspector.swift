import SwiftUI

struct Inspector: View {
	var isProcessing: Bool

	var body: some View {
		ScrollView {}
			.disabled(isProcessing)
	}
}

#Preview {
	Inspector(isProcessing: false)
}
