# AutoFocusAI Implementation Plan

## M1 Status

M1 is functionally complete.

Completed milestones:

- Analysis now produces time-ordered `ShotState` values for preview and export.
- The app shows original, output, and side-by-side synced playback.
- Export is wired up through the app save flow.
- The UI now includes progress stages, export, and comparison controls.

### M1 Follow-Up Polish

These are no longer blockers for the first milestone, but are still reasonable cleanup items:

- Remove now-unused helper code around the old image-generator path.
- Add a small amount of benchmark automation so performance regressions are easier to catch.
- Do a manual visual pass on representative sermon footage after the recent pose-processing changes.

## Pose Detection Performance

### Goal

Reduce analysis time without materially hurting crop quality.

### Completed

#### 1. Relax exact frame extraction

Done.

- Analysis no longer required exact frame seeks for the old image-generator path.
- This was a small win and is now superseded by the `AVAssetReader` backend.

#### 2. Downscale frames before Vision

Done.

- Vision now runs on scaled frames with a fixed maximum long edge.
- This remains part of the current pipeline.

#### 3. Reuse Vision request objects

Done for the serial path.

- Request reuse improved the old serial implementation slightly.
- The current pipelined path creates one request per concurrent task to keep task-local state isolated.

#### 4. Add region-of-interest detection

Explored, not adopted.

- A padded ROI prototype was built and benchmarked.
- On `TrackingExample.mov` it regressed performance, so it was reverted.
- Revisit only if we have a better confidence model or a more efficient way to crop the Vision input.

#### 5. Replace `AVAssetImageGenerator` with `AVAssetReader`

Done.

- `VideoProcessor` now uses sequential decode through `AVAssetReader`.
- This is the current extraction backend.

#### 6. Pipeline decode and detection

Done.

- The current implementation uses a bounded task group over the reader stream.
- Benchmarking found that `2` concurrent Vision tasks outperformed both the serial reader path and a wider pipeline of `3`.

#### 7. Add adaptive sampling

Not every segment needs the same analysis rate. Stable shots can be sampled less densely than active motion.

- Keep a base analysis rate.
- Increase sampling when recent subject motion exceeds a threshold.
- Decrease sampling when the subject remains stable.

Done when:

- Stable footage analyzes faster than today.
- Faster subject motion still produces smooth framing after interpolation.

Explored, not adopted.

- A motion-based adaptive cadence prototype was benchmarked.
- On `TrackingExample.mov` it reduced analyzed frames to `650`, but total wall time still regressed to `57.24s`.
- The prototype was reverted, so the fixed `10 FPS` pipeline remains the current implementation.

### Benchmarks

Measured on the local `TrackingExample.mov` benchmark clip:

1. Original baseline: `135.87s`
2. Relaxed frame extraction: `133.81s`
3. Downscaled Vision input: `107.32s`
4. Reused request objects: `106.55s`
5. `AVAssetReader` backend: `57.99s`
6. Pipelined reader + detection (`2` in flight): `54.95s`
7. Adaptive sampling prototype: `57.24s` (`650` analyzed frames, reverted)

### Remaining Work

1. Decide whether ROI detection is worth revisiting now that both ROI and adaptive cadence prototypes regressed.
2. Expand the benchmark helper into a small set of repeatable comparison runs if performance tuning remains active.
3. Do a manual visual pass on representative sermon clips after the recent pose-processing changes.

### Revised Order

1. Keep the current reader + pipeline path as the baseline.
2. Use the benchmark helper to validate any future ROI or sampling experiments before adopting them.
3. Revisit ROI only if a new detection strategy changes the workload enough to make it worth another pass.
