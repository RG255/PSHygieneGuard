Function PSHG-TestBareKeywordCommand
{
	<#
		.SYNOPSIS
		Finds an `If`/`ElseIf`/`While` written inside plain parens `(...)` instead of the
		subexpression operator `$(...)`, where PowerShell silently misparses it as a command
		invocation instead of a statement.

		.DESCRIPTION
		`(If ($x) { 1 } Else { 2 })` is valid PowerShell SYNTAX - it parses as a call to a
		command literally named "If", passed four positional arguments ($x, {1}, 'Else', {2}).
		It is never what the author meant (the intent is always "use the if/else's result as a
		value", which requires `$(...)`, not `(...)` - plain parens only accept a single
		pipeline, not a statement). This parses cleanly (no PSScriptAnalyzer finding, no parse
		error) and only fails at RUNTIME, with a misleading "The term 'If' is not recognized..."
		error.

		There is no legitimate reason PowerShell would ever resolve a real command named
		`if`/`elseif`/`while` - every match is an actual bug, so a clean run means zero
		findings, not zero NEW findings (no baseline needed for this checker).

		Uses the PowerShell language parser's AST directly ([Parser]::ParseFile), not
		PSScriptAnalyzer - no PSSA dependency, so this also runs on machines where PSSA is
		not installed.

		.PARAMETER Path
		File or directory to scan (recurses). Defaults to the current directory.

		.EXAMPLE
		PSHG-TestBareKeywordCommand

		.EXAMPLE
		PSHG-TestBareKeywordCommand -Path 'C:\MyProject'

		.NOTES
		Returns 0 = clean, 1 = at least one bare-keyword command found, 2 = no findings but at least one
		file could not be read or parsed (listed; NOT a clean result). Scans .ps1 and .psm1. Wrap the call in
		`PSHG-TestBareKeywordCommand ...; exit $LASTEXITCODE` for a process exit code.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console report is the entire purpose of this tool (matches module convention)')]
	[CmdletBinding()]
	Param (
		[String]$Path = $PWD.ProviderPath
	)

	# The only keywords that produce a CLEAN parse (zero errors) when misused this way -
	# ForEach/Switch/Do misuse in the same shape produces genuine PARSE ERRORS instead
	# (already caught by PSHG-TestScriptSyntax).
	$Private:BareKeywords = @('if', 'elseif', 'while')

	If (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: [{0}]' -f $Path) }
	$Private:Root = (Resolve-Path -LiteralPath $Path).ProviderPath

	$ExcludePattern = '\\Original(s)?\\|\\_RetiredModules\\|\\\.git\\'

	$Skipped = [System.Collections.Generic.List[String]]::new()
	$Files = @(Get-PSHGScanFile -Path $Private:Root -ExcludePattern $ExcludePattern -Problem $Skipped)

	Write-Host ('Scanning {0} file(s) for bare If/ElseIf/While misused inside plain parens...' -f $Files.Count) -ForegroundColor Cyan

	$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()
	$Private:Escaped = [Regex]::Escape($Private:Root)

	ForEach ($File in $Files)
	{
		$Private:_parsed = Read-PSHGAst -File $File
		If (-not $Private:_parsed.Ok)
		{ $Skipped.Add(('{0} ({1})' -f $File, $Private:_parsed.Reason)); If (-not $Private:_parsed.Ast) { Continue } }   # a partial tree is still scanned
		$Private:_ast = $Private:_parsed.Ast

		$Private:_cmds = $Private:_ast.FindAll(
			{ Param($N) $N -is [System.Management.Automation.Language.CommandAst] }, $true)

		ForEach ($Private:_cmd in $Private:_cmds)
		{
			$Private:_name = $Private:_cmd.GetCommandName()
			If ($Private:_name -and ($Private:_name -in $Private:BareKeywords))
			{
				$Rel = $File -replace ('^{0}\\' -f $Private:Escaped), ''
				$Findings.Add([PSCustomObject]@{
						File = $Rel
						Line = $Private:_cmd.Extent.StartLineNumber
						Text = $Private:_cmd.Extent.Text
					})
			}
		}
	}

	Write-PSHGSkipReport -Skipped $Skipped

	If ($Findings.Count -eq 0)
	{
		If ($Skipped.Count -gt 0)
		{ Write-Host ('NOT CLEAN - no findings, but {0} file(s) were not checked.' -f $Skipped.Count) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
		Write-Host 'PASS - no bare If/ElseIf/While found.' -ForegroundColor Green
		$Global:LASTEXITCODE = 0; return
	}

	Write-Host ''
	ForEach ($F in ($Findings | Sort-Object File, Line))
	{
		Write-Host ('  {0}:{1}' -f $F.File, $F.Line) -ForegroundColor Red
		Write-Host ('    {0}' -f $F.Text) -ForegroundColor DarkGray
		Write-Host ('    Fix: wrap in $(...) instead of (...) so it is evaluated as a value, not a command.') -ForegroundColor Yellow
	}
	Write-Host ''
	Write-Host ('FAIL - {0} finding(s).' -f $Findings.Count) -ForegroundColor Red
	$Global:LASTEXITCODE = 1; return
}
