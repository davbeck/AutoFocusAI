# Expanded reusable-analysis validation — November 8, 2026

This expands the [initial reusable-analysis checks](Persisted-Analysis-Validation-2026-11-08.md) with synthetic pose scenarios and short original recordings from three additional weeks. No production change was needed.

## Deterministic observation scenarios

`PoseScenarioReuseTests` adds three test functions with six executions:

- Four traces cover walking and return movement during face-joint loss or partial shoulder occlusion; two empty detections followed by reentry; a smaller background person with changing observation-array order; and raised arms with head dips.
- Each trace runs both native crop shapes, serializes initial and adaptive observations, reloads them, and requires identical crop bounds, timestamps, and selected subject centers with zero new detector-provider calls. It also checks native crop sizes, source-frame bounds, nonzero source/selection origins, empty observations, and retention of both people.
- Increasing tracking precision from 8 to 16 updates per second fills additional boundary probes, then reuses them on the next calculation.
- Selecting an empty subrange from an artifact containing people at other times produces an empty selection and the expected no-subject error. The selected-start extraction context is filled separately; earlier people cannot leak into it.

Every pose comes from the hand-authored synthetic skeleton documented in `AutoFocusAITests/Fixtures/Analysis-Fixtures.md`. Scenario geometry and confidence changes use constants and simple curves. Face-joint loss represents a turn at the observation layer; these tests exercise tracking and reuse after detection, rather than measuring Vision's ability to detect a real turn. Captured recordings and their observations remain local.

The focused suite passed all six executions in the normal macOS test host, without sleeps or serialization:

```sh
xcodebuild test -project AutoFocusAI.xcodeproj -scheme AutoFocusAI \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/afai-reuse-expanded-build \
  -only-testing:AutoFocusAITests/PoseScenarioReuseTests CODE_SIGNING_ALLOWED=NO
```

## Original-recording matrix

Runtime checks used the combined five-PR CLI at `999bd06`, including the tracking and source-cadence changes. The new unit tests ran on the reusable-analysis branch based on `6c20495`. Source-time preservation in the following media checks depends on the separate timing PR.

All recordings were 3840×2160, video only, with reported nominal cadence 30000/1001 and a 1/600 time base:

| Recording | Codec | Checked source interval | Fresh Close Up: new requests | Loaded Vertical: new requests | Repeated both shapes: new requests |
| --- | --- | --- | ---: | ---: | ---: |
| September 20, 10:34:59.202 MEVO | H.264 | 280–292s | 19 | 3 | 0 |
| October 18, 10:30:47.750 MEVO | H.264 | 280–292s | 12 | 0 | 0 |
| November 1, 10:35:33.027 MEVO | HEVC | 280–292s | 19 | 0 | 0 |

Counts are new extraction/sample requests, including adaptive requests, rather than a count of people. Every initial pass contained 12 sampled frames. The three additional September portrait requests demonstrate that a different crop can need observations absent from the landscape artifact. After filling them, repeated calculations for both shapes needed no new samples.

For all three recordings:

- Fresh and loaded JSON crop paths matched exactly for both native shapes.
- Close Up and Vertical exports were 1920×1080 and 1080×1920, respectively, each with one video stream and zero audio streams.
- Each export reported 361 frames and exactly 12.000000s edited duration. Both PTS arrays matched exactly, including the partial boundary frame at elapsed zero and the final PTS at 7195/600 = 11.991667s.
- Every subsequent PTS equaled a source PTS minus 280s; the comparison read past the selected end before filtering source packets, preserving reordered frames near the boundary.
- Presentation intervals derived from consecutive PTS, together with the common 12s edit end, matched between shapes. Compressed packet-duration fields differed at four packets on October 18 and eight on November 1; identical compressed-packet timing is not claimed.

Fresh Close Up / loaded Vertical elapsed times were 5.246s / 3.755s, 4.152s / 3.419s, and 4.068s / 3.653s, respectively. Warm two-shape keyframe calculations took 0.177s, 0.047s, and 0.042s. These are individual Debug-build measurements on a shared Mac, not full-recording throughput estimates.

## Changed selections and source compatibility

Separate checks rebuilt a fresh 280–292s artifact, then selected 282–292s for both shapes:

| Recording | First loaded 10s selection: new requests | Repeated selection: new requests | Fresh versus loaded paths |
| --- | ---: | ---: | --- |
| September 20 | 1 | 0 | Exact match |
| October 18 | 1 | 0 | Exact match |
| November 1 | 1 | 0 | Exact match |

The selected-start request differs from an interior request at the same nominal source time. It is analyzed under its own extraction context, while compatible interior observations are reused. Earlier 282–290s checks also passed: September 20 required three new requests (one selected-start request and two additional crop-boundary probes), then zero on repetition. Those checks remain in the local run record.

Loading the September 20 artifact against the valid October 18 recording rejected the incompatible file path with an actionable message and exit code 64; no keyframe file was created.

Representative commands, with output directories already created:

```sh
afai "$SOURCE" "$OUT/close.mov" --resolution 1920x1080 \
  --pose-interval 1 --start-time 280 --end-time 292 \
  --save-analysis "$OUT/analysis.json"

afai "$SOURCE" "$OUT/vertical.mov" --resolution 1080x1920 \
  --pose-interval 1 --start-time 280 --end-time 292 \
  --load-analysis "$OUT/analysis.json" --save-analysis "$OUT/analysis.json"

afai "$SOURCE" --keyframes "$OUT/loaded.json" \
  --resolution 1920x1080 --resolution 1080x1920 \
  --pose-interval 1 --start-time 282 --end-time 292 \
  --load-analysis "$OUT/analysis.json" --save-analysis "$OUT/analysis.json"

afai "$SOURCE" --keyframes "$OUT/fresh.json" \
  --resolution 1920x1080 --resolution 1080x1920 \
  --pose-interval 1 --start-time 282 --end-time 292
```

Exact commands, logs, local media, source observations, and result summaries are retained under `/tmp/afai-multiweek/reuse/`. They are excluded from repository changes.

## Limits

These checks establish reuse equivalence and presentation-time alignment over the checked intervals. Complete sermons, recording joins, other people entering at different distances, prolonged occlusion, and all visual framing choices across these recordings remain unverified by this matrix. The synthetic scenarios cover observation-level behavior; the original-recording checks are not a whole-sermon visual approval. No soundboard alignment or audio-drift conclusion follows from these video-only checks.
