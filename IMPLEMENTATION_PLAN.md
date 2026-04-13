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

## Pose Detection Performance

### Goal

Reduce analysis time without materially hurting crop quality.

### Proposed Optimizations

#### 1. Relax exact frame extraction

The current analysis path uses `AVAssetImageGenerator` with zero tolerance before and after each requested time. That forces exact seeks and increases decode cost.

- Allow nearby frames instead of exact frame matches during analysis.
- Keep the current sampled timestamps for tracking data, but accept AVFoundation's nearest decoded frame.
- Verify that interpolation between tracked states still produces stable framing.

Done when:

- Analysis is measurably faster on long clips.
- Framing quality is unchanged or acceptably close in side-by-side review.

#### 2. Downscale frames before Vision

Pose detection does not need full-resolution source frames. Running Vision on smaller images should reduce CPU and memory cost.

- Resize decoded frames before creating the Vision request handler.
- Start with a fixed long-edge target such as 512 to 720 pixels.
- Compare detection quality across a few representative sermon clips before locking the default.

Done when:

- Pose detection time drops meaningfully.
- Detection remains reliable for a single speaker on stage footage.

#### 3. Reuse Vision request objects

The current loop constructs a new `DetectHumanBodyPoseRequest` for every sampled frame.

- Move request construction out of the per-frame loop.
- Keep request configuration stable unless we have a reason to vary it by frame.

Done when:

- The analysis loop no longer allocates a fresh pose request for each sample.

#### 4. Add region-of-interest detection

Once tracking is established, full-frame pose detection is wasteful. We should search near the prior subject location first and fall back to full-frame detection only when tracking is lost.

- Derive a padded ROI from the last known subject bounds.
- Run pose detection inside that ROI while confidence remains good.
- Fall back to a full-frame pass when the subject disappears or confidence drops.

Done when:

- Stable single-speaker clips spend most detection time in ROI mode.
- Recovery from missed detections still works reliably.

#### 5. Replace `AVAssetImageGenerator` with `AVAssetReader`

The current approach repeatedly asks AVFoundation for individual frames. For full-video analysis, sequential decode with `AVAssetReader` should be a better fit.

- Build a streaming frame reader for the video track.
- Sample frames by timestamp while decoding sequentially.
- Preserve source orientation and timing metadata needed by tracking.

Done when:

- Full-video analysis no longer depends on repeated image-generator seeks.
- End-to-end analysis time improves on medium and long clips.

#### 6. Pipeline decode and detection

The current work is strictly serial: decode frame, run Vision, repeat. A small bounded pipeline should overlap those stages.

- Separate decode from Vision work.
- Use a small bounded buffer to avoid excessive memory growth.
- Keep output ordering deterministic so tracking remains time-ordered.

Done when:

- Decode and detection overlap without changing tracking results.
- Memory use stays bounded on long videos.

#### 7. Add adaptive sampling

Not every segment needs the same analysis rate. Stable shots can be sampled less densely than active motion.

- Keep a base analysis rate.
- Increase sampling when recent subject motion exceeds a threshold.
- Decrease sampling when the subject remains stable.

Done when:

- Stable footage analyzes faster than today.
- Faster subject motion still produces smooth framing after interpolation.

### Recommended Order

1. Relax frame extraction tolerances.
2. Downscale frames before Vision.
3. Reuse the pose request object.
4. Add ROI-based detection.
5. Replace the extraction backend with `AVAssetReader`.
6. Pipeline decode and detection.
7. Add adaptive sampling.
