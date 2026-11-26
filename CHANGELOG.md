# Changelog

## 0.1 (2026-11-26 update, no version bump)

- Added `LiveVersion.psd1` (states the live version of the module; read only when no copy sits beside the version folders).

## 0.1 (2026-11-22 update, no version bump)

- New function `PSHG-TestLivePinLiteral` (17th export, additive: no existing function changed): AST check for a literal version pin on a module that publishes its live version in `<ModulesRoot>\<Module>\LiveVersion.psd1` - `Import-Module X -RequiredVersion <literal>`, `Open-MyElevatedSession -ModuleName X -ModuleVersion <literal>`, and the same `Import-Module` text inside a string built for a child process (kind `InString`). Skips frozen version folders (not the newest of their module) and a module's own self-references unless `-IncludeFrozen` / `-IncludeSelf`. Baseline-gated (`-BaselinePath`, `-UpdateBaseline`, `-All`; keys `LivePinLiteral|<relative path>|<Module>|<Kind>`, never a line number). Exit 0 no new site / 1 new site / 2 could not run reliably (no modules root, unreadable baseline, files not checked). `-Quiet`, `-Csv`, `-PassThru`, pipeline input. Guide: `Docs\PSHG-TestLivePinLiteral.md`.
- Tests: new `Tests\PSHygieneGuard.LivePinLiteral.Tests.ps1` (16 tests); the export-count test now expects 17 functions.
- Amended 2026-11-22: Fixed: the `-Fix` rewrite of `PSHG-FindHardcodedWindowsPath` and the baseline files written by `PSHG-TestRepoLint` and `PSHG-TestScriptErrorHandling` now double the typographic single quotes (U+2018-U+201B) as well as the ASCII apostrophe when they put a path or key inside a single-quoted literal. New `Tests\PSHygieneGuard.QuoteEscapeWriters.Tests.ps1` (3 tests).

## 0.1 (2026-11-16 second update, no version bump)

- New function `PSHG-TestUnescapedLiteral` (16th export): AST check for a value placed inside a single-quoted literal of a `-f` format string (or `[string]::Format`) with no escaping at all - `"Set-Thing -Path '{0}'" -f $Path`, `"@{{ Path = '{0}' }}" -f $Path`, also inside a here-string - so even an ASCII apostrophe in the value ends the literal early. An argument is accepted when it is a `Format-EscapedLiteral` call (any spelling, through a pipeline or `$( )`), a constant, a variable whose every earlier assignment in the same function is safe (the name is never trusted: `*Esc` / `*Escaped` / `*ForCb` without an escape assignment is reported as `name-only`), a typed int/guid/datetime/bool/enum value, a `ValidateSet` parameter without quotes, a `.ToString('N')`-style format, `Get-Date`, or an If/Else of safe values. Reports file, line, argument index, kind and the expression for EVERY site (a lead list to review, not a verdict); deliberately no baseline and no marker comment. Sites whose result is only displayed or thrown are skipped unless `-IncludeDisplay`; `-DisplayCommand` adds names; test files in a scanned folder are skipped unless `-IncludeTests`. Exit 0 clean / 1 sites / 2 not clean (files unreadable). `-Quiet`, `-Csv`, `-PassThru`, pipeline input. Guide: `Docs\PSHG-TestUnescapedLiteral.md`.
- Tests: new `Tests\PSHygieneGuard.UnescapedLiteral.Tests.ps1` (50 tests) and the Good fixture `Examples\Good\CorrectUnescapedLiteral.ps1`; the export-count test now expects 16 functions. Suite total 205 per host.

## 0.1 (2026-11-16 update, no version bump)

