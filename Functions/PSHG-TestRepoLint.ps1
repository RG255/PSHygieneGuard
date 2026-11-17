Function PSHG-TestRepoLint
{
	<#
		.SYNOPSIS
		Baseline-gated PSScriptAnalyzer check that reports only NEW findings.

		.DESCRIPTION
		Runs PSScriptAnalyzer over the target tree, then compares the result against a baseline
		of known-and-accepted findings.

		The point of the baseline is that the rules stay SWITCHED ON. Accepted debt (e.g. an
		exported plural-noun function name that cannot be renamed without breaking a published
		API) is recorded once and stays quiet, while anything NEWLY written still fails the
		check. An ExcludeRules list would silence new code too, which is the opposite of what
		is wanted.

		Findings are keyed on RuleName + relative path + function name, NEVER on line number,
		so ordinary edits above a finding do not resurrect it as "new".

		.PARAMETER Rule
		Rules to gate on. Defaults to two that commonly recur (ShouldProcess, plural nouns).

		.PARAMETER UpdateBaseline
		Rewrite the baseline from the current scan. Use this ONLY after deliberately accepting
		the findings it contains - it is how debt gets recorded, so review the diff it prints
		before committing. Does NOT fix any code - see the README's Detect-only/Auto-fix table.

		.PARAMETER All
		Report every finding, baselined or not (audit view; does not affect the return code).

		.PARAMETER Path
		Tree to scan. Defaults to the current directory when omitted.

		.PARAMETER BaselinePath
		Path to the baseline .psd1. Defaults to PSHygieneGuardBaseline\RepoLint-Baseline.psd1,
		resolved relative to this module's own location - so a fresh clone works with zero
		configuration, but any consumer can point this at their own baseline file/location.

		.PARAMETER RepoRoot
		Root the baseline's relative paths are computed from. Defaults to the current directory
		(so a fresh clone works with zero configuration when run from the repo root), but any
		caller that cannot guarantee its own working directory - an orchestrator, a scheduled
		task, a wrapper invoked from an unpredictable CWD - should pass this explicitly.
		Relying on the ambient working directory means a caller sitting in a subfolder gets false
		"NEW" findings for entries already accepted in the baseline, because every relative path is
		computed too deep to match. A trailing slash on the value is ignored.

		.EXAMPLE
		PSHG-TestRepoLint -Path 'C:\MyProject' -RepoRoot 'C:\MyProject' -BaselinePath 'C:\MyProject\RepoLint-Baseline.psd1'
		Gate: returns 1 if any finding in C:\MyProject is not in the baseline.

		.EXAMPLE
		PSHG-TestRepoLint -Path 'C:\MyProject' -RepoRoot 'C:\MyProject' -All
		Show accepted debt alongside new findings.

		.NOTES
		Requires PSScriptAnalyzer - see README.md's Requirements section for the exact pinned
		version and install command.
		Returns 0 = no new findings (or the baseline was written), 1 = new findings, 2 = PSScriptAnalyzer
		is not installed (rather than dying with a CommandNotFoundException), PSScriptAnalyzer reported errors
		for some files (they were not linted, so the run is not a pass; the errors are printed), the baseline
		file cannot be read/parsed (the message names the file), or -UpdateBaseline was given without
		-BaselinePath. Wrap the call in `PSHG-TestRepoLint ...; exit $LASTEXITCODE` for a process exit code.

		-UpdateBaseline requires -BaselinePath: the baseline shipped inside the module is an empty template and is
		never written. Baseline keys for the two default rules are RuleName|RelativePath|FunctionName. For any other
		-Rule the function name is not in the analyzer message, so the key is RuleName|RelativePath|Token@EnclosingFunction#N
		(N counts repeats of the same token in the same function), which keeps one accepted finding from accepting
		every later one in the file. A file outside -RepoRoot produces a warning, because its key would hold an
		absolute path; pass -RepoRoot when -Path is not under the current directory.

		-UpdateBaseline together with -Path is a MERGE: only entries whose path lies inside the scanned
		folder are replaced; entries for sibling folders are kept (a folder named 'App' does not match
		'AppLegacy'). An unscoped -UpdateBaseline rewrites the whole baseline.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Coloured console report is the entire purpose of this function (matches this toolkit''s convention)')]
	[CmdletBinding()]
	Param (
		[String[]]$Rule = @('PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns'),
		[Switch]$UpdateBaseline,
		[Switch]$All,
		[String]$Path,
		[String]$BaselinePath,
		[String]$RepoRoot
	)

	If (-not $RepoRoot) { $RepoRoot = $PWD.ProviderPath }

	# The baseline shipped inside the module is an empty read-only template shared by every project on the
	# machine (and lost on a module update): reading it is fine, writing it is refused.
	If ($UpdateBaseline -and -not $BaselinePath)
	{
		Write-Host 'REFUSED: -UpdateBaseline needs an explicit -BaselinePath <your project baseline file>; the baseline shipped inside the module is a read-only template.' -ForegroundColor Red
		$Global:LASTEXITCODE = 2; return
	}
	If (-not $BaselinePath)
	{
		$BaselinePath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'PSHygieneGuardBaseline\RepoLint-Baseline.psd1'
	}
	$BaselineFile = $BaselinePath

	If (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer))
	{
		Write-Host 'PSScriptAnalyzer is not installed on this machine - cannot lint.' -ForegroundColor Yellow
		Write-Host 'Install it - see README.md''s Requirements section.' -ForegroundColor Yellow
		$Global:LASTEXITCODE = 2; return
	}
	Import-Module -Name PSScriptAnalyzer -ErrorAction Stop

	# --- which tree(s) to scan --------------------------------------------------
	If ($Path)
	{
		If (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: [{0}]' -f $Path) }
		$Targets = @((Resolve-Path -LiteralPath $Path).ProviderPath)
	}
	Else
	{
		$Targets = @($RepoRoot)
	}

	# Read-only reference trees that must never be edited, plus generated fixtures.
	$ExcludePattern = '\\Original(s)?\\|\\_RetiredModules\\|\\\.git\\'

	# --- scan ------------------------------------------------------------------
	Function Get-PSHGLintFinding
	{
		[CmdletBinding()]
		Param ([String[]]$Target, [String[]]$RuleName, [String]$Skip, [System.Collections.Generic.List[String]]$AnalyzerProblem)

		$Found = @()
		ForEach ($T in $Target)
		{
			# -Path takes wildcards, so [ and ] in a folder name are escaped. A file the analyzer could not
			# process contributes no findings, so its errors are collected and make the run fail (exit 2).
			$AnalyzerErrors = $null
			$Raw = Invoke-ScriptAnalyzer -Path ([WildcardPattern]::Escape($T)) -Recurse -IncludeRule $RuleName -ErrorAction SilentlyContinue -ErrorVariable AnalyzerErrors
			ForEach ($AnalyzerError in $AnalyzerErrors) { $AnalyzerProblem.Add($AnalyzerError.ToString()) }
			# A file the analyzer could not read or parse comes back as a ParseError-severity record (FileReadError,
			# MissingEndCurlyBrace, ...), not as an error. TypeNotFound-style records are class-resolution noise.
			ForEach ($Diagnostic in @($Raw | Where-Object { $_.Severity -eq 'ParseError' -and $_.RuleName -notin $RuleName -and $_.RuleName -notin 'TypeNotFound', 'MemberAlreadyDefined', 'AmbiguousTypeReference' }))
			{ $AnalyzerProblem.Add(('{0}: {1}: {2}' -f $Diagnostic.ScriptPath, $Diagnostic.RuleName, $Diagnostic.Message)) }
			# PSSA also emits parse diagnostics (TypeNotFound / MemberAlreadyDefined /
			# AmbiguousTypeReference) through this same channel - they are NOT findings
			# for the requested rules and wrongly inflate every count if kept.
			$Found += $Raw | Where-Object { $_.RuleName -in $RuleName }
		}
		return $Found | Where-Object { $_.ScriptPath -notmatch $Skip }
	}

	Write-Host ('Linting {0} tree(s) for {1} rule(s)...' -f $Targets.Count, $Rule.Count) -ForegroundColor Cyan
	$AnalyzerProblem = [System.Collections.Generic.List[String]]::new()
	$Findings = Get-PSHGLintFinding -Target $Targets -RuleName $Rule -Skip $ExcludePattern -AnalyzerProblem $AnalyzerProblem
	If ($AnalyzerProblem.Count -gt 0)
	{
		Write-Host ("`nPSScriptAnalyzer reported {0} error(s); the files they concern were NOT linted, so this is NOT a pass:" -f $AnalyzerProblem.Count) -ForegroundColor Red
		$AnalyzerProblem | Select-Object -First 10 | ForEach-Object { Write-Host ('  {0}' -f $_) -ForegroundColor Red }
		$Global:LASTEXITCODE = 2; return
	}

	# --- normalise to stable keys ---------------------------------------------
	$Escaped = [Regex]::Escape($RepoRoot.TrimEnd('\', '/'))
	$GatedByName = @('PSUseShouldProcessForStateChangingFunctions', 'PSUseSingularNouns')
	$AstCache = @{}
	$OccurrenceCount = @{}
	$RootWarned = $false
	$Rows = @($Findings | Sort-Object ScriptPath, Line | ForEach-Object {
			$Rel = $_.ScriptPath -replace ('^{0}\\' -f $Escaped), ''
			If ($Rel -eq $_.ScriptPath -and -not $RootWarned)
			{
				$RootWarned = $true
				Write-Warning ('PSHG-TestRepoLint: [{0}] is outside -RepoRoot [{1}], so its baseline key holds an absolute path and will not match a baseline written elsewhere. Pass -RepoRoot.' -f $_.ScriptPath, $RepoRoot)
			}
			# The function name is in the message for both gated rules; fall back to the
			# file name so a key always exists even if a message format changes.
			$Func = if ($_.Message -match "'([^']+)'") { $Matches[1] } else { Split-Path $_.ScriptPath -Leaf }
			If ($_.RuleName -notin $GatedByName)
			{
				# Other rules do not put the function in the message, so one baselined finding could accept every
				# later one in the file. Qualify the key with the enclosing function and the occurrence number.
				If (-not $AstCache.ContainsKey($_.ScriptPath))
				{
					$AstCache[$_.ScriptPath] = [System.Management.Automation.Language.Parser]::ParseFile($_.ScriptPath, [ref]$null, [ref]$null)
				}
				$Line = $_.Line
				$Enclosing = @($AstCache[$_.ScriptPath].FindAll({ Param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $N.Extent.StartLineNumber -le $Line -and $N.Extent.EndLineNumber -ge $Line }, $true) |
						Sort-Object { $_.Extent.StartOffset } -Descending | Select-Object -First 1)
					$Scope = If ($Enclosing.Count -gt 0) { $Enclosing[0].Name } Else { '(script)' }
					$CountKey = '{0}|{1}|{2}|{3}' -f $_.RuleName, $Rel, $Func, $Scope
					$OccurrenceCount[$CountKey] = 1 + $(If ($OccurrenceCount.ContainsKey($CountKey)) { $OccurrenceCount[$CountKey] } Else { 0 })
					$Func = '{0}@{1}#{2}' -f $Func, $Scope, $OccurrenceCount[$CountKey]
				}
				[PSCustomObject]@{
					Key      = ('{0}|{1}|{2}' -f $_.RuleName, $Rel, $Func)
					RuleName = $_.RuleName
					File     = $Rel
					Function = $Func
					Line     = $_.Line
				}
			} | Sort-Object Key -Unique)

	# --- baseline -------------------------------------------------------------
	$Baseline = @{}
	If (Test-Path -LiteralPath $BaselineFile)
	{
		try { $Data = Import-PowerShellDataFile -LiteralPath $BaselineFile -ErrorAction Stop }
		catch
		{
			Write-Host ('Cannot read baseline [{0}]: {1}' -f $BaselineFile, $_.Exception.Message) -ForegroundColor Red
			$Global:LASTEXITCODE = 2; return
		}
		ForEach ($Entry in $Data.Accepted) { $Baseline[$Entry] = $true }
	}

	If ($UpdateBaseline)
	{
		$Added = @($Rows | Where-Object { -not $Baseline.ContainsKey($_.Key) })

		# SAFETY: -UpdateBaseline used to WHOLESALE REPLACE the entire baseline with only what
		# THIS run scanned. Combined with -Path (scoping to one subtree), that could silently
		# delete every other subtree's accepted debt in one command. Fix: when -Path is given,
		# MERGE - keep every existing entry whose RelativePath falls OUTSIDE what was actually
		# scanned untouched, and only reconcile entries for files that were genuinely looked at
		# this run. Only a full, unscoped -UpdateBaseline (the routine "prune the whole tree's
		# stale entries" maintenance mode) is allowed to drop entries for files it did not scan.
		$FinalKeys = [System.Collections.Generic.List[String]]::new()
		ForEach ($R in $Rows) { $FinalKeys.Add($R.Key) }
		If ($Path)
		{
			$Private:_scannedRoot = (Resolve-Path -LiteralPath $Path).ProviderPath
			$Private:_scannedRel  = $Private:_scannedRoot -replace ('^{0}\\' -f $Escaped), ''
			ForEach ($Private:_k in $Baseline.Keys)
			{
				# Key shape: RuleName|RelativePath|FunctionName - preserve anything whose RelativePath
				# is not under the scanned scope, exactly as-is.
				$Private:_relPath = ($Private:_k -split '\|')[1]
				# Path-boundary test: 'Modules\App' must not swallow 'Modules\AppLegacy\...'.
				If (-not ($Private:_relPath -eq $Private:_scannedRel -or
						$Private:_relPath -like ('{0}\*' -f $Private:_scannedRel)))
				{ $FinalKeys.Add($Private:_k) }
			}
			$Removed = @($Baseline.Keys | Where-Object { $_ -notin $FinalKeys })
		}
		Else
		{ $Removed = @($Baseline.Keys | Where-Object { $_ -notin $Rows.Key }) }
		$FinalKeys = @($FinalKeys | Sort-Object -Unique)

		$Out = [System.Collections.Generic.List[String]]::new()
		$Out.Add('<#')
		$Out.Add('    Accepted PSScriptAnalyzer findings - the repo lint BASELINE.')
		$Out.Add('')
		$Out.Add('    Each entry is RuleName|RelativePath|FunctionName (NO line number, so')
		$Out.Add('    edits above a finding do not resurrect it). PSHG-TestRepoLint reports')
		$Out.Add('    only findings that are NOT listed here, so the rules stay ON for new')
		$Out.Add('    code while existing accepted debt stays quiet.')
		$Out.Add('')
		$Out.Add('    Do NOT hand-edit to silence something new - fix the code, or add it')
		$Out.Add('    deliberately via -UpdateBaseline and say why in the commit/todo.')
		$Out.Add('')
		$Out.Add(('    Regenerated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
		$Out.Add(('    Entries: {0}' -f $FinalKeys.Count))
		$Out.Add('#>')
		$Out.Add('@{')
		$Out.Add('    Accepted = @(')
		ForEach ($K in $FinalKeys)
		{ $Out.Add(("        '{0}'" -f ($K -replace "'", "''"))) }
		$Out.Add('    )')
		$Out.Add('}')
		$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
		Write-PSHGFileAtomic -Path $BaselineFile -Bytes ([Byte[]]($Utf8Bom.GetPreamble() + $Utf8Bom.GetBytes((($Out -join "`r`n") + "`r`n"))))

		Write-Host ("`nBaseline written: {0}" -f $BaselineFile) -ForegroundColor Green
		Write-Host ('  {0} entr(ies) total, {1} added, {2} no longer present' -f $FinalKeys.Count, $Added.Count, $Removed.Count)
		ForEach ($A in $Added)   { Write-Host ('  + {0}' -f $A.Key) -ForegroundColor Yellow }
		ForEach ($R in $Removed) { Write-Host ('  - {0}' -f $R) -ForegroundColor DarkGray }
		$Global:LASTEXITCODE = 0; return
	}

	# --- report --------------------------------------------------------------
	$New      = @($Rows | Where-Object { -not $Baseline.ContainsKey($_.Key) })
	$Accepted = @($Rows | Where-Object { $Baseline.ContainsKey($_.Key) })

	If ($All -and $Accepted)
	{
		Write-Host ("`nAccepted (baselined) findings - {0}:" -f $Accepted.Count) -ForegroundColor DarkGray
		ForEach ($A in ($Accepted | Sort-Object RuleName, File))
		{ Write-Host ('  {0}  {1}:{2}  [{3}]' -f $A.Function, $A.File, $A.Line, ($A.RuleName -replace '^PSUse', '')) -ForegroundColor DarkGray }
	}

	# A baseline entry that no longer fires means the code got fixed - prompt a refresh
	# so the debt list shrinks instead of quietly rotting. ONLY meaningful on a FULL
	# scan: with -Path every entry outside the scanned subset looks "fixed".
	$Stale = if ($Path) { @() } else { @($Baseline.Keys | Where-Object { $_ -notin $Rows.Key }) }
	If ($Stale)
	{
		Write-Host ("`n{0} baseline entr(ies) no longer fire (fixed) - re-run with -UpdateBaseline to shrink the list:" -f $Stale.Count) -ForegroundColor Cyan
		ForEach ($S in $Stale) { Write-Host ('  - {0}' -f $S) -ForegroundColor Cyan }
	}

	If ($New.Count -eq 0)
	{
		Write-Host ("`nPASS - no new findings ({0} accepted, {1} rule(s) gated)." -f $Accepted.Count, $Rule.Count) -ForegroundColor Green
		$Global:LASTEXITCODE = 0; return
	}

	Write-Host ("`nFAIL - {0} NEW finding(s):" -f $New.Count) -ForegroundColor Red
	ForEach ($N in ($New | Sort-Object RuleName, File))
	{
		Write-Host ('  [{0}] {1}' -f ($N.RuleName -replace '^PSUse', ''), $N.Function) -ForegroundColor Red
		Write-Host ('      {0}:{1}' -f $N.File, $N.Line)
	}
	Write-Host ''
	Write-Host 'Fix the code, or - if the finding is deliberate - suppress it inline with a' -ForegroundColor Yellow
	Write-Host 'Justification, or accept it via -UpdateBaseline. See README.md.' -ForegroundColor Yellow
	$Global:LASTEXITCODE = 1; return
}
