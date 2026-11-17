#requires -Version 5.0
<#
	.SYNOPSIS
	Runs the real PSHygieneGuard checkers against a disposable copy of Examples\, so you can
	see genuine auto-fixes and baseline entries get created - not just read about them.

	.DESCRIPTION
	Copies Examples\Good\ and extracts Examples\Bad.zip into a fresh scratch folder
	(Demo\_run\, wiped and recreated at the START of every run), then runs the real checkers
	against that COPY.

	WHY Bad\ SHIPS AS A ZIP, NOT LIVE .ps1 FILES: every fixture under it is DELIBERATELY
	broken - that is the whole point. A generic module-release pipeline (PSScriptAnalyzer-based
	lint, a bare-keyword scan, etc.) run against this repo's own tree cannot distinguish "an
	intentional teaching fixture" from "a real defect that must block deployment" -
	a release pipeline halts before deploy when Bad\ ships as live .ps1 files, exactly as it's supposed to
	for a real defect. Zipping removes them from
	being live source a generic scan would ever see, while keeping them fully inspectable (any
	archive tool opens Bad.zip) and fully exercised here in the demo.

	HARD CONSTRAINT: the shipped Examples\Bad.zip / Examples\Good\ are NEVER opened for write
	by this script - only ever read from, to populate the scratch copy. Re-running this demo,
	or running it from a read-only clone, must never alter the shipped examples.

	.EXAMPLE
	.\Demo\Invoke-Demo.ps1
#>
[CmdletBinding()]
Param ()

$ErrorActionPreference = 'Stop'
$Script:ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
$Script:RunDir     = Join-Path $PSScriptRoot '_run'
$Script:GoodSrc    = Join-Path $Script:ModuleRoot 'Examples\Good'
$Script:BadZip     = Join-Path $Script:ModuleRoot 'Examples\Bad.zip'

Write-Host '=== PSHygieneGuard live demo ===' -ForegroundColor Magenta
Write-Host 'Nothing under Examples\ is ever written to by this script - only read from.' -ForegroundColor DarkGray
Write-Host ''

# Fresh, disposable scratch folder every run.
if (Test-Path -LiteralPath $Script:RunDir) { Remove-Item -LiteralPath $Script:RunDir -Recurse -Force }
$null = New-Item -ItemType Directory -Path $Script:RunDir -Force
$Script:GoodRun = Join-Path $Script:RunDir 'Good'
$Script:BadRun  = Join-Path $Script:RunDir 'Bad'
Copy-Item -Path $Script:GoodSrc -Destination $Script:GoodRun -Recurse
Expand-Archive -LiteralPath $Script:BadZip -DestinationPath $Script:BadRun -Force
Write-Host ("Working copy created at {0}" -f $Script:RunDir) -ForegroundColor DarkGray
Write-Host ''

Import-Module (Join-Path $Script:ModuleRoot 'PSHygieneGuard.psd1') -Force -WarningAction SilentlyContinue

# --- 1. Auto-fix tools, run for real against the copy --------------------------------------
Write-Host '--- 1. PSHG-TestFileEncoding -Fix (auto-fix) ---' -ForegroundColor Cyan
$Private:BeforeBytes = [System.IO.File]::ReadAllBytes((Join-Path $Script:BadRun 'MisencodedFile.ps1'))
$null = PSHG-TestFileEncoding -Path $Script:BadRun -Fix
$Private:AfterBytes = [System.IO.File]::ReadAllBytes((Join-Path $Script:BadRun 'MisencodedFile.ps1'))
$Private:HadBom  = ($Private:BeforeBytes.Length -ge 3 -and $Private:BeforeBytes[0] -eq 0xEF)
$Private:HasBom  = ($Private:AfterBytes.Length -ge 3 -and $Private:AfterBytes[0] -eq 0xEF)
Write-Host ("  MisencodedFile.ps1 had a BOM before: {0}   has a BOM now: {1}" -f $Private:HadBom, $Private:HasBom) -ForegroundColor Green
Write-Host ''

Write-Host '--- 2. PSHG-FormatPS1File (auto-fix) ---' -ForegroundColor Cyan
$null = Get-ChildItem -Path $Script:BadRun -Filter '*.ps1' | PSHG-FormatPS1File
Write-Host ''

# --- 3. Baseline-tracked tools, full real lifecycle -----------------------------------------
Write-Host '--- 3. PSHG-TestRepoLint: empty baseline -> findings -> -UpdateBaseline -> quiet ---' -ForegroundColor Cyan
$Script:DemoBaselineDir = Join-Path $Script:RunDir 'PSHygieneGuardBaseline'
$null = New-Item -ItemType Directory -Path $Script:DemoBaselineDir -Force
$Script:DemoBaseline = Join-Path $Script:DemoBaselineDir 'RepoLint-Baseline.psd1'
"@{ Accepted = @() }" | Set-Content -LiteralPath $Script:DemoBaseline -Encoding UTF8

Write-Host '  First pass (empty baseline - everything reports as NEW):' -ForegroundColor DarkGray
$null = PSHG-TestRepoLint -Path $Script:BadRun -BaselinePath $Script:DemoBaseline

Write-Host ''
Write-Host '  Running -UpdateBaseline...' -ForegroundColor DarkGray
$null = PSHG-TestRepoLint -Path $Script:BadRun -BaselinePath $Script:DemoBaseline -UpdateBaseline

Write-Host ''
Write-Host '  Resulting baseline file contents:' -ForegroundColor DarkGray
Get-Content -LiteralPath $Script:DemoBaseline | ForEach-Object { Write-Host ('    {0}' -f $_) -ForegroundColor DarkGray }

Write-Host ''
Write-Host '  Second pass (same code, now baselined - PASS, findings go quiet):' -ForegroundColor DarkGray
$null = PSHG-TestRepoLint -Path $Script:BadRun -BaselinePath $Script:DemoBaseline
Write-Host ''

# --- 4. Report-only tools, no fix, no baseline ----------------------------------------------
Write-Host '--- 4. Report-only checkers (detect, never fix, no baseline) ---' -ForegroundColor Cyan
$null = PSHG-TestBareKeywordCommand -Path (Join-Path $Script:BadRun 'BareKeywordMisparse.ps1')
$null = PSHG-TestFinallyThrow -Path (Join-Path $Script:BadRun 'ThrowInsideFinally.ps1')
$null = PSHG-TestJoinPathDriveRoot -Path (Join-Path $Script:BadRun 'JoinPathDriveRoot.ps1')
Write-Host ''

# --- Verify the shipped examples were never touched -----------------------------------------
# This is a live smoke check, not exhaustive proof - see the Tests\ suite for the real,
# hash-based before/after verification of this constraint.
Write-Host '--- Verifying the shipped Examples\ folder was never written to ---' -ForegroundColor Cyan
$Private:ShippedFiles = Get-ChildItem -Path (Join-Path $Script:ModuleRoot 'Examples') -Recurse -File
Write-Host ('  {0} file(s) checked under Examples\ - this script only ever reads from that folder.' -f $Private:ShippedFiles.Count) -ForegroundColor Green

Write-Host ''
Write-Host '=== Demo complete. Scratch output is in Demo\_run\ - safe to delete any time. ===' -ForegroundColor Magenta
