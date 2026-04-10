# AutoFocusAI Implementation Plan

## M1 Immediate Next Steps

### 1. Promote analysis output from poses to shot states

Use the existing pose detection pipeline to produce a time-ordered list of reframing states, not just raw body poses.

- Keep `VideoProcessor` responsible for frame iteration and detection.
- Add a pass that feeds detected poses into `ShotTracker`.
- Store per-frame crop bounds for later preview and export.

Done when:

- The app can compute a vertical crop rectangle for the full video.

### 2. Show the computed framing in-app

Replace the current "processing only" experience with a basic result preview.

- Keep the existing source player.
- Overlay or otherwise display the computed crop window on the source video.
- Show simple states: idle, processing, ready, failed.

Done when:

- Dropping a video results in a visible tracked frame after analysis completes.

### 3. Implement a default export path

Render the computed crop path into a new vertical video file.

- Use a fixed 9:16 output.
- Preserve source audio when possible.
- Expose a single `Export` action once analysis is ready.
- Present a save panel so the user chooses the destination and file name.

Done when:

- A user can drop a video, choose where to save it, and export a vertical output with no settings.

### 4. Tighten the minimal product UI

Reduce the app surface to only what M1 needs.

- Keep drag-and-drop ingest.
- Replace the empty inspector with status, errors, and the export action.
- Add clear messaging for unsupported video, failed analysis, and failed export.

Done when:

- The full M1 flow is understandable without any hidden or placeholder UI.

## Suggested Order

1. Analysis to shot states
2. Preview of computed framing
3. Export pipeline
4. Minimal status/error polish
