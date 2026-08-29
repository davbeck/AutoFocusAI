import SwiftUI

struct Inspector: View {
	@Bindable var coordinator: VideoCoordinator

	var body: some View {
		Form {
			Section("Output") {
				Picker("Resolution", selection: $coordinator.outputFormat) {
					ForEach(VideoCoordinator.OutputFormat.allCases) { format in
						Text(format.label)
							.tag(format)
					}
				}

				if coordinator.outputFormat == .custom {
					LabeledContent("Size") {
						HStack(spacing: 6) {
							TextField("Width", value: $coordinator.customOutputWidth, format: .number)
								.frame(width: 64)
								.multilineTextAlignment(.trailing)
								.accessibilityLabel("Custom output width")

							Text("×")
								.foregroundStyle(.secondary)

							TextField("Height", value: $coordinator.customOutputHeight, format: .number)
								.frame(width: 64)
								.multilineTextAlignment(.trailing)
								.accessibilityLabel("Custom output height")

							Text("px")
								.foregroundStyle(.secondary)
						}
					}
				}

				if let description = coordinator.resolvedOutputDescription {
					Text(description)
						.foregroundStyle(.secondary)
				}

				if let errorText = coordinator.outputSettingsErrorText {
					Text(errorText)
						.foregroundStyle(.red)
						.accessibilityLabel("Output settings error: \(errorText)")
				}

				Text("The crop is exported at its native pixel size without scaling.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.controlSize(.small)
		.disabled(coordinator.isExporting)
	}
}
