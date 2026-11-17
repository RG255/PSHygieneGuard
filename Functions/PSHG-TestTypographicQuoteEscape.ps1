Function PSHG-TestTypographicQuoteEscape
{
	<#
		.SYNOPSIS
		Finds hand-rolled quote escaping that only handles the ASCII quote - a value containing a typographic
		quote still ends the literal early.

		.DESCRIPTION
		PowerShell treats U+2018, U+2019, U+201A and U+201B as single quotes, and U+201C, U+201D and U+201E as double
		quotes, wherever the parser reads quoted text. Code that builds command text (an elevated command, a
		-Command string, a generated script) by doubling only the ASCII quote is therefore wrong for a value such as
		"Ray's backup" typed with a curly apostrophe: the literal ends early, the command breaks, and with a crafted
		value it can run code.

		    $Value -replace "'", "''"                       # ASCII only: reported
		    $Value.Replace("'", "''")                        # reported
		    [regex]::Replace($Value, "'", "''")              # reported
		    $Value -replace '"', '""'   (or '`"')            # same check for double quotes: reported
		    [Regex]::Replace($Value, "['<U+2018><U+2019><U+201A><U+201B>]", '$0$0')   # covers them: not reported

		A site is reported when -replace, .Replace() or [regex]::Replace has a pattern that is exactly the ASCII quote
		and a replacement that is two of them (for double quotes: two double quotes, or a backtick and a double quote),
		unless the same chained expression also names a typographic quote of that kind (a literal character, a
		0x2018-style number, a decimal code, a \u escape in a pattern). The usual fix is one shared helper that doubles
		the whole quote class instead of a hand-rolled replace at every call site.

		Dashes are a related trap (U+2013 to U+2015 are read as '-') but are not checked here.

		There is NO baseline and no marker comment: every site is listed on every run so old ones stay visible until the
		file they are in is next edited. Exit code 1 on any finding.

		Uses the PowerShell language parser's AST directly - no PSScriptAnalyzer dependency.

		.PARAMETER Path
		File or directory to scan (recurses; .ps1 and .psm1). Accepts pipeline input (strings or objects with a
		FullName property). Defaults to the current directory.

		.PARAMETER Quiet
		Print only the findings and the final verdict line (no banner, no per-finding suggestion line).

		.PARAMETER Csv
		Write every finding (File, Line, Kind, Text) to this CSV file.

		.PARAMETER PassThru
		Also emit each finding as an object to the success stream.

		.EXAMPLE
		PSHG-TestTypographicQuoteEscape -Path 'C:\MyProject'

		.EXAMPLE
		Get-ChildItem C:\MyProject -Recurse -Filter *.ps1 | PSHG-TestTypographicQuoteEscape -Csv .\quotes.csv

		.NOTES
		Returns 0 = clean, 1 = at least one finding, 2 = no findings but at least one file could not be read or parsed
		(listed; NOT a clean result). Follow the call with `exit $LASTEXITCODE` for a process exit code; `exit (call)` yields 0.
		Folders named Original, Originals, _RetiredModules, .archive, _PlanningDocs and .git are skipped.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console report is the entire purpose of this tool (matches module convention)')]
	[CmdletBinding()]
	Param (
		[Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[Alias('FullName')]
		[String[]]$Path = @($PWD.ProviderPath),

		[Switch]$Quiet,
		[String]$Csv,
		[Switch]$PassThru
	)

	Begin
	{
		$Script:TqeFindings = [System.Collections.Generic.List[PSCustomObject]]::new()
		$Script:TqeSkipped  = [System.Collections.Generic.List[String]]::new()
		$Script:TqeFileCount = 0
		$Script:TqeExclude  = '\\Original(s)?\\|\\_RetiredModules\\|\\\.archive\\|\\_PlanningDocs\\|\\\.git\\'

		# Evidence that an expression also deals with typographic quotes: the character itself, a 0x20xx / \u20xx
		# code, or the decimal code point. Built from char codes so this file stays ASCII.
		$Script:TqeSingleCover = '[{0}-{1}]|0x201[89AB]|u201[89AB]|\b821[6-9]\b' -f [char]0x2018, [char]0x201B
		$Script:TqeDoubleCover = '[{0}-{1}]|0x201[CDE]|u201[CDE]|\b822[0-2]\b' -f [char]0x201C, [char]0x201E
	}

	Process
	{
		ForEach ($Private:P in $Path)
		{
			If (-not (Test-Path -LiteralPath $Private:P)) { $Script:TqeSkipped.Add(('{0} (path not found)' -f $Private:P)); Continue }
			$Private:Root = (Resolve-Path -LiteralPath $Private:P).ProviderPath
			$Private:Files = @(Get-PSHGScanFile -Path $Private:Root -ExcludePattern $Script:TqeExclude -Problem $Script:TqeSkipped)
			$Private:Base = If (Test-Path -LiteralPath $Private:Root -PathType Container) { $Private:Root } Else { [System.IO.Path]::GetDirectoryName($Private:Root) }

			ForEach ($Private:File in $Private:Files)
			{
				$Script:TqeFileCount++
				$Private:Parsed = Read-PSHGAst -File $Private:File
				If (-not $Private:Parsed.Ok)
				{ $Script:TqeSkipped.Add(('{0} ({1})' -f $Private:File, $Private:Parsed.Reason)); If (-not $Private:Parsed.Ast) { Continue } }   # a partial tree is still scanned

				# Constant text of a string argument, or $null when it is not a plain constant string.
				$Private:ConstText = {
					Param ($N)
					If ($N -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $N.Value }
					If ($N -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $N.NestedExpressions.Count -eq 0) { return $N.Value }
					return $null
				}

				$Private:Candidates = $Private:Parsed.Ast.FindAll({
						Param($N)
						($N -is [System.Management.Automation.Language.BinaryExpressionAst] -and $N.Operator -in 'Replace', 'Ireplace', 'Creplace') -or
						($N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $N.Member.Value -ieq 'Replace')
					}, $true)

				ForEach ($Private:N in $Private:Candidates)
				{
					$Private:Pattern = $null; $Private:Repl = $null
					If ($Private:N -is [System.Management.Automation.Language.BinaryExpressionAst])
					{
						If ($Private:N.Right -is [System.Management.Automation.Language.ArrayLiteralAst] -and $Private:N.Right.Elements.Count -ge 2)
						{ $Private:Pattern = & $Private:ConstText $Private:N.Right.Elements[0]; $Private:Repl = & $Private:ConstText $Private:N.Right.Elements[1] }
					}
					ElseIf ($Private:N.Static)
					{
						# [regex]::Replace(input, pattern, replacement)
						$Private:TypeName = If ($Private:N.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) { $Private:N.Expression.TypeName.FullName } Else { '' }
						If ($Private:TypeName -in 'regex', 'System.Text.RegularExpressions.Regex' -and $Private:N.Arguments.Count -ge 3)
						{ $Private:Pattern = & $Private:ConstText $Private:N.Arguments[1]; $Private:Repl = & $Private:ConstText $Private:N.Arguments[2] }
					}
					ElseIf ($Private:N.Arguments.Count -eq 2)
					{ $Private:Pattern = & $Private:ConstText $Private:N.Arguments[0]; $Private:Repl = & $Private:ConstText $Private:N.Arguments[1] }

					If ($null -eq $Private:Pattern -or $null -eq $Private:Repl) { Continue }

					$Private:Kind = $null
					$Private:DQ = [string][char]34
					If ($Private:Pattern -ceq "'" -and $Private:Repl -ceq "''") { $Private:Kind = 'single' }
					ElseIf ($Private:Pattern -ceq $Private:DQ -and ($Private:Repl -ceq ($Private:DQ + $Private:DQ) -or $Private:Repl -ceq ('`' + $Private:DQ))) { $Private:Kind = 'double' }
					If (-not $Private:Kind) { Continue }

					# The whole chained expression the replace belongs to: a later or earlier replace in the same chain may cover the typographic quotes.
					$Private:Top = $Private:N
					While ($Private:Top.Parent)
					{
						$Private:Par = $Private:Top.Parent
						$Private:Up = $false
						If ($Private:Par -is [System.Management.Automation.Language.ParenExpressionAst]) { $Private:Up = $true }
						ElseIf ($Private:Par -is [System.Management.Automation.Language.BinaryExpressionAst] -and $Private:Par.Operator -in 'Replace', 'Ireplace', 'Creplace' -and [object]::ReferenceEquals($Private:Par.Left, $Private:Top)) { $Private:Up = $true }
						ElseIf ($Private:Par -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and ([object]::ReferenceEquals($Private:Par.Expression, $Private:Top) -or ($Private:Par.Static -and $Private:Par.Arguments.Count -gt 0 -and [object]::ReferenceEquals($Private:Par.Arguments[0], $Private:Top)))) { $Private:Up = $true }
						# The wrapper nodes inside parentheses: ( <pipeline> <command-expression> <expression> )
						ElseIf ($Private:Par -is [System.Management.Automation.Language.CommandExpressionAst] -and $Private:Par.Parent -is [System.Management.Automation.Language.PipelineAst] -and $Private:Par.Parent.PipelineElements.Count -eq 1 -and $Private:Par.Parent.Parent -is [System.Management.Automation.Language.ParenExpressionAst]) { $Private:Up = $true }
						ElseIf ($Private:Par -is [System.Management.Automation.Language.PipelineAst] -and $Private:Par.Parent -is [System.Management.Automation.Language.ParenExpressionAst]) { $Private:Up = $true }
						If (-not $Private:Up) { break }
						$Private:Top = $Private:Par
					}
					$Private:Cover = If ($Private:Kind -eq 'single') { $Script:TqeSingleCover } Else { $Script:TqeDoubleCover }
					If ($Private:Top.Extent.Text -match $Private:Cover) { Continue }

					$Private:Rel = If ($Private:File.StartsWith($Private:Base, [StringComparison]::OrdinalIgnoreCase)) { $Private:File.Substring($Private:Base.Length).TrimStart('\') } Else { $Private:File }
					If ([String]::IsNullOrEmpty($Private:Rel)) { $Private:Rel = Split-Path -Leaf $Private:File }
					$Script:TqeFindings.Add([PSCustomObject]@{
							File = $Private:Rel
							Line = $Private:N.Extent.StartLineNumber
							Kind = $Private:Kind
							Text = ($Private:N.Extent.Text -split "`r?`n")[0].Trim()
							Path = $Private:File
						})
				}
			}
		}
	}

	End
	{
		$Private:Found = @($Script:TqeFindings | Sort-Object Path, Line)
		If (-not $Quiet) { Write-Host ('Scanned {0} file(s) for ASCII-only quote escaping...' -f $Script:TqeFileCount) -ForegroundColor Cyan }

		Write-PSHGSkipReport -Skipped $Script:TqeSkipped

		If ($Csv -and $Found.Count -gt 0)
		{
			$Found | Select-Object File, Line, Kind, Text | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
			Write-Host ('CSV: {0} row(s) -> {1}' -f $Found.Count, $Csv) -ForegroundColor DarkGray
		}

		If ($Found.Count -eq 0)
		{
			If ($Script:TqeSkipped.Count -gt 0)
			{ Write-Host ('NOT CLEAN - no findings, but {0} path(s)/file(s) were not checked.' -f $Script:TqeSkipped.Count) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
			Write-Host 'PASS - no ASCII-only quote escaping found.' -ForegroundColor Green
			$Global:LASTEXITCODE = 0; return
		}

		Write-Host ''
		ForEach ($F in $Found)
		{
			Write-Host ('  {0}:{1}  [{2} quote]' -f $F.File, $F.Line, $F.Kind) -ForegroundColor Red
			Write-Host ('    {0}' -f $F.Text) -ForegroundColor DarkGray
			If (-not $Quiet) { Write-Host '    Fix: this escapes only the ASCII quote; a typographic quote in the value still ends the literal. Use Format-EscapedLiteral (or a replace that also covers the typographic quotes).' -ForegroundColor Yellow }
			If ($PassThru) { $F }
		}
		Write-Host ''
		Write-Host ('FAIL - {0} finding(s).' -f $Found.Count) -ForegroundColor Red
		$Global:LASTEXITCODE = 1; return
	}
}
