# PSHygieneGuard

A PowerShell hygiene toolkit: baseline-gated lint, encoding enforcement, silent-failure
detection, a portability checker, and a handful of narrow AST-based checkers for defect
classes that **parse cleanly, pass PSScriptAnalyzer, and still fail silently at runtime**.
Every function here was built to catch a real, previously-shipped defect - not a hypothetical
one.

Built by RG255 with Claude (Anthropic) as a contributor.

## Why this exists

PSScriptAnalyzer is excellent at what it checks, but several classes of PowerShell defect
slip straight through it - and through a normal parse - because they are only wrong at
*runtime*, in a way the language's own grammar can't see:

- `(If ($x) {1} Else {2})` parses as a call to a command literally named `If`. Valid syntax,
  never what the author meant. Only fails when that code path actually runs, with a
  misleading `The term 'If' is not recognized` error.
- A `throw` inside a `Finally` block fires on **every** exit path - including one an adjacent
  `Catch` already handled and returned cleanly from - turning an already-handled failure back
  into an uncaught exception.
- `{ ... }.GetNewClosure()` only snapshots the *immediate* enclosing scope. A `$Private:`
  variable referenced inside the closure silently fails to resolve - no error, no warning,
  the value just reads as unset whenever the closure eventually runs.
- A file with no BOM reads as UTF-8 under PowerShell 7 but as ANSI/Windows-1252 under Windows
  PowerShell 5.1 - fine right up until someone types a smart quote into it, then it breaks
  silently.
- A `try`/`catch` around a cmdlet call with no `$ErrorActionPreference = 'Stop'` never
  actually catches anything, because cmdlets fail *non-terminating* by default.

None of these are hypothetical - every checker here exists because one of these bit a real
codebase in production. See each function's own `Get-Help` for the specific incident that
motivated it.

## Requirements

