import AutoFocusCore
import AVKit
import Observation
import SwiftUI

struct VideoView: View {
	var coordinator: VideoCoordinator

	var body: some View {
		@Bindable var coordinator = coordinator

		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Picker("View", selection: $coordinator.previewMode) {
					Text("Original")
						.tag(VideoCoordinator.PreviewMode.original)

					Text("Output")
						.selectionDisabled(!coordinator.hasComparisonPreview)
						.tag(VideoCoordinator.PreviewMode.output)

					Text("Both")
						.selectionDisabled(!coordinator.hasComparisonPreview)
						.tag(VideoCoordinator.PreviewMode.comparison)
				}
				.pickerStyle(.segmented)
				.labelsHidden()

				Spacer()

				if let progress = coordinator.processingProgress {
					HStack {
						Text(progress.stage.label)
							.font(.subheadline.weight(.medium))
							.foregroundStyle(.secondary)

						ProgressView(value: progress.fractionCompleted)
							.frame(maxWidth: 300)
					}
				}
			}

			if let errorText = coordinator.errorText {
				Text(errorText)
			}

			ZStack {
				VideoPlayer(player: coordinator.player)
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.onAppear { coordinator.play() }
		.onDisappear { coordinator.pause() }
	}
}
