Function PSHG-TestFinallyThrow
{
	<#
		.SYNOPSIS
		Finds a `throw` statement sitting inside a `Finally` block.

		.DESCRIPTION
		A `Finally` block runs on EVERY exit path out of its `Try` - including a normal, already-
		handled `return` from the `Catch` above it, not just when an exception is still propagating.
		A `throw` placed inside `Finally` therefore re-raises unconditionally regardless of how the
		Try/Catch above it actually exited, which can turn an already-reported, already-handled
		failure (or even a clean success) back into an uncaught exception.

		This parses cleanly (no PSScriptAnalyzer finding, no parse error) and is invisible to
		lint/silent-failure checkers - neither looks at what block a `throw` sits in.

		Unlike a baseline-gated rule, this needs no baseline: there is no legitimate reason a cleanup
		block should unconditionally re-throw regardless of how the guarded code exited - a genuine
		"re-raise the original exception" belongs in the `Catch` block (where it only fires when
		there actually was one), not in `Finally`. A clean run means zero findings, not zero NEW
		findings.

		Uses the PowerShell language parser's AST directly ([Parser]::ParseFile), not
		PSScriptAnalyzer - no PSSA dependency, so this also runs on machines where PSSA is not
		installed.

		.PARAMETER Path
		File or directory to scan (recurses). Defaults to the current directory.

		.EXAMPLE
		PSHG-TestFinallyThrow

		.EXAMPLE
		PSHG-TestFinallyThrow -Path 'C:\MyProject'

		.NOTES
		Returns 0 = clean, 1 = at least one throw-inside-Finally found, 2 = no findings but at least one
		file could not be read or parsed (listed; NOT a clean result). Scans .ps1 and .psm1. Wrap the call in
		`PSHG-TestFinallyThrow ...; exit $LASTEXITCODE` for a process exit code.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console report is the entire purpose of this tool (matches module convention)')]
	[CmdletBinding()]
	Param (
		[String]$Path = $PWD.ProviderPath
	)

	If (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: [{0}]' -f $Path) }
	$Private:Root = (Resolve-Path -LiteralPath $Path).ProviderPath

	$ExcludePattern = '\\Original(s)?\\|\\_RetiredModules\\|\\\.git\\'

	$Skipped = [System.Collections.Generic.List[String]]::new()
	$Files = @(Get-PSHGScanFile -Path $Private:Root -ExcludePattern $ExcludePattern -Problem $Skipped)

	Write-Host ('Scanning {0} file(s) for throw statements inside Finally blocks...' -f $Files.Count) -ForegroundColor Cyan

	$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()
	$Private:Escaped = [Regex]::Escape($Private:Root)

	ForEach ($File in $Files)
	{
		$Private:_parsed = Read-PSHGAst -File $File
		If (-not $Private:_parsed.Ok)
		{ $Skipped.Add(('{0} ({1})' -f $File, $Private:_parsed.Reason)); If (-not $Private:_parsed.Ast) { Continue } }   # a partial tree is still scanned
		$Private:_ast = $Private:_parsed.Ast

		$Private:_throws = $Private:_ast.FindAll(
			{ Param($N) $N -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)

		ForEach ($Private:_throw in $Private:_throws)
		{
			# Walk up the parent chain through every enclosing Try. The throw is in a Finally when the
			# node below some Try is that Try's Finally. A throw in the BODY of a Try that has a Catch is
			# handled there, so the walk stops; a throw in a Catch clause (or a catch-less Body) escapes
			# that Try, so the walk continues outward to any Finally that encloses it.
			$Private:_node = $Private:_throw
			$Private:_inFinally = $false
			While ($Private:_node.Parent)
			{
				$Private:_parent = $Private:_node.Parent
				If ($Private:_parent -is [System.Management.Automation.Language.TryStatementAst])
				{
					If ($Private:_parent.Finally -and $Private:_parent.Finally -eq $Private:_node)
					{
						$Private:_inFinally = $true
						Break
					}
					If ($Private:_parent.Body -eq $Private:_node -and $Private:_parent.CatchClauses.Count -gt 0) { Break }
				}
				$Private:_node = $Private:_parent
			}

			If ($Private:_inFinally)
			{
				$Rel = $File -replace ('^{0}\\' -f $Private:Escaped), ''
				$Findings.Add([PSCustomObject]@{
						File = $Rel
						Line = $Private:_throw.Extent.StartLineNumber
						Text = $Private:_throw.Extent.Text
					})
			}
		}
	}

	Write-PSHGSkipReport -Skipped $Skipped

	If ($Findings.Count -eq 0)
	{
		If ($Skipped.Count -gt 0)
		{ Write-Host ('NOT CLEAN - no findings, but {0} file(s) were not checked.' -f $Skipped.Count) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
		Write-Host 'PASS - no throw-inside-Finally found.' -ForegroundColor Green
		$Global:LASTEXITCODE = 0; return
	}

	Write-Host ''
	ForEach ($F in ($Findings | Sort-Object File, Line))
	{
		Write-Host ('  {0}:{1}' -f $F.File, $F.Line) -ForegroundColor Red
		Write-Host ('    {0}' -f $F.Text) -ForegroundColor DarkGray
		Write-Host ('    Fix: move this throw into the Catch block (fires only when there really was an exception), or replace it with a report + return so an already-handled exit path is not re-thrown.') -ForegroundColor Yellow
	}
	Write-Host ''
	Write-Host ('FAIL - {0} finding(s).' -f $Findings.Count) -ForegroundColor Red
	$Global:LASTEXITCODE = 1; return
}
