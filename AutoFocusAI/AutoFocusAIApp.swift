//
//  AutoFocusAIApp.swift
//  AutoFocusAI
//
//  Created by David Beck on 4/26/25.
//

import SwiftUI
import AppKit

@main
struct AutoFocusAIApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
	
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
