Function PSHG-TestJoinPathDriveRoot
{
	<#
		.SYNOPSIS
		Finds `Join-Path` called on a drive root that is built from a variable - the call throws "Cannot find
		drive" when that drive is not a live PSDrive.

		.DESCRIPTION
		`Join-Path` does not just join strings. It resolves the drive of its -Path argument through PowerShell's
		provider system and THROWS "Cannot find drive. A drive with the name 'X' does not exist." when there is
		no such drive. Code that builds a path for a drive that is allowed to be absent - a USB drive plugged in
		after the session started, an unmounted VHD, a letter a test supplies - therefore fails exactly where it
		was meant to cope. Under `$ErrorActionPreference = 'Stop'` (as an elevated pipe server sets) that is a
		terminating error; otherwise it is a non-terminating one and the call silently returns nothing.

		    Join-Path -Path ('{0}:\' -f $Letter) -ChildPath $Rel       # throws if $Letter is not mounted
		    [System.IO.Path]::Combine(('{0}:\' -f $Letter), $Rel)       # just builds the string

		This checker reports `Join-Path` calls whose -Path (or first positional) argument is built from a
		drive-root template: a `'{0}:\'` format string, or an interpolated `"${Letter}:\..."` /
		`"$($Letter):\..."` string. It does NOT flag a drive that is a literal (`'C:\x'`) - that one is a
		different question (see PSHG-FindDriveLetterAssumption) - nor a path that merely arrives in a variable,
		which it cannot judge.

		Every hit is worth reading, but one can be legitimate (the drive is known to be mounted, e.g. it was
		just enumerated as a mounted volume AND the session has refreshed its drive list). Mark such a line with
		the comment `# PSHG-OK: JoinPathDriveRoot` on the same line and it is skipped.

		Uses the PowerShell language parser's AST directly - no PSScriptAnalyzer dependency.

		.PARAMETER Path
		File or directory to scan (recurses). Defaults to the current directory.

		.EXAMPLE
		PSHG-TestJoinPathDriveRoot -Path 'C:\MyProject'

		.NOTES
		Returns 0 = clean, 1 = at least one finding, 2 = no findings but at least one file could not be read or parsed
		(listed; NOT a clean result). Scans .ps1 and .psm1. Follow the call with `exit $LASTEXITCODE` for a process exit code; `exit (call)` yields 0.
		No baseline: a hit is either a bug or carries the marker comment.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console report is the entire purpose of this tool (matches module convention)')]
	[CmdletBinding()]
	Param (
		[String]$Path = $PWD.ProviderPath
	)

	If (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: [{0}]' -f $Path) }
	$Private:Root = (Resolve-Path -LiteralPath $Path).ProviderPath

	# A string that starts with a drive-root template: {0}:\  or  ${Letter}:\  or  $($Letter):\  (the colon may be followed by \ or end).
	$Private:DriveRootTemplate = '^\s*["'']?(\{\d+\}|\$\{\w+\}|\$\(\s*\$\w+\s*\))\s*:(\\|["'']|$)'
	$Private:Marker            = 'PSHG-OK:\s*JoinPathDriveRoot'
	$ExcludePattern            = '\\Original(s)?\\|\\_RetiredModules\\|\\\.git\\'

	$Skipped = [System.Collections.Generic.List[String]]::new()
	$Files = @(Get-PSHGScanFile -Path $Private:Root -ExcludePattern $ExcludePattern -Problem $Skipped)

	Write-Host ('Scanning {0} file(s) for Join-Path on a variable-built drive root...' -f $Files.Count) -ForegroundColor Cyan

	$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()
	$Private:Escaped = [Regex]::Escape($Private:Root)

	ForEach ($File in $Files)
	{
		$Private:_parsed = Read-PSHGAst -File $File
		If (-not $Private:_parsed.Ok)
		{ $Skipped.Add(('{0} ({1})' -f $File, $Private:_parsed.Reason)); If (-not $Private:_parsed.Ast) { Continue } }   # a partial tree is still scanned
		$Private:_ast = $Private:_parsed.Ast
		$Private:_lines = $null

		$Private:_cmds = $Private:_ast.FindAll(
			{ Param($N) $N -is [System.Management.Automation.Language.CommandAst] -and $N.GetCommandName() -eq 'Join-Path' }, $true)

		ForEach ($Private:_cmd in $Private:_cmds)
		{
			# The -Path argument: the named one, else the first positional (CommandElements[0] is the command name).
			$Private:_pathArg = $null
			$Private:_els = $Private:_cmd.CommandElements
			For ($Private:i = 1; $Private:i -lt $Private:_els.Count; $Private:i++)
			{
				$Private:e = $Private:_els[$Private:i]
				If ($Private:e -is [System.Management.Automation.Language.CommandParameterAst])
				{
					If ($Private:e.ParameterName -ieq 'Path')
					{
						$Private:_pathArg = If ($Private:e.Argument) { $Private:e.Argument } ElseIf ($Private:i + 1 -lt $Private:_els.Count) { $Private:_els[$Private:i + 1] } Else { $null }
						break
					}
					# Other value-taking parameters: step over their value so it is not mistaken for the positional -Path.
					If ($Private:e.ParameterName -in 'ChildPath', 'AdditionalChildPath', 'Credential' -and -not $Private:e.Argument) { $Private:i++ }
					continue
				}
				# First positional argument (not the value of a named parameter - those were skipped above).
				$Private:_pathArg = $Private:e
				break
			}
			If (-not $Private:_pathArg) { continue }

			$Private:_strings = @($Private:_pathArg.FindAll({ Param($N) $N -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $N -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true))
			If ($Private:_pathArg -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $Private:_pathArg -is [System.Management.Automation.Language.ExpandableStringExpressionAst])
			{ $Private:_strings += $Private:_pathArg }
			$Private:_hit = $false
			ForEach ($Private:s in $Private:_strings) { If ($Private:s.Extent.Text -match $Private:DriveRootTemplate) { $Private:_hit = $true; break } }
			If (-not $Private:_hit) { continue }

			If ($null -eq $Private:_lines) { $Private:_lines = [IO.File]::ReadAllLines($File) }
			$Private:_lineText = $Private:_lines[$Private:_cmd.Extent.StartLineNumber - 1]
			If ($Private:_lineText -match $Private:Marker) { continue }

			$Rel = $File -replace ('^{0}\\' -f $Private:Escaped), ''
			$Findings.Add([PSCustomObject]@{
					File = $Rel
					Line = $Private:_cmd.Extent.StartLineNumber
					Text = ($Private:_cmd.Extent.Text -split "`r?`n")[0].Trim()
				})
		}
	}

	Write-PSHGSkipReport -Skipped $Skipped

	If ($Findings.Count -eq 0)
	{
		If ($Skipped.Count -gt 0)
		{ Write-Host ('NOT CLEAN - no findings, but {0} file(s) were not checked.' -f $Skipped.Count) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
		Write-Host 'PASS - no Join-Path on a variable-built drive root found.' -ForegroundColor Green
		$Global:LASTEXITCODE = 0; return
	}

	Write-Host ''
	ForEach ($F in ($Findings | Sort-Object File, Line))
	{
		Write-Host ('  {0}:{1}' -f $F.File, $F.Line) -ForegroundColor Red
		Write-Host ('    {0}' -f $F.Text) -ForegroundColor DarkGray
		Write-Host ('    Fix: Join-Path throws "Cannot find drive" when that drive is not mounted. Use [System.IO.Path]::Combine(<root>, <child>) - or add "# PSHG-OK: JoinPathDriveRoot" if the drive is known to exist.') -ForegroundColor Yellow
	}
	Write-Host ''
	Write-Host ('FAIL - {0} finding(s).' -f $Findings.Count) -ForegroundColor Red
	$Global:LASTEXITCODE = 1; return
}
