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
- `ErrorDiagnosticsTests`: 3 tests passed, covering nested causes, unknown error
  identity/reason, missing underlying errors, and exclusion of arbitrary
  `userInfo` values.
- SwiftFormat 0.58.1 repository lint: 0 of 28 files require formatting.
- `git diff --check` passed.

The formatter emits at most eight causal levels and reads only domain, code,
localized description/failure reason, and the underlying-error link. It does
not dump arbitrary framework `userInfo` dictionaries.
