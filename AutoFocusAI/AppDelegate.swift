import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
	func application(_ application: NSApplication, open urls: [URL]) {
		print(">> \(urls)")
	}
}