| Dependency | Version | Why |
|---|---|---|
| PowerShell | 5.0+ | Everything here runs on Windows PowerShell 5.1 and PowerShell 7. |
| [PSScriptAnalyzer](https://www.powershellgallery.com/packages/PSScriptAnalyzer) | 1.25.0 | Soft dependency - see below. |
| [Pester](https://www.powershellgallery.com/packages/Pester) | 5.7.1 | Only needed to run `Tests\PSHygieneGuard.Tests.ps1`. Never a runtime dependency of the module itself. |

Install both:

```powershell
# Elevated:
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force -SkipPublisherCheck
Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck

# Or, without admin rights:
Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser -Force -SkipPublisherCheck
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
```

Confirm what's actually installed before relying on it:

```powershell
Get-Module -ListAvailable PSScriptAnalyzer, Pester
```

**PSScriptAnalyzer is deliberately a *soft* dependency, not in the module manifest's
`RequiredModules`.** Every checker that uses it degrades gracefully when it's absent - it
returns a distinct code (see each function's own `.NOTES`) and keeps running whatever it can
(a parse-only check, for instance) rather than crashing `Import-Module` outright or silently
reporting a false "all clean." Pester is a test-only dependency and is never imported by the
module's own code. Both are still pinned in the manifest's
`PrivateData.PSData.ExternalModuleDependencies` for discoverability.

**Note on the module's own naming**: every function uses the `PSHG-` prefix instead of a
standard PowerShell verb (`PSHG-TestScriptSyntax`, not `Test-PSHGScriptSyntax`). This
intentionally trades PowerShell's "approved verb" convention (`Import-Module` will warn about
it - harmless, just a warning) for a short, consistent, collision-resistant prefix across
seventeen functions whose natural verbs (`Test-`, `Find-`, `Invoke-`, `Format-`) would otherwise
be generic enough to collide with other modules.

## Quick start

```powershell
Import-Module .\PSHygieneGuard.psd1

# See it work against the shipped examples, without touching anything permanent:
.\Demo\Invoke-Demo.ps1

# Run a real check against your own code:
PSHG-TestScriptSyntax -Path C:\MyProject
PSHG-TestFileEncoding -Path C:\MyProject -Fix
PSHG-InvokeSilentFailureSweep -Path C:\MyProject
```

## Detect-only vs. auto-fix

Three of the seventeen functions actually **change** the file they flag; everything else only
ever reports - it is always a human decision (fix the code, or justify why it's fine) that
determines what happens next, never the tool itself.

| Function | Behavior |
|---|---|
| `PSHG-TestFileEncoding -Fix` | **Fixes.** Converts to UTF-8-with-BOM in place. |
| `PSHG-FormatPS1File` | **Fixes.** Reformats indentation in place, keeping the file's BOM state. Refuses (file left unchanged) if the file is not valid UTF-8 or the formatter's own output looks corrupted - see its help. |
| `PSHG-FindHardcodedWindowsPath -Fix` | **Fixes** 5 of 6 targets, in both code and comments, only at assignments and path arguments (refuses to write if the fix would introduce a parse error or the file is not valid UTF-8). Never rewrites `.psd1` data files, regex-escaped literals or `-match`/`-replace`/`-split` operands. `Users\<name>` always stays report-only - see its own help for why that one target can't be auto-fixed safely. Supports `-WhatIf`. |
| `PSHG-TestScriptSyntax` | Reports only. |
| `PSHG-TestBareKeywordCommand` | Reports only. |
| `PSHG-TestFinallyThrow` | Reports only. |
| `PSHG-TestGetNewClosureScope` | Reports only. |
| `PSHG-TestGetNewClosurePrivateScope` | Reports only. |
| `PSHG-FindDriveLetterAssumption` | Reports only (a candidate list for human review, not a verdict). |
| `PSHG-TestJoinPathDriveRoot` | Reports only. Every hit is a bug unless the line carries `# PSHG-OK: JoinPathDriveRoot`. |
| `PSHG-TestTypographicQuoteEscape` | Reports only. No baseline and no marker: every site is listed on every run. |
| `PSHG-TestUnescapedLiteral` | Reports only. A lead finder, not a verdict: no baseline and no marker, every site is listed on every run. |
| `PSHG-TestLivePinLiteral` | Reports only. Baseline-gated (`-BaselinePath`, `-UpdateBaseline` records current sites as accepted); a new site exits 1. |
| `PSHG-TestModuleVersionSelfReference` | Reports only. |
| `PSHG-TestScriptErrorHandling` | Reports only. |
| `PSHG-InvokeSilentFailureSweep` | Reports only. |
| `PSHG-TestRepoLint` | Reports only. `-UpdateBaseline` does **not** fix anything either - it only records a finding as *accepted*, with a reason a human writes. The underlying code is never touched. |

## Baselining - why, and how

`PSHG-TestRepoLint` and `PSHG-InvokeSilentFailureSweep`/`PSHG-TestScriptErrorHandling` are
**baseline-gated**, not rule-excluded. The distinction matters:

- Excluding a rule silences it for *all* code, forever - including code written tomorrow that
  has the exact same real defect.
- A baseline records specific, already-reviewed findings as accepted **once**, by exact
  identity (rule + relative path + function name, never a line number, so an unrelated edit
  above a finding never resurrects it as "new"). Anything genuinely new still fails the check.

The rule stays switched ON. Only pre-existing, deliberately-reviewed debt gets grandfathered
- and only with a real, written reason, never a blanket accept-all.

Both baseline files ship **empty** in `PSHygieneGuardBaseline\` - this is a template for you
to populate against your own codebase, not this project's own accepted debt:

```powershell
# First run: see everything as a new finding.
PSHG-TestRepoLint -Path C:\MyProject

# Review each finding. For each one that's genuinely fine, accept it:
PSHG-TestRepoLint -Path C:\MyProject -RepoRoot C:\MyProject -BaselinePath C:\MyProject\RepoLint-Baseline.psd1 -UpdateBaseline
```

**`-UpdateBaseline` does not silently accept a finding as reviewed.** It writes a generic
`TODO: ...` placeholder reason for anything newly accepted - go back and replace every `TODO`
with the ACTUAL reason (BY DESIGN / FALSE POSITIVE / a genuine defect you've now fixed
instead) before trusting a clean run. See `Examples\Baselining\README.md` for a fully worked
walkthrough, and `Examples\Baselining\SampleBaselineEntry.psd1` for what a real, well-reasoned
entry looks like.

`-BaselinePath` on both functions lets you point at any baseline file/location - the default
(`PSHygieneGuardBaseline\` next to the module) is a zero-config convenience, not a
requirement for READING. The shipped baseline is a read-only template: `-UpdateBaseline`
requires an explicit `-BaselinePath` (`PSHG-TestRepoLint`) or `-Baseline`
(`PSHG-TestScriptErrorHandling` / `PSHG-InvokeSilentFailureSweep`) and exits 2 without one.
If the baseline file cannot be read or parsed, `PSHG-TestRepoLint` prints the
file name and exits 2 rather than treating everything as new.

For any `-Rule` other than the two defaults, `PSHG-TestRepoLint` keys a finding as
`Rule|RelativePath|Token@EnclosingFunction#N`, so accepting one finding does not accept every
later one in the same file. A file outside `-RepoRoot` gets a warning, because its key would
hold an absolute path.

Relative paths in the baseline are computed from `-RepoRoot` (default: the current directory;
a trailing slash is ignored). Pass it explicitly from scripts or scheduled tasks. Running
`-UpdateBaseline` together with `-Path` *merges*: only entries inside the scanned folder are
replaced and entries for other folders are kept (the match is on a whole path segment, so
`Modules\App` does not touch `Modules\AppLegacy`).

## Exit codes

The functions set `$LASTEXITCODE` (they do not call `exit`). To get a process exit code, call
the function and then `exit $LASTEXITCODE`:

```powershell
powershell.exe -NoProfile -Command "Import-Module .\PSHygieneGuard.psd1; PSHG-TestRepoLint -Path .\src; exit $LASTEXITCODE"
```

| Code | Typical meaning |
|---|---|
| 0 | Clean (or the requested fix/baseline write succeeded). |
| 1 | Findings, or a file was refused / non-compliant. |
| 2 | The check could not run reliably: PSScriptAnalyzer missing or erroring on a file, an unreadable baseline, a scan that errored and found nothing, or **at least one file was not checked** (missing, unreadable, or a parse error). Never a clean result. |

A checker never reports "clean" for files it skipped: every skipped file is listed (`NOT CHECKED`)
and makes the run exit 2 when nothing else was found. The AST checkers (`PSHG-TestBareKeywordCommand`,
`PSHG-TestFinallyThrow`, `PSHG-TestGetNewClosureScope`, `PSHG-TestGetNewClosurePrivateScope`,
`PSHG-TestJoinPathDriveRoot`) and `PSHG-TestScriptSyntax` folder mode scan `.ps1` and `.psm1`.

The table is the general shape; exact codes per function are in each function's `.NOTES`. Notable
exceptions: `PSHG-TestFileEncoding` also uses 2 for files that need manual review (not valid UTF-8,
with or without a BOM; unreadable; named but missing), and
`PSHG-TestScriptSyntax` uses 1 = parse errors or a file/path it could not check, 2 = analyzer findings only, 3 = PSScriptAnalyzer missing.

## Safety notes

- `PSHG-TestScriptErrorHandling -TestWrapper` **executes** the wrapper and collector functions it
  extracts from the scanned file. Use it only on code you trust. The static scan never runs the target.
- `-Fix` and `-UpdateBaseline` write through a temp file in the same folder; `PSHG-TestFileEncoding`
  and `PSHG-FindHardcodedWindowsPath` also accept `-WhatIf`.

## Teaching the silent-failure checker your own codebase's idioms

`PSHG-TestScriptErrorHandling` (and `PSHG-InvokeSilentFailureSweep`, which passes it straight
through) recognizes a `catch` block as genuinely signaling a failure when it `throw`s,
`Write-Error`s, or assigns something that reads like a fail/error/success/status flag - but it
can't know about a function your OWN codebase uses for the same purpose (an audit-trail logger,
a telemetry call, an internal result-recording helper). Rather than baselining every hit that
calls your own such function one by one, teach the checker about it directly:

```powershell
PSHG-InvokeSilentFailureSweep -Path C:\MyProject -KnownSignalFunction 'Write-MyAuditTrail'
```

Accepts more than one name. On a large real codebase this one flag removed over a hundred
false positives: most `catch` blocks calling the project's own audit logger were never
recognized as signaling anything until the checker was told what to look for, and were
otherwise headed for one baseline entry apiece.

**Worked example.** Given this function:

```powershell
Function Test-Example
{
    Try
    {
        Get-Item 'C:\DoesNotExist' -ErrorAction Stop
    }
    Catch
    {
        Write-MyAuditTrail -Message $_.Exception.Message
    }
    return $true
}
```

Without the flag, the checker has no way to know `Write-MyAuditTrail` records anything, so it
flags the catch as a genuine defect:

```powershell
PSHG-TestScriptErrorHandling -Path .\Test-Example.ps1

  [AP9] line 7: catch in 'Test-Example' SILENTLY swallows the error (no output, no signal)
        and execution CONTINUES - nothing anywhere records this failure
```

With it, the same catch is recognized and the finding disappears entirely:

```powershell
PSHG-TestScriptErrorHandling -Path .\Test-Example.ps1 -KnownSignalFunction 'Write-MyAuditTrail'

  no findings
```

## The functions

| Function | What it catches |
|---|---|
| `PSHG-TestScriptSyntax` | Parse errors + PSScriptAnalyzer findings, the fast per-file check while editing. |
| `PSHG-TestFileEncoding` | Missing/doubled BOM. |
| `PSHG-FormatPS1File` | Inconsistent tab indentation. |
| `PSHG-TestBareKeywordCommand` | `If`/`ElseIf`/`While` misused inside plain `(...)` instead of `$(...)`. |
| `PSHG-TestFinallyThrow` | A `throw` inside a `Finally` block. |
| `PSHG-TestGetNewClosureScope` | A plain variable or bare nested-function call inside `.GetNewClosure()` that isn't locally available. |
| `PSHG-TestGetNewClosurePrivateScope` | A `$Private:` variable relied on inside `.GetNewClosure()` (never survives capture). |
| `PSHG-FindDriveLetterAssumption` | Code that assumes every mount/volume has a drive letter. |
| `PSHG-FindHardcodedWindowsPath` | A hardcoded `C:\Program Files\`/`ProgramData\`/`Windows\`/`Users\<name>\` path that should use the matching `$env:` variable. |
| `PSHG-TestJoinPathDriveRoot` ([guide](Docs/PSHG-TestJoinPathDriveRoot.md)) | `Join-Path` on a drive root built from a variable (`'{0}:\' -f $Letter`, `"${Letter}:\..."`). `Join-Path` throws "Cannot find drive" when that drive is not mounted - the case for a USB drive plugged in after the session started or an unmounted VHD. Use `[System.IO.Path]::Combine`. |
| `PSHG-TestTypographicQuoteEscape` ([guide](Docs/PSHG-TestTypographicQuoteEscape.md)) | Hand-rolled quote escaping that handles only the ASCII quote (`-replace "'", "''"`, `.Replace("'", "''")`, `[regex]::Replace(...)`, and the double-quote forms). PowerShell also reads U+2018-U+201B and U+201C-U+201E as quotes, so a value containing one still ends the literal early. Lists every site on every run (no baseline); exit 1 on any. |
| `PSHG-TestUnescapedLiteral` ([guide](Docs/PSHG-TestUnescapedLiteral.md)) | A value put between single quotes in a `-f` format string (`"Set-Thing -Path '{0}'" -f $Path`, `"@{{ Path = '{0}' }}" -f $Path`, `[string]::Format`) with no escaping at all, so even an ASCII apostrophe in the value ends the literal early in the generated command or data file. Safe forms are skipped (`Format-EscapedLiteral`, constants, typed numbers/guids/dates, `ValidateSet`, variables whose assignment is verified). A lead list to review, not a verdict: lists every site on every run (no baseline); exit 1 on any. |
| `PSHG-TestLivePinLiteral` ([guide](Docs/PSHG-TestLivePinLiteral.md)) | For codebases that publish each module's live version in `<Module>\LiveVersion.psd1`: a literal `Import-Module X -RequiredVersion 1.2` or `Open-MyElevatedSession -ModuleName X -ModuleVersion 1.2` (also inside a string built for a child process) on a module that has such a file, which goes stale at the next branch. Skips frozen (non-newest) version folders and a module's own self-references unless asked. Baseline-gated; exit 1 on a new site. |
| `PSHG-TestModuleVersionSelfReference` | A module's own files still pointing at an OLDER version of itself after a branch. |
| `PSHG-TestScriptErrorHandling` | The silent-failure antipatterns, reported as AP1-AP12 (empty catch, swallowed `$LASTEXITCODE`, null-unsafe conditionals, and more - see its own `Get-Help -Full`). |
| `PSHG-InvokeSilentFailureSweep` | Bulk-audit driver for `PSHG-TestScriptErrorHandling` across a whole tree, with a per-rule summary. If the background scan reports errors and finds nothing it exits 2, never a false clean. |
| `PSHG-TestRepoLint` | Baseline-gated PSScriptAnalyzer gate (defaults to `ShouldProcess`/`SingularNouns`, configurable via `-Rule`). |

Every function has full comment-based help - `Get-Help PSHG-TestScriptSyntax -Full` for the
complete picture, including the parameters and examples above.

## Examples

`Examples\Good\` and `Examples\Bad.zip` contain real, runnable `.ps1` files - one pair per
distinct defect shape, not just one per checker. Where a checker documents multiple genuinely
different ways it fires (e.g. the 3 real incident shapes behind
`PSHG-FindDriveLetterAssumption`), each gets its own pair. Where a defect has more than one
*legitimate* fix (empty-catch has three - see `Examples\Good\CorrectEmptyCatch-*.ps1`), each
resolution gets its own file too, rather than implying there's only one correct answer.

**Why `Bad\` ships as a zip, not live `.ps1` files:** every fixture in it is *deliberately*
broken - that's the point. A generic module-release pipeline can't tell "intentional teaching
fixture" from "real defect that should block deployment," so keeping them as live source in
the tree would make this repo permanently fail its own (or anyone else's) standard checks.
Zipping keeps them fully inspectable - open `Bad.zip` with any archive tool - without ever
being live source a generic scan sees.

```powershell
Expand-Archive .\Examples\Bad.zip -DestinationPath C:\Temp\PSHGBadExamples
PSHG-TestScriptSyntax -Path C:\Temp\PSHGBadExamples
```

Or run `.\Demo\Invoke-Demo.ps1` for a scripted walkthrough that extracts the zip itself,
exercises the auto-fix and baseline lifecycle for real against a disposable copy, and never
touches the shipped `Examples\` files.

## Contributing / License

MIT licensed - see `LICENSE`. Issues and pull requests welcome at
[github.com/RG255/PSHygieneGuard](https://github.com/RG255/PSHygieneGuard).
