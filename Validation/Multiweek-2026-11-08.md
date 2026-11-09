# Multiweek tracking and workflow validation

This follow-up tests the combined changes from PRs #1–#5, with synthetic regressions kept in their owning PRs. Real footage and captured observations remain local. Original November 8 attachments show the initial correction; they predate this follow-up.

## Coverage and method

Fourteen short windows total 297 seconds of source time, from nine sermon weeks (August 23 through November 8) plus three archived examples. An independent 0.125-second Vision pass provides 2,376 reference frames at their actual source timestamps. Scoring checks confident (>0.1) face joints and face/neck/shoulder joints against interpolated crop bounds. This is landmark containment, not a complete silhouette or a substitute for visual review of hair, hands, clothing, and camera motion.

Reference selection follows the initial speaker by continuity. The September 6 handoff is scored only after the new speaker arrives (10s onward). The background-person reference follows the gray-jacket speaker using a fixed source-position seed, rather than allowing a crosser to become the reference. Entry is scored from source 50s onward. Missing detections are reported separately. The November 8 opening is a negative control: the preacher is absent from the original camera, and both old and new commands report no detected subject; a crop cannot repair that coverage.

Baseline is repository main `7594f5b`, with its five-second default. The intermediate revision includes one-second sampling and the initial pan correction. The final revision includes the additional fixes below. Baseline-versus-final changes both sampling and planning; a separate final-code five-second run isolates the sampling limitation.

## Findings and changes

1. **Fast step followed by slow walking:** September 20 portrait briefly clipped the face even with one-second sampling. The planner averaged a fast departure and slow continuation into one velocity. Preserve horizontal walking progress at the observed timestamps, with connected linear segments. The existing vertical interpolation remains time-based, so head bob cannot reverse horizontal motion. Synthetic tests cover acceleration/deceleration in both directions, both crop shapes, and independent head movement. The fast-to-slow and head-bob tests failed before their fixes.
2. **Background people:** denser sampling exposed a continuity-selection error. Candidates used full-body box centers while the tracked reference used the torso/face composition anchor. The inconsistent points favored a bystander at source 12s. Candidate selection now uses the same composition point for every person. Existing area ranking and maximum-distance policy remain. A synthetic native-observation regression fails before the fix and checks reordered candidates and an untrackable large pose afterward.
3. **Endpoint-only motion:** an overlapping face/body observation in the background-person example caused a vertical transition with the same start and end timestamp. Adaptive onset now retains the last stationary bound, while the end retains the first moving bound. A synthetic step regression verifies an intermediate crop position at video cadence. Onset can begin within one tracking interval before detected movement; no arbitrary duration clamp or outlier filter is added. The detector’s overlapping-person association remains a limitation.
4. **Sampling remains consequential:** final-code five-second sampling still misses movement in the August 23 reversal, September 20 opening, September 27 reversal, November 8 interval, and archived walk/entry. A one-second default is supported by this matrix; it is not a universal guarantee. Half-second sampling remains useful for rapid or unpredictable motion.

## Tracking results

| Source / source interval | Scored frames | Baseline 5s face misses C / V | Intermediate 1s face misses C / V | Final 1s face misses C / V | Final upper-body misses C / V |
| --- | ---: | ---: | ---: | ---: | ---: |
| 08-23 18–38s — left walk / reversal | 160 | 41 / 58 | 0 / 0 | 0 / 0 | 0 / 0 |
| 09-06 0–20s — speaker handoff | 80 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| 09-13 290–310s — reading / head dips / gestures | 160 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| 09-20 0–20s — fast step / glasses / turns | 160 | 0 / 8 | 0 / 3 | 0 / 0 | 0 / 0 |
| 09-27 112–132s — side bend / fast walk / reversal | 160 | 0 / 32 | 0 / 0 | 0 / 0 | 0 / 0 |
| 10-18 0–20s — different speaker / gestures / lectern | 160 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| 10-25 16–36s — crossing / turn | 160 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| 11-01 0–20s — reading / head raises / bright background | 160 | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| 11-08 280–320s — production walk / return to lectern | 320 | 34 / 46 | 0 / 0 | 0 / 0 | 0 / 0 |
| Archived walk 0–25s | 200 | 0 / 14 | 0 / 0 | 0 / 0 | 0 / 0 |
| Background people 5–25s | 160 | 0 / 0 | 89 / 91 | 0 / 0 | 0 / 0 |
| Entry 40–60s | 80 | 0 / 28 | 0 / 0 | 0 / 0 | 0 / 0 |
| Exit + empty 5–25s | 22 | 9 / 12 | 0 / 3 | 0 / 3 | 0 / 3 |
| 11-08 0–12s | 0 | no subject | no subject | no subject | no subject |

