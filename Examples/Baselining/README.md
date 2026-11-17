# Baselining walkthrough

A worked example of the full accept-a-finding lifecycle, using `PSHG-TestRepoLint` against
`SilentEmptyCatch.ps1` and `ClosurePrivateScopeCapture.ps1` from `Examples\Bad.zip` (both
happen to use state-changing verbs - `Remove-`/`New-` - without `ShouldProcess`, which is
exactly the kind of thing this checker gates on).

## 0. Extract the zip

`Examples\Bad.zip` ships as a zip rather than live `.ps1` files - see the main README's
"Examples" section for why. Extract it somewhere disposable first:

```powershell
Expand-Archive ..\Bad.zip -DestinationPath C:\Temp\PSHGBadExamples
```

## 1. Run it - see the finding

```powershell
PSHG-TestRepoLint -Path C:\Temp\PSHGBadExamples
```

```
FAIL - 2 NEW finding(s):
  [ShouldProcessForStateChangingFunctions] Remove-TempFile
      SilentEmptyCatch.ps1:9
  [ShouldProcessForStateChangingFunctions] New-ClickHandler
      ClosurePrivateScopeCapture.ps1:9
```

## 2. Judge it

For each finding, decide one of three things:

- **BY DESIGN** - the code is correct as-is; the rule doesn't apply here for a specific,
  articulable reason.
- **FALSE POSITIVE** - the checker's pattern-matching missed something a human can see
  immediately (e.g. a guard clause the checker's heuristic doesn't recognize).
- **Genuine defect** - fix the code instead of accepting the finding.

In this example: both functions genuinely change state (delete a file, wire up an event
handler with a side effect) without supporting `-WhatIf`/`-Confirm` - a real case where adding
`SupportsShouldProcess` would be the better fix in production code. For this walkthrough,
we'll accept them as BY DESIGN (they're example/demo functions, not production code with real
blast radius) to show the acceptance mechanism.

## 3. Accept it

```powershell
PSHG-TestRepoLint -Path C:\Temp\PSHGBadExamples -RepoRoot C:\Temp\PSHGBadExamples -BaselinePath C:\Temp\PSHGBadExamples\RepoLint-Baseline.psd1 -UpdateBaseline
```

This writes a `TODO: ...` placeholder for each newly-accepted finding - **this does not count
as reviewed**. The very next (non-update) run still reports both as live findings until the
placeholder is replaced with a real reason.

## 4. Replace the placeholder with a real reason

Open the baseline `.psd1` and replace each `TODO:` value. See
`SampleBaselineEntry.psd1` in this folder for the level of detail expected - state what the
finding actually is, why it's safe (or why it was fixed instead), and how you verified that.

## 5. Confirm it's quiet

```powershell
PSHG-TestRepoLint -Path C:\Temp\PSHGBadExamples
```

```
PASS - no new findings (2 accepted, 2 rule(s) gated).
```

The rule is still fully active - any *new* `ShouldProcessForStateChangingFunctions` finding
elsewhere in the codebase still fails the check. Only these two specific, reviewed findings
are quiet.

See `..\..\Demo\Invoke-Demo.ps1` for this exact lifecycle run live, end to end, against a
disposable copy.
