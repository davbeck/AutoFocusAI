# AutoFocusAI Product Requirements Document

## Product Summary

AutoFocusAI converts a landscape video into a vertical video that keeps a single on-stage person centered as they move horizontally across the frame.

The primary use case is a speaker, pastor, teacher, or performer walking back and forth on a stage while being recorded in a wide shot. The app should automatically produce a vertical reframed export suitable for social media and mobile viewing.

## Problem

Wide stage recordings are poorly suited for vertical distribution. Manual reframing is time-consuming and requires editing skill. Users need a fast way to drop in a landscape video and receive a vertically cropped export that tracks the subject smoothly and keeps them centered.

## Vision

Create a simple desktop tool that feels closer to "autofocus for editing" than "full video editor":

- Input: one landscape source video
- Core behavior: detect and track the primary person
- Output: one vertical rendered video with smooth subject-centered framing

## Target User

- A creator or media team member with a recorded stage video
- Minimal editing experience
- Primary goal is fast turnaround, not frame-perfect manual control

## Core Use Case

1. User opens the app.
2. User drops a landscape video into the window.
3. The app analyzes the video and tracks the subject.
4. The app generates a vertical crop that follows the subject smoothly.
5. User exports the resulting vertical video.

## Product Goals

- Produce a usable 9:16 version of a wide stage recording automatically.
- Keep the subject visually centered during left/right movement.
- Avoid jittery or overly reactive camera motion.
- Minimize user effort in M1.
- Provide tunable behavior and export controls in M2.

## Non-Goals

- Full nonlinear video editing
- Multi-subject editorial decision making
- Manual keyframing in M1
- Audio editing or enhancement
- Captions, titles, or branding overlays

## Assumptions

- Source videos are primarily landscape.
- A single person is the intended subject for most of the clip.
- The subject remains visible for most of the video.
- The desired output format is vertical, primarily 9:16.
- The app runs locally on macOS and processes videos on-device.

## Milestones

## M1: Zero-Configuration Reframing

### Goal

Deliver the shortest path from source video to usable vertical export with no user-adjustable settings.

### User Experience

- User drops a video into the app.
- App shows analysis/progress state.
- App produces a default vertical reframing result.
- User clicks `Export` and chooses where to save the output file.

### Functional Requirements

- Accept a supported local video file via drag and drop.
- Analyze video frames to detect and track the primary person.
- Generate a smooth virtual camera path based on subject position over time.
- Render a default 9:16 vertical output from the source video.
- Preserve original audio in the export when possible.
- Provide a single export action with a sensible default output format and a standard save flow that lets the user choose the destination and file name.
- Handle the no-subject-detected case with a clear error state.
- Handle processing failures with a clear error state.

### Default Behavior

- Output aspect ratio is fixed to 9:16.
- Tracking behavior is fully automatic.
- Export settings are not user-configurable.
- The user chooses the save location during export.
- Subject should remain near the horizontal center of the vertical frame.
- Motion smoothing should prefer stable framing over aggressive corrections.

### Out of Scope for M1

- Tracking sensitivity controls
- Framing bias controls
- Manual override or subject selection UI
- Preview comparison tools
- Custom codec, bitrate, resolution, or destination settings

### Success Criteria

- A user can go from dropped file to exported vertical video with no required configuration.
- Output framing is stable and keeps the subject acceptably centered for typical stage-walking footage.
- Exported video is suitable for quick review and publishing to vertical platforms.

## M2: User Controls and Export Options

### Goal

Add controls that let users tune tracking behavior and choose export settings without turning the app into a full editor.

### User Experience

- User drops a video into the app.
- App analyzes the video.
- User can adjust behavior controls and preview the result.
- User can choose export settings.
- User exports the final video.

### Functional Requirements

- Add user controls for reframing behavior, such as:
- Smoothing / responsiveness
- Subject framing bias
- Zoom or crop aggressiveness
- Recovery behavior when the subject is temporarily lost
- Add export controls, such as:
- Output resolution
- Codec / quality preset
- File name and destination
- Potentially aspect ratio presets if product direction expands beyond 9:16
- Allow re-export without re-importing the source video.

### Out of Scope for M2

- Full manual timeline editing
- Multi-camera workflows
- Collaborative review features

### Success Criteria

- Users can meaningfully tune tracking and output quality for different stage videos.
- Export options are flexible enough for common publishing workflows.
- The app remains simple enough for a non-editor to operate quickly.

## Core Product Requirements

### Input

- Accept common local video formats supported by AVFoundation.
- Support drag-and-drop as the primary ingestion flow.

### Analysis

- Detect human body pose or equivalent person position signal.
- Track the intended subject across time.
- Smooth tracking data to avoid jitter and abrupt reframing.

### Reframing

- Produce a vertical crop window from the landscape source.
- Keep the crop inside source bounds.
- Favor stable motion over frame-to-frame twitching.
- Recover gracefully when detections are noisy or temporarily unavailable.

### Preview

- Show the source video and, at minimum, enough app feedback for the user to understand processing state.
- In M2, show a usable preview of the reframed result while adjusting controls.

### Export

- Render a new video file using the computed crop path.
- Preserve timing and audio sync.
- Surface progress and completion state.

## Quality Bar

- Framing should feel intentional, not robotic.
- Camera motion should be smooth enough to resemble a human operator following the subject.
- Temporary detection instability should not cause visible shaking.
- Failures should be obvious and recoverable.

## Risks

- Pose detection may fail on low-light footage, occlusion, or wide shots.
- Multiple visible people may confuse subject selection.
- Overly reactive tracking may create unpleasant jitter.
- Under-reactive tracking may let the subject drift too far from center.
- Export performance may be slow on longer or higher-resolution videos.

## Open Questions

- What should M1 use as its default export resolution?
- Should M1 provide a preview of the reframed output before export, or is progress plus export sufficient?
- How should the app choose the primary subject if multiple people appear?
- What fallback should be used when the subject leaves frame temporarily?
