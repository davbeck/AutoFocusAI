import AVKit
import SwiftUI

struct VideoView: View {
	var coordinator: VideoCoordinator

	var body: some View {
		VideoPlayer(player: coordinator.player)
			.onAppear { coordinator.player.play() }
			.onDisappear { coordinator.player.pause() }
	}
}

// #Preview {
//    VideoView()
// }
