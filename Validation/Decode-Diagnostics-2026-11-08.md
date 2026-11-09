# Decode diagnostics validation — November 8, 2026

The analyzer already retained the image generator's underlying error, but its
localized message reduced the CLI failure to “Cannot Decode.” That text did not
expose the AVFoundation error identity or its nested OSStatus cause.

The same valid source and short command were run in the restricted Codex
execution environment and outside that restriction:

```sh
afai \
  "/Volumes/Recordings/2026-11-08/10.31.35.209 Sermon 2026-11-08 MEVO-KH4KR (Mevo-KH4KR).mov" \
  --pose-data /tmp/afai-diagnostics-poses.json \
  --start-time 280 --end-time 281 --debug
```

Restricted execution exited 1 and emitted the following details on stderr,
followed by the existing concise error:

```text
Failure: AutoFocusCore.PoseVideoAnalyzer.Error (0): Unable to generate an analysis frame: Cannot Decode
Caused by: AVFoundationErrorDomain (-11821): Cannot Decode
Reason: The media data could not be decoded. It may be damaged.
Caused by: NSOSStatusErrorDomain (-12911): The operation couldn’t be completed. (OSStatus error -12911.)
Error: Unable to generate an analysis frame: Cannot Decode
```

The identical command outside the restriction exited 0, wrote one pose sample,
and emitted no stderr. Without `--debug`, restricted execution still exited 1
and emitted only the original concise application error. A framework-generated
`sysctlbyname` diagnostic also appeared on restricted stderr; it is independent
of the new formatter.

This establishes an environment-dependent failure for this invocation. Neither
the generic AVFoundation damage suggestion nor the OSStatus code alone proves
corruption or identifies which restriction caused the decode failure. No retry,
permission change, or sandbox classification was added to the CLI.

Validation completed:

- CLI Xcode build succeeded.
- `ErrorDiagnosticsTests`: 7 tests passed, covering nested causes, unknown
  native/Swift error identity, failure reasons, missing underlying errors,
  bounded output, and exclusion of arbitrary `userInfo` values.
- SwiftFormat 0.58.1 repository lint: 0 of 28 files require formatting.
- `git diff --check` passed.

The formatter emits at most eight causal levels and reads only domain, code,
localized description/failure reason, and the underlying-error link. It does
not dump arbitrary framework `userInfo` dictionaries.

## Expanded checks across recording weeks

The same CLI binary analyzed source 10–11 seconds from three additional original
4K camera recordings. Each command used `--pose-data`, `--start-time 10`,
`--end-time 11`, and `--debug`; no media export was needed for this diagnostic
check. Output files stayed in a temporary local directory.

| Source recording | Codec | Restricted execution | Unrestricted execution |
| --- | --- | --- | --- |
| August 23, `10.42.17.652 Sermon 2026-08-23 Preacher.mov` | HEVC | Exit 1 | Exit 0, one pose sample |
| October 18, `10.30.47.750 Sermon 2026-10-18 MEVO-KH4KR (Mevo-KH4KR).mov` | H.264 | Exit 1 | Exit 0, one pose sample |
| November 1, `10.35.33.027 Sermon 2026-11-01 MEVO-KH4KR (Mevo-KH4KR).mov` | HEVC | Exit 1 | Exit 0, one pose sample |

All three restricted runs exposed the same AVFoundation `-11821` → OSStatus
`-12911` causal chain. All three unrestricted runs emitted no stderr. These
results extend the environment-dependent reproduction across source weeks and
both codecs; they do not identify the specific restriction responsible.

Expanded automated coverage uses synthetic errors only. It checks a native
reader error with nested media/system causes, an unexpected Swift error with a
stable Foundation identity, the documented causal-depth limit, and suppression
of a repeated failure reason. No production frame or pose fixture is included.
