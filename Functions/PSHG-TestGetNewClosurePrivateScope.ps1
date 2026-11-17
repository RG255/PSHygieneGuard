Function PSHG-TestGetNewClosurePrivateScope
{
	<#
		.SYNOPSIS
		Finds a `$Private:`-prefixed variable referenced inside a `.GetNewClosure()`'d scriptblock
		that is never locally assigned within that same scriptblock - it is relying on being
		captured from the enclosing scope, which does not reliably work for `Private:`-scoped
		variables the way it does for plain ones.

		.DESCRIPTION
		`{ ... }.GetNewClosure()` snapshots the variables a scriptblock needs from its enclosing
		scope so the scriptblock keeps working once that scope is gone (e.g. a WPF event handler
		fired long after the function that built it has returned). Plain variables (`$Foo`) survive
		this snapshot correctly. `$Private:`-scoped variables do not - a reference to
		`$Private:_foo` inside the closure silently fails to resolve to the captured value, with
		no error, no warning, nothing - the condition/expression using it just quietly evaluates
		as if the variable were never set.

		This parses cleanly (no PSScriptAnalyzer finding, no parse error) and only fails at
		RUNTIME, by silently doing nothing - there is no exception, no log line, nothing to
		notice unless you already suspect this exact pattern.

		A `$Private:`-prefixed variable that IS assigned somewhere inside the same scriptblock is
		NOT flagged - it is genuinely local to that scriptblock's own execution (a fresh value each
		time the closure runs), not relying on outer-scope capture at all.

		Uses the PowerShell language parser's AST directly ([Parser]::ParseFile), not
		PSScriptAnalyzer - no PSSA dependency, so this also runs on machines where PSSA is not
		installed.

		Unlike a baseline-gated rule, this needs no baseline: there is no legitimate reason a
		`Private:`-scoped variable inside a closure should ever rely on outer-scope capture - every
		match is an actual bug, so a clean run means zero findings, not zero NEW findings.

		.PARAMETER Path
		File or directory to scan (recurses). Defaults to the current directory.

		.EXAMPLE
		PSHG-TestGetNewClosurePrivateScope

		.EXAMPLE
		PSHG-TestGetNewClosurePrivateScope -Path 'C:\MyProject'

		.NOTES
		Returns 0 = clean, 1 = at least one unresolved Private: capture found, 2 = no findings but at least
		one file could not be read or parsed (listed; NOT a clean result). Scans .ps1 and .psm1. Wrap the call in
		`PSHG-TestGetNewClosurePrivateScope ...; exit $LASTEXITCODE` for a process exit code.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console report is the entire purpose of this function (matches this toolkit''s convention)')]
	[CmdletBinding()]
	Param (
		[String]$Path = $PWD.ProviderPath
	)

	If (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: [{0}]' -f $Path) }
	$Private:Root = (Resolve-Path -LiteralPath $Path).ProviderPath

	$ExcludePattern = '\\Original(s)?\\|\\_RetiredModules\\|\\\.git\\'

	$Skipped = [System.Collections.Generic.List[String]]::new()
	$Files = @(Get-PSHGScanFile -Path $Private:Root -ExcludePattern $ExcludePattern -Problem $Skipped)

	Write-Host ('Scanning {0} file(s) for unresolved $Private: captures inside .GetNewClosure() scriptblocks...' -f $Files.Count) -ForegroundColor Cyan

	$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()
	$Private:Escaped = [Regex]::Escape($Private:Root)

	ForEach ($File in $Files)
	{
		$Private:_parsed = Read-PSHGAst -File $File
		If (-not $Private:_parsed.Ok)
		{ $Skipped.Add(('{0} ({1})' -f $File, $Private:_parsed.Reason)); If (-not $Private:_parsed.Ast) { Continue } }   # a partial tree is still scanned
		$Private:_ast = $Private:_parsed.Ast

		# Every `{ ... }.GetNewClosure()` call - the Expression of the member-invocation is the
		# scriptblock literal the closure snapshot is taken of.
		$Private:_invokes = $Private:_ast.FindAll(
			{
				Param($N)
				$N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
				$N.Member.Value -ieq 'GetNewClosure' -and
				$N.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
			}, $true)

		ForEach ($Private:_invoke in $Private:_invokes)
		{
			$Private:_sb = $Private:_invoke.Expression.ScriptBlock

			# Every $Private:-scoped variable REFERENCE anywhere in this scriptblock. "Private:" is
			# NOT a real PSDrive-style scope the way Script:/Global:/Local: are - the AST leaves
			# VariablePath.DriveName empty and stores the literal text "Private:_foo" in UserPath
			# instead (confirmed by direct AST inspection - do not assume DriveName here).
			$Private:_privVars = $Private:_sb.FindAll(
				{
					Param($N)
					$N -is [System.Management.Automation.Language.VariableExpressionAst] -and
					$N.VariablePath.UserPath -imatch '^Private:'
				}, $true)
			If ($Private:_privVars.Count -eq 0) { Continue }

			# Every variable name that IS locally assigned somewhere in this SAME scriptblock
			# (the LHS of an assignment) - these are genuinely local, not relying on outer-scope
			# capture, and must not be flagged regardless of scope prefix used to reference them.
			$Private:_assigns = $Private:_sb.FindAll(
				{
					Param($N)
					$N -is [System.Management.Automation.Language.AssignmentStatementAst] -and
					$N.Left -is [System.Management.Automation.Language.VariableExpressionAst]
				}, $true)
			$Private:_assignedNames = @($Private:_assigns | ForEach-Object { $_.Left.VariablePath.UserPath })

			$Private:_unresolved = $Private:_privVars | Where-Object { $_.VariablePath.UserPath -notin $Private:_assignedNames }
			ForEach ($Private:_v in ($Private:_unresolved | Sort-Object { $_.Extent.StartLineNumber } -Unique))
			{
				$Rel = $File -replace ('^{0}\\' -f $Private:Escaped), ''
				$Findings.Add([PSCustomObject]@{
						File = $Rel
						Line = $Private:_v.Extent.StartLineNumber
						Text = $Private:_v.Extent.Text
					})
			}
		}
	}

	$Findings = @($Findings | Sort-Object File, Line, Text -Unique)

	Write-PSHGSkipReport -Skipped $Skipped

	If ($Findings.Count -eq 0)
	{
		If ($Skipped.Count -gt 0)
		{ Write-Host ('NOT CLEAN - no findings, but {0} file(s) were not checked.' -f $Skipped.Count) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
		Write-Host 'PASS - no unresolved $Private: captures found.' -ForegroundColor Green
		$Global:LASTEXITCODE = 0; return
	}

	Write-Host ''
	ForEach ($F in $Findings)
	{
		Write-Host ('  {0}:{1}' -f $F.File, $F.Line) -ForegroundColor Red
		Write-Host ('    {0}' -f $F.Text) -ForegroundColor DarkGray
		Write-Host ('    Fix: rename to a plain (non-Private:) variable name captured by .GetNewClosure().') -ForegroundColor Yellow
	}
	Write-Host ''
	Write-Host ('FAIL - {0} finding(s). $Private: variables do not reliably survive .GetNewClosure() capture.' -f $Findings.Count) -ForegroundColor Red
	$Global:LASTEXITCODE = 1; return
}