- New function `PSHG-TestTypographicQuoteEscape` (15th export): AST check for hand-rolled quote escaping that handles only the ASCII quote - `-replace`, `.Replace()` or `[regex]::Replace` with the ASCII `'` replaced by `''` (or `"` by `""` / `` `" ``), unless the same chained expression also names a typographic quote (U+2018-U+201B, U+201C-U+201E). PowerShell reads those as quotes too, so such code breaks, or can be made to run attacker text, when a value contains one. Reports file, line, kind and the expression for EVERY site; deliberately no baseline and no marker comment, so old sites stay visible. Exit 0 clean / 1 findings / 2 not clean (files unreadable). `-Quiet`, `-Csv`, `-PassThru`, pipeline input. Guide: `Docs\PSHG-TestTypographicQuoteEscape.md`.
- Tests: new `Tests\PSHygieneGuard.TypographicQuote.Tests.ps1` (21 tests) and the Good fixture `Examples\Good\CorrectTypographicQuoteEscape.ps1`; the export-count test now expects 15 functions. Suite total 155 per host.

## 0.1 (2026-11-11 update, no version bump)

Fixes from an independent code review. **Exit codes change**: a run that skipped files is no longer reported clean.

- **Files that were not checked make the run NOT clean.** `PSHG-TestScriptErrorHandling`, `PSHG-InvokeSilentFailureSweep`, `PSHG-TestBareKeywordCommand`, `PSHG-TestFinallyThrow`, `PSHG-TestGetNewClosureScope`, `PSHG-TestGetNewClosurePrivateScope`, `PSHG-TestJoinPathDriveRoot` and `PSHG-FindHardcodedWindowsPath` used to skip a missing, unreadable or unparseable file without a trace and finish "clean" (exit 0). They now list the file (`NOT CHECKED`) and exit 2 when nothing else was found (findings still exit 1). `PSHG-TestScriptErrorHandling` also raises a warning per skipped file so a caller that discards the information stream (the sweep does) still sees it. `PSHG-TestScriptSyntax` counts a missing/unreadable path or an analyzer error on a file as exit 1; `PSHG-TestFileEncoding` reports a missing, unreadable path as needing review (exit 2). A partial tree from a file with a parse error is still scanned, so findings in it are still reported. A class file whose only parse errors are unresolved sibling types (`TypeNotFound`) is scanned instead of skipped (matched by error id, not message text).
- `PSHG-FindHardcodedWindowsPath` now sets `$LASTEXITCODE` (1 = candidate sites found, 2 = none but files skipped, 0 = clean). `-Fix` no longer rewrites: anything in a `.psd1`; regex-escaped literals (doubled backslashes) or the operand of `-match`/`-replace`/`-split`; strings inside a script block, attribute or parameter default; or a literal in a command merely because the word `Path` appears elsewhere in that command's text (a decision site is now an assignment or an argument of a path-taking command or path-named parameter). It refuses a file that is not valid UTF-8 (previously such a file was re-encoded with replacement characters). Supports `-WhatIf`.
- `PSHG-TestFileEncoding -Fix`: a file that is only BOMs is repaired to one BOM (it used to write garbage); a BOM in front of a body that is not valid UTF-8 is reported for review and left untouched (it used to be counted compliant, or re-encoded with replacement characters after a doubled BOM); supports `-WhatIf`.
- `PSHG-TestModuleVersionSelfReference`: a version only matches at a boundary, so `0.1` no longer matches inside `0.17`, `0.10` or `0.1.5`; version folders with three or more numeric parts are recognised; a relative `-RootPath` is resolved so reported file names are correct.
- `PSHG-TestRepoLint`: PSScriptAnalyzer records that mean a file was not linted (unreadable file, parse error) now fail the run with exit 2 instead of passing; for rules other than the two defaults the baseline key now includes the enclosing function and an occurrence number (`Rule|Path|Token@Function#N`), so one accepted finding no longer accepts every later one in the file (baselines of non-default rules need regenerating); `-UpdateBaseline` requires `-BaselinePath` (the shipped baseline is a read-only template and was previously overwritten); a file outside `-RepoRoot` warns.
- `PSHG-TestScriptErrorHandling`: `-UpdateBaseline` requires `-Baseline`; a trailing slash on `-RepoRoot` is ignored; relative file names are resolved before baseline keys are computed; `-WrapperName`/`-CollectorName` must be plain function names; help and README now state that `-TestWrapper` executes code from the scanned file. `PSHG-InvokeSilentFailureSweep`: same `-Baseline` requirement.
- The AST checkers and `PSHG-TestScriptSyntax` folder mode now scan `.psm1` as well as `.ps1`. `PSHG-TestFinallyThrow` also finds a `throw` in a `catch` that sits inside a `finally`.
- Paths containing `[` or `]` are handled (literal-path parameters; the analyzer path is wildcard-escaped).
- `PSHG-FormatPS1File`, `PSHG-TestFileEncoding`, `PSHG-FindHardcodedWindowsPath` and both baseline writers replace files through a temp file in the same folder. The module refuses to load (instead of loading empty) when its `Functions` folder is missing or empty. Each function keeps its own `$Script:` state names.
- Tests: new `Tests\PSHygieneGuard.Review.Tests.ps1` (53 tests; 46 fail against the previous code, the rest guard behaviour that must not change). One existing closure-scope test now expects exit 2 for a file with a parse error and no findings.

## 0.1 (2026-11-08 update, no version bump)

- `PSHG-TestGetNewClosureScope` now has its own Pester coverage (plain-variable and nested-function findings, immediate-scope rule, exemptions, directory mode, error paths).
- `PSHG-TestGetNewClosureScope`: the documented exemption for `$Script:`, `$Global:` and `$using:` variables now works. It tested `VariablePath.DriveName`, which the parser leaves empty for scope modifiers, so those variables were reported as plain-variable findings and a plain reference to a name assigned via `$Script:`/`$Global:` elsewhere in the file was not exempted. It now uses `IsScript`/`IsGlobal` and recognises `$using:` (including `$using:X.Prop` and `$using:X[0]`). Every other finding is unchanged.

## 0.1 (2026-11-07 update, no version bump)

Two guards added in the 2026-11-03 update did not take effect; both now do:

- `PSHG-InvokeSilentFailureSweep`: the background job's error list is now copied before the job is removed (removing the job empties it), so errors from a failed scan are counted, printed, and a scan that errored and found nothing exits 2 as documented. Previously such a scan still exited 0.
- `PSHG-TestRepoLint`: an unparsable baseline file is now a terminating error, so the "Cannot read baseline" message naming the file and exit 2 are produced as documented. Previously the raw error was printed, the baseline was treated as empty and the run exited 1 with every finding reported as new.
- Both are covered by tests (previously held back), which were verified to fail when the fix is removed.
- Wording only: the summary hint printed by `PSHG-TestScriptErrorHandling` now points at the module README/help, and a few comments and example justification strings were made generic. No behaviour change.
- Tests: the PSHG-TestRepoLint empty-baseline test is now documented as a deliberate canary - without PSScriptAnalyzer it fails with an explanatory message while the other analyzer-dependent tests skip, so an environment that cannot see the analyzer is noticed. (No code change.)

## 0.1 (2026-11-03 update, no version bump)

Fixes from an independent review of the module:

- `PSHG-FormatPS1File` decodes the file as strict UTF-8 and REFUSES (file left unchanged, counted as a failure) on invalid bytes. Previously a genuinely ANSI file could be silently corrupted by the rewrite.
- `PSHG-TestRepoLint -UpdateBaseline -Path` now merges on a whole path segment, so scanning `Modules\App` no longer drops the accepted entries of a sibling such as `Modules\AppLegacy`.
- `PSHG-TestRepoLint`: a trailing slash on `-RepoRoot` is ignored; an unreadable or unparsable baseline file now prints the file name and exits 2 instead of failing with a raw error.
- `PSHG-InvokeSilentFailureSweep`: errors from the background scan job are printed, and a scan that errored and found nothing exits 2 (it used to look like a clean pass). The job's `-RepoRoot` is pinned to the caller's location.
- `PSHG-TestModuleVersionSelfReference`: a self-pin written as `-ModuleVersion <old>` (for example `Open-MyElevatedSession -ModuleName X -ModuleVersion <old>`) is now FUNCTIONAL, as `-RequiredVersion` already was. The module name must be on the same line as the version.
- Help and README: exit-code notes now say to call the function and then `exit $LASTEXITCODE`; new Exit codes section; function counts corrected to fourteen; project-specific incident detail removed from help text.

## 0.1 (2026-10-06 update, no version bump)

- Added `PSHG-TestJoinPathDriveRoot` (14th exported function): finds `Join-Path` called on a drive root built from a variable. `Join-Path` resolves the drive through the provider system and throws "Cannot find drive. A drive with the name 'X' does not exist." when it is not a live PSDrive, which breaks code meant to cope with a drive that may be absent (a USB drive plugged in after the session started, an unmounted VHD). Found in the field, in two production functions. AST-based (no PSScriptAnalyzer dependency), report-only, no baseline; a line carrying `# PSHG-OK: JoinPathDriveRoot` is skipped. Ships with a Good example (`Examples\Good\CorrectJoinPathDriveRoot.ps1`), a Bad example (`JoinPathDriveRoot.ps1` in `Examples\Bad.zip`), a demo line, 10 tests and and a user guide (`Docs\PSHG-TestJoinPathDriveRoot.md`).

## 0.1 (2026-09-12 update, no version bump)

### PSScriptAnalyzer cleanup
No `PSUseSingularNouns` findings at all in this module.
Fixed in place, no version branch (all remaining findings were either genuine gaps or deliberate
teaching fixtures, nothing exported changed):

- Added `[OutputType([PSCustomObject[]])]` to `PSHG-FindDriveLetterAssumption` and
  `PSHG-FindHardcodedWindowsPath` (both build and return an array of finding rows).
- Added `SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', ...)` to the three
  `Examples\Good\` fixture functions that tripped it (`New-ClickHandler`, and `Remove-TempFile`/
  `Stop-BackgroundJob` across the three empty-catch resolution fixtures) - each is illustrative code
  for a different checker's documentation, not real production logic; the verb-is-the-purpose
  reasoning still applies to what each fixture's function actually does.
- Added `SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', ...)` to
  `CorrectEmptyCatch-InlineComment.ps1`'s deliberately-empty catch - it specifically demonstrates
  the `# SILENT-OK:` inline-comment convention, which PSScriptAnalyzer's rule doesn't
  recognize (only `PSHG-InvokeSilentFailureSweep` does); suppressing documents that the finding is
  expected without changing what the fixture teaches.
- Added `PSScriptAnalyzerSettings.psd1`, including a third exclusion beyond the usual parser-noise +
  `PSAvoidUsingWriteHost` pair: `PSMissingModuleManifestField`, which fires on
  `PSHygieneGuardBaseline\ErrorHandling-Baseline.psd1` (a plain data file, not a module manifest) -
  a typical parser-noise case.
- Not addressed (outside Phase-1 scope, matches Pass 1/2 precedent): 13 `PSUseApprovedVerbs` findings
  (the module's own `PSHG-` prefix convention predates and deliberately departs from the standard
  Verb-Noun scheme) and 6 `PSUseUsingScopeModifierInNewRunspaces` findings.

Full release pipeline (format/syntax/repo-lint/silent-failure-sweep/encoding) clean prior to deploy.

## 0.1 - 2026-09-02

Initial release. Twelve functions covering syntax/lint, encoding, formatting, and five
narrow AST-based checkers for silent-runtime-failure defect classes (bare-keyword misparse,
throw-inside-Finally, two `.GetNewClosure()` scope-capture checkers, drive-letter
assumptions, module version self-reference), plus a baseline-gated repo lint gate and a
silent-failure-antipattern auditor with its own bulk-sweep driver.

Migrated from a private repository's internal `Tools\` folder, generalized to remove every
repo-specific assumption (hardcoded module-tree layouts, machine-pair paths), converted from
standalone scripts to real module functions (`PSHG-` prefix), and reshipped with empty
baseline templates plus a full Examples/Demo/Tests set.