C / V means Close Up / Vertical. There are 1982 scored reference frames per crop after excluding missing detections and the explicitly scoped handoff/entry periods. Upper-body includes face, neck, and shoulders. Hands and crown are outside automatic scoring; visual checks use representative frames and contact sheets.

| Final-code pose interval | Initial / new refinement requests | Reused requests | Nov 8 face misses C / V | Keyframe wall time |
| --- | ---: | ---: | ---: | ---: |
| 5s | 8 / 39 | 21 | 23 / 35 | 2.27s |
| 1s | 40 / 55 | 22 | 0 / 0 | 4.31s |
| 0.5s | 80 / 35 | 14 | 0 / 0 | 4.23s |

The final-code comparison still fails at five seconds even after all motion fixes. Both 1s and 0.5s pass the original November 8 interval. These are single shared-Mac wall-clock measurements, including crop calculation, and overlap other QA activity; they are not throughput benchmarks. A finer interval does not guarantee a proportionate runtime increase or decrease. The initial sample count omits adaptive probes. Saving analysis was enabled for the one-second measurement.

For that interval, one-second source analysis is shared by both output paths: 40 initial samples plus 55 new refinement requests, with 22 requests reused. Loading that artifact to produce the two videos reports **0 new / 117 reused sample requests**; no aspect-specific path is loaded. Changed configurations may require further observations, as the reuse validation demonstrates.

Across all fourteen windows, final one-second keyframe commands took 25.73s total; the thirteen loaded-analysis paired exports took 141.48s total. These are summed single-run measurements on a shared Mac, not a long-sermon projection.

In the original November 8 interval, topmost face-joint clearance is 243.8–411.2 source pixels in Close Up and 456.4–623.8 in Vertical. Representative frames around source 301s show the crown and shoulders inside both crops. These are measured face-landmark margins, not a general headroom guarantee.

All sampled crop rectangles have exactly the requested native dimensions and remain inside the 3840×2160 source. No source resizing is introduced; unit-scale crop transforms are checked by export tests. Portrait and landscape paths are calculated independently from shared observations.

The exit example contains a speaker until approximately source 7.7s, then empty coverage. It is not an entirely empty window. At one-second sampling, the portrait crop briefly lags the exit while the original camera still contains face landmarks; half-second sampling eliminates those measured misses. Empty source coverage after departure is excluded from clipping counts. Peak speed across acquisition/handoff is not a measure of continuous pan comfort: the first detection deliberately acquires the subject immediately.

For the background-person vertical glitch, the old landscape export has a registered 90px vertical jump between adjacent displayed frames. After the onset-bracket fix, crop origins evaluated at the exported presentation timestamps distribute that movement across four steps (about 18.62, 23.27, 23.27, and 24.50px); the portrait path stays stationary. This removes the one-frame cut, while the overlapping-person pose association itself remains unresolved.

## Reuse, timing, and diagnostics

