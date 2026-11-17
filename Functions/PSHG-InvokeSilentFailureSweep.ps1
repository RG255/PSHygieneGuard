Function PSHG-InvokeSilentFailureSweep
{
	<#
		.SYNOPSIS
		Runs PSHG-TestScriptErrorHandling across a tree and summarises the findings by rule.

		.DESCRIPTION
		The bulk-audit driver for the silent-failure checker. Scans every .ps1/.psm1 under
		-Path, skipping Original(s)\ and Tests\. Examples\ is NOT skipped - Bad\ is expected to
			be flagged, and Good\ is expected to pass clean; the checker recognizes the same
			SILENT-OK/SuppressMessageAttribute opt-outs a Good\ example uses to demonstrate a
			resolution, so "good" content genuinely comes out clean rather than being exempted
			from the scan.

		!! MEASUREMENT TRAP this function exists to avoid: PSHG-TestScriptErrorHandling reports
		via Write-Host, which writes to the INFORMATION stream. A sweep that captures with
		'2>&1' collects NOTHING and reports zero findings across the board - which happens
		silently and looks entirely plausible. Findings are also emitted as OBJECTS on the
		success stream, and that is what this function consumes. If a sweep ever reports a
		clean sheet across a large tree, disbelieve it and check the stream first.

		.PARAMETER Path
		Tree to scan. Defaults to the current directory.

		.PARAMETER Csv
		Write the per-finding detail to this path.

		.PARAMETER IncludeWeak
		Pass -IncludeWeak through to the checker (adds advisory AP6w rows).

		.PARAMETER Baseline
		Passed through to PSHG-TestScriptErrorHandling's -Baseline.

		.PARAMETER UpdateBaseline
		Passed through to the checker. -UpdateBaseline records the CURRENT findings as
		accepted (new rows marked TODO - give each a real reason). Does NOT fix any code -
		see the README's Detect-only/Auto-fix table.

		.PARAMETER PruneStale
		Passed through to the checker. With -UpdateBaseline, delete entries this run looked
		for and did not find.

		.PARAMETER ShowAccepted
		Passed through to the checker.

		.PARAMETER Rule
		Limit the report to one or more specific AP rules (e.g. 'AP9', or 'AP6','AP9' together).
		Filters AFTER the full scan - every rule still runs, this only narrows what gets tallied,
		listed, and written to -Csv. Saves hand-rolling a
		`Where-Object Rule -eq 'AP9'` scratch script mid-triage to focus on one category at a time -
		see PSHG-TestScriptErrorHandling's help for what each AP number means.

		.EXAMPLE
		PSHG-InvokeSilentFailureSweep -Path 'C:\MyProject'

		.EXAMPLE
		PSHG-InvokeSilentFailureSweep -Path 'C:\MyProject' -Csv .\findings.csv

		.EXAMPLE
		PSHG-InvokeSilentFailureSweep -Path 'C:\MyProject' -Rule AP9
		Only report AP9 (silently-swallowed, no signal at all) findings - useful when triaging one
		category at a time instead of the whole mixed list.

		.NOTES
		Returns 0 = no findings and every file checked, 1 = findings, 2 = no findings but the scan was
		incomplete: the background scan reported errors, or at least one file could not be read or parsed (NOT a
		clean result; the errors and the skipped files are printed). Wrap the call in
		`PSHG-InvokeSilentFailureSweep ...; exit $LASTEXITCODE` for a process exit code.
		-UpdateBaseline requires -Baseline <file>; the baseline shipped inside the module is never written.
	#>
	[CmdletBinding()]
	Param (
		[String]$Path = $PWD.ProviderPath,
		[String]$Csv,
		[Switch]$IncludeWeak,
		[String]$Baseline,

		# Safe across a large sweep: PSHG-TestScriptErrorHandling reloads the baseline file each
		# call, so entries accumulate rather than the last file overwriting the rest.
		[Switch]$UpdateBaseline,

		# With -UpdateBaseline, delete entries this run looked for and did not find. Scoped to
		# the files actually scanned by THIS call, so a -Path-scoped sweep cannot remove another
		# subtree's entries - see PSHG-TestScriptErrorHandling's own -PruneStale notes.
		[Switch]$PruneStale,
		[Switch]$ShowAccepted,

		# Passed through to PSHG-TestScriptErrorHandling's -KnownSignalFunction - one or more
		# function names that, if called inside a catch body, count as genuinely signaling the
		# failure (e.g. your own codebase's audit-trail/logging function). Not set by default.
		[String[]]$KnownSignalFunction = @(),

		# Passed through to PSHG-TestScriptErrorHandling's -RepoRoot - root the baseline's relative
		# paths are computed from. Defaults there to $PWD if not set here either; pass explicitly
		# from anything that cannot guarantee its own working directory (an orchestrator, a
		# scheduled task) - same reasoning as PSHG-TestRepoLint's own -RepoRoot.
		[String]$RepoRoot,

		# Post-scan filter, not passed through to the checker - see .PARAMETER Rule above.
		[String[]]$Rule
	)

	If (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: [{0}]' -f $Path) }
	$Private:Root = (Resolve-Path -LiteralPath $Path).ProviderPath

	$Files = Get-ChildItem -LiteralPath $Private:Root -Recurse -File -ErrorAction SilentlyContinue |
		Where-Object { $_.Extension -in '.ps1', '.psm1' -and
			$_.FullName -notmatch '\\(Original|Originals|Tests)\\' }

	If (-not $Files)
	{
		Write-Host ('No .ps1/.psm1 files found under [{0}]' -f $Private:Root) -ForegroundColor Yellow
		$Global:LASTEXITCODE = 0; return
	}

	# NOT $Args - that is a PowerShell automatic variable (PSAvoidAssignmentToAutomaticVariable).
	$ToolArgs = @{ Quiet = $true }
	if ($IncludeWeak)    { $ToolArgs['IncludeWeak']    = $true }
	if ($Baseline)       { $ToolArgs['Baseline']       = $Baseline }
	if ($UpdateBaseline) { $ToolArgs['UpdateBaseline'] = $true }
	if ($PruneStale)     { $ToolArgs['PruneStale']     = $true }
	if ($ShowAccepted)   { $ToolArgs['ShowAccepted']   = $true }
	if ($KnownSignalFunction) { $ToolArgs['KnownSignalFunction'] = $KnownSignalFunction }
	# Start-Job does NOT inherit the caller's location, so the checker's own $PWD default would be
	# evaluated against the job's working directory. Pin it to the caller's location here.
	$ToolArgs['RepoRoot'] = $(if ($RepoRoot) { $RepoRoot } else { (Get-Location).ProviderPath })

	# RUN PSHG-TestScriptErrorHandling IN A GENUINELY SEPARATE JOB, not an in-process function
	# call. When it was called as an ordinary function from inside this sibling exported
	# function over a large multi-file pipeline (even with explicit Module\Command qualification,
	# or via a hand-rolled child process using Export-Clixml and a separate pwsh.exe -File), it
	# intermittently failed with "term not recognized" for one of its OWN Begin-scoped helper
	# functions (a different one each run, although each was confirmed present). The cause was
	# never isolated; it could not be reproduced when the same child-process logic was run from a
	# standalone top-level script, so it appears tied to the live call stack of the orchestrating
	# function. Start-Job sidesteps that by handing the whole unit of work to PowerShell's
	# standard, process-isolated job mechanism.
	$Private:ModulePath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'PSHygieneGuard.psd1'
	$Private:Job = Start-Job -ScriptBlock {
		Param($ModulePath, $Files, $ToolArgs)
		Import-Module $ModulePath -Force -WarningAction SilentlyContinue
		$Private:Scan = @($Files | PSHG-TestScriptErrorHandling @ToolArgs 6>$null)
		[PSCustomObject]@{ Findings = $Private:Scan; ExitCode = $Global:LASTEXITCODE }
	} -ArgumentList $Private:ModulePath, $Files.FullName, $ToolArgs

	$null = Wait-Job -Job $Private:Job
	$Private:Result = @(Receive-Job -Job $Private:Job) | Where-Object { $_.PSObject.Properties['ExitCode'] } | Select-Object -Last 1
	$Found = if ($Private:Result) { @($Private:Result.Findings) } else { @() }
	# Snapshot the job's error and warning lists BEFORE Remove-Job: removing the job empties them.
	$Private:JobErrors = @($Private:Job.ChildJobs[0].Error)
	$Private:SkipWarnings = @($Private:Job.ChildJobs[0].Warning | ForEach-Object { $_.Message } | Where-Object { $_ -like 'SKIPPED *' })
	Remove-Job -Job $Private:Job -Force -ErrorAction SilentlyContinue

	# -Rule filters AFTER the full scan (every rule still ran) - see .PARAMETER Rule.
	If ($Rule) { $Found = @($Found | Where-Object { $_.Rule -in $Rule }) }

	If ($Private:JobErrors.Count -gt 0)
	{
		Write-Host ('WARNING: {0} error(s) reported by the background job - results below may be incomplete:' -f $Private:JobErrors.Count) -ForegroundColor Red
		$Private:JobErrors | Select-Object -First 5 | ForEach-Object { Write-Host ('  {0}' -f $_) -ForegroundColor Red }
		# A scan that errored did not necessarily run: never report it as a clean pass.
		$Private:ScanIncomplete = $true
	}
	If ($Private:SkipWarnings.Count -gt 0)
	{
		Write-Host ('NOT CHECKED - {0} file(s) were skipped (unreadable or unparseable), so this is NOT a clean result:' -f $Private:SkipWarnings.Count) -ForegroundColor Red
		$Private:SkipWarnings | ForEach-Object { Write-Host ('  {0}' -f $_) -ForegroundColor Red }
		$Private:ScanIncomplete = $true
	}
	# The checker itself ended with exit 2 (or never returned a result): incomplete even if no message was captured.
	If (-not $Private:Result -or ($Private:Result.ExitCode -eq 2 -and $Found.Count -eq 0)) { $Private:ScanIncomplete = $true }

	$Tally = @{}
	$Details = @()
	foreach ($F in $Found)
	{
		$Tally[$F.Rule] = 1 + $(if ($Tally.ContainsKey($F.Rule)) { $Tally[$F.Rule] } else { 0 })
		# Key and Path are carried through deliberately, not just the leaf file name, so a CSV
		# reader can tell which baseline entry a finding corresponds to without re-deriving keys
		# by hand.
		$Details += [PSCustomObject]@{
			File = (Split-Path $F.File -Leaf)
			Line = $F.Line
			Rule = $F.Rule
			Text = $F.Text
			Key  = $F.Key
			Path = $F.File
		}
	}

	Write-Host ''
	Write-Host '=== FINDINGS ===' -ForegroundColor Cyan
	# An explicit width keeps every rule column visible - Format-Table -AutoSize can silently
	# DROP trailing columns when the table is wider than the host.
	[PSCustomObject]@{
		Files = $Files.Count
		Total = $Found.Count
		AP1 = $Tally['AP1']; AP2 = $Tally['AP2']; AP3 = $Tally['AP3']; AP4 = $Tally['AP4']
		AP5 = $Tally['AP5']; AP6 = $Tally['AP6']; AP7 = $Tally['AP7']; AP8 = $Tally['AP8']
		AP9 = $Tally['AP9']; AP10 = $Tally['AP10']; AP11 = $Tally['AP11']; AP12 = $Tally['AP12']
	} | Format-Table -Property Files, Total, AP1, AP2, AP3, AP4, AP5, AP6, AP7, AP8, AP9, AP10, AP11, AP12 |
		Out-String -Width 190 | Write-Host

	Write-Host '=== TOTALS BY RULE ===' -ForegroundColor Cyan
	$Details | Group-Object Rule | Sort-Object Name |
		ForEach-Object { Write-Host ('  {0}: {1}' -f $_.Name, $_.Count) }

	if ($Csv)
	{
		$Details | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
		Write-Host ''
		Write-Host ('Detail: {0} row(s) -> {1}' -f $Details.Count, $Csv) -ForegroundColor DarkGray
	}

	Write-Host ''
	Write-Host ('TOTAL: {0} finding(s) across {1} file(s)' -f $Details.Count, $Files.Count) -ForegroundColor Yellow

	if ($Details.Count -gt 0) { $Global:LASTEXITCODE = 1; return }
	if ($Private:ScanIncomplete) { Write-Host 'Scan reported errors and found nothing: NOT a clean result (exit 2).' -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
	$Global:LASTEXITCODE = 0; return
}
