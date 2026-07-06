# AutoFocusAI

Crop videos based on the person's position.

## Requirements

- Xcode with the macOS 26 SDK
- Swift 6 toolchain

The app, CLI, and tests all target macOS 26.

## Build

```sh
xcodebuild build -project AutoFocusAI.xcodeproj -scheme AutoFocusAI
```

## Test

```sh
xcodebuild test -project AutoFocusAI.xcodeproj -scheme AutoFocusAI
```

## CLI

```sh
xcodebuild build -project AutoFocusAI.xcodeproj -scheme AutoFocusAICLI
```

Run the built binary with:

```sh
<input-video> <output-video>
```