- PR #2 shares initial analysis and adaptive observations across two outputs. PR #5 extends reuse across commands without storing aspect-specific crop paths. September 20, October 18, and November 1 checks compare fresh versus loaded crop paths for full and changed subranges; paths match, warm repeated requests require no new detections, and partial misses are filled. A different-week source artifact is rejected before output. See [reuse validation](https://github.com/davbeck/AutoFocusAI/blob/codex/persist-pose-analysis/Documentation/Expanded-Reuse-Validation-2026-11-08.md).
- PR #3 adds 21 parameterized timing cases / 42 synthetic exports: 24/25/30/50/60 fps, 24000/1001, 30000/1001, 60000/1001, variable cadence and a long held frame; both native crops and comparison shapes; late trims and nonzero origins; video-only and audio-bearing inputs. Decoded frame-number patterns check order and speed, alongside presentation timestamps and final sample coverage. Fourteen real-media jobs produce 28 short native movies across August 23, September 20 (fractional stage camera and integer wide camera), and October 18. The 1920×1080 integer wide source uses native 960×540 / 540×960 crops; the 4K sources use 1920×1080 / 1080×1920. See [timing validation](https://github.com/davbeck/AutoFocusAI/blob/codex/fractional-export-timing/Docs/Export-Timing-2026-11-08.md).
- The October 18 source contains a 40.406667s timestamp gap (79.68→120.086667s) and shorter later gaps. Exports preserve those source timestamps; the missing capture is not repaired or scored as a tracking failure.
- Two archived HEVC MOVs require interpreting their media-to-asset edit mappings. AVFoundation sample/segment inspection confirms exact output timing against the native source timeline; raw ffprobe-normalized source timestamps differ for those legacy edit lists. This is documented separately from a speed change.
- PR #1 diagnostics retain nested AVFoundation/CoreMedia/POSIX context. Identical one-second commands on August 23 HEVC, October 18 H.264, and November 1 HEVC failed under the restricted environment and succeeded outside it. This establishes the environment distinction for those runs; it does not classify every decoder failure as sandbox-related. No product retry or elevation was added.

The final complete multiweek media inspection covers 13 rendered pairs / 26 files: all have native requested dimensions, no audio, the requested edit duration, matching paired PTS, and exact source-relative PTS after the source edit mapping. The wholly empty November 8 window has no output. The archived walk has 750 frames and the background-person example 600, matching AVFoundation’s authoritative asset timeline. Raw ffprobe-normalized source phases differ for those two legacy MOVs. The final rerun uses tracking commit `e727d21` with PR #5 `fce95d9`, timing `08215d5`, and diagnostics `fedf18a` applied together in local integration commit `30b4ab8`.

## Reproduction commands

Use a reconstructed original-resolution master for each logical section before tracking; keep Scripture Reading and Sermon separate. The November 1 test covers only the first recording part's opening, not a reconstructed full section.

```sh
# One analysis supports both independent native crop paths and saves observations.
afai 'Sermon-Wide.mov' 'Sermon-Close Up.mov' 'Sermon-Vertical.mov' \
  --resolution 1920x1080 --resolution 1080x1920 \
  --save-analysis 'Sermon.analysis.json'

# Change crop configuration and reuse compatible observations, filling any misses.
afai 'Sermon-Wide.mov' 'Sermon-Vertical-review.mov' \
  --resolution 1080x1920 --pose-interval 0.5 \
  --load-analysis 'Sermon.analysis.json' --save-analysis 'Sermon.analysis.json'

# Short original production regression, retaining source-time coordinates.
afai 'Sermon-Wide.mov' /tmp/close.mov /tmp/vertical.mov \
  --resolution 1920x1080 --resolution 1080x1920 \
  --start-time 280 --end-time 320 --save-analysis /tmp/sermon-test.analysis.json

# Reference landmarks and aspect-specific paths are separate inspection outputs.
afai 'Sermon-Wide.mov' --pose-data /tmp/reference.json \
  --pose-interval 0.125 --start-time 280 --end-time 320
```

`--save-analysis` / `--load-analysis` require PR #5; the one-second default requires PR #4; source cadence preservation requires PR #3. The original wide angle is imported separately at the same section start. Capture-specific soundboard alignment stays an editing decision: no fixed audio delay or drift correction is added.

## Checks and limits

The complete combined normal hosted test plan passed: **102 tests / 135 executions, zero failures**. It includes real exported-media inspection, synthetic pose round trips and scenario reuse, source/timing compatibility negatives, independent native crop geometry, interpolation, missing detections, subject continuity, and the reproduced motion regressions. SwiftFormat 0.58.1 lint reports **0/38 files requiring formatting**; `git diff --check` passes. No `.serialized`, sleeps, or Swift concurrency escape hatches are used to hide test failures. The timing inspector uses independent Dispatch-backed actors because AVAssetReader’s blocking read was observed to starve cooperative workers; it does not serialize test cases.

Only short intervals were rendered. No complete 51-minute export, full-section November 1 reconstruction, new audio alignment measurement, or exhaustive visual approval of every source frame was performed. One-second sampling cannot recover an excursion between observations, guarantee identity through arbitrary occlusion, or supply missing original-camera coverage. More frequent sampling can help, with additional analysis cost. New committed fixtures are synthetic, including native pose observations; private footage and pose artifacts are not bundled with tests.
