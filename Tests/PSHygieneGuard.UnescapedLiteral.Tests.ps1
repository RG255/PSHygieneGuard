#requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
	.SYNOPSIS
	Pester suite for PSHG-TestUnescapedLiteral. Fixtures are written to $TestDrive; typographic quotes are
	built from char codes so this file stays ASCII.
#>

BeforeAll {
	Remove-Module -Name PSHygieneGuard -Force -ErrorAction SilentlyContinue
	Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\PSHygieneGuard.psd1') -Force

	$Script:ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
	$Script:GoodDir    = Join-Path $Script:ModuleRoot 'Examples\Good'
	$Script:UlDir      = Join-Path $TestDrive 'ul'
	$null = New-Item -ItemType Directory -Path $Script:UlDir -Force

	# Writes Body to a new .ps1 and returns the exit code of the check on it.
	$Script:Run = {
		Param ([String]$Body, [hashtable]$Extra = @{})
		$F = Join-Path $Script:UlDir ('f-' + [guid]::NewGuid().ToString('N') + '.ps1')
		Set-Content -LiteralPath $F -Value $Body
		$null = PSHG-TestUnescapedLiteral -Path $F @Extra 6>$null
		$Global:LASTEXITCODE
	}

	# Writes Body to a new .ps1 and returns the finding objects.
	$Script:Find = {
		Param ([String]$Body)
		$F = Join-Path $Script:UlDir ('g-' + [guid]::NewGuid().ToString('N') + '.ps1')
		Set-Content -LiteralPath $F -Value $Body
		$Out = PSHG-TestUnescapedLiteral -Path $F -PassThru 6>&1
		@($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] -and $_.PSObject.Properties['Arg'] })
	}
	$Script:Rsq = [string][char]0x2019
}

Describe 'PSHG-TestUnescapedLiteral' {
	Context 'sites that must be reported' {
		It 'flags a plain value inside a quoted placeholder' {
			$Body = @'
$Cmd = ("Set-Thing -Path '{0}'" -f $Path)
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'flags the generated data-file shape with doubled braces' {
			$Body = @'
$Text = "@{{ Path = '{0}' }}" -f $Path
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'flags a placeholder inside a here-string format' {
			$Body = @'
$Text = @"
Set-Thing -Path '{0}'
Set-Other -Name 'x'
"@ -f $Path
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'flags a single-quoted format string written with doubled quotes' {
			$Body = @'
$Cmd = 'Set-Thing -Path ''{0}''' -f $Path
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'flags [string]::Format and System.String.Format' {
			(& $Script:Run '$c = [string]::Format("Set-X ''{0}''", $Path)') | Should -Be 1
			(& $Script:Run '$c = [System.String]::Format("Set-X ''{0}''", $Path)') | Should -Be 1
		}
		It 'flags a property read and a method result (cannot be proven escaped)' {
			(& $Script:Run '$c = "Set-X ''{0}''" -f $State.ConfigPath') | Should -Be 1
			(& $Script:Run '$c = "Set-X ''{0}''" -f $Path.ToLowerInvariant()') | Should -Be 1
			(& $Script:Run '$c = "Set-X ''{0}''" -f $Path.Trim("''")') | Should -Be 1
		}
		It 'reports only the unescaped argument and names its index' {
			$Found = @(& $Script:Find '$c = "Set-X ''{0}'' ''{1}''" -f (Format-EscapedLiteral $A), $B')
			$Found.Count | Should -Be 1
			$Found[0].Arg | Should -Be 1
			$Found[0].Value | Should -Be '$B'
			$Found[0].Kind | Should -Be 'value'
			$Found[0].Via | Should -Be '-f'
		}
		It 'reports one finding per unescaped argument' {
			(& $Script:Find '$c = "Set-X ''{0}'' ''{1}''" -f $A, $B').Count | Should -Be 2
		}
		It 'does not trust a name: *Esc without an escape assignment is reported as name-only' {
			$Body = @'
Function F {
	$PathEsc = $Path
	return ("Set-X '{0}'" -f $PathEsc)
}
'@
			$Found = @(& $Script:Find $Body)
			$Found.Count | Should -Be 1
			$Found[0].Kind | Should -Be 'name-only'
		}
		It 'does not trust *Escaped or *ForCb names that are only parameters' {
			(& $Script:Find 'Function F { Param($PathEscaped) return ("Set-X ''{0}''" -f $PathEscaped) }')[0].Kind | Should -Be 'name-only'
			(& $Script:Find 'Function F { Param($CfgForCb) return ("Set-X ''{0}''" -f $CfgForCb) }')[0].Kind | Should -Be 'name-only'
		}
		It 'flags a parameter that is not typed' {
			(& $Script:Run 'Function F { Param($Path) return ("Set-X ''{0}''" -f $Path) }') | Should -Be 1
		}
		It 'flags a variable with one escaped and one raw assignment before the site' {
			$Body = @'
Function F {
	Param($Path)
	$V = Format-EscapedLiteral $Path
	If ($x) { $V = $Path }
	return ("Set-X '{0}'" -f $V)
}
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'flags a variable assigned only AFTER the site' {
			$Body = @'
Function F {
	$c = ("Set-X '{0}'" -f $V)
	$V = Format-EscapedLiteral $Path
}
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'flags a variable escaped in another function (the assignment must be in the same function)' {
			$Body = @'
Function A { $V = Format-EscapedLiteral $Path; return $V }
Function B { return ("Set-X '{0}'" -f $V) }
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'flags a variable changed with += (not a plain escape assignment)' {
			$Body = @'
Function F {
	$V = Format-EscapedLiteral $A
	$V += $B
	return ("Set-X '{0}'" -f $V)
}
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'sees a format string built from constants joined with + and one held in a variable' {
			(& $Script:Run '$c = ("Set-X " + "''{0}''") -f $Path') | Should -Be 1
			(& $Script:Run ('$Fmt = "Set-X ''{0}''"' + "`r`n" + '$c = $Fmt -f $Path')) | Should -Be 1
		}
		It 'flags an expandable-string format and a -f with a leading array expression' {
			(& $Script:Run '$c = "Set-X ''{0}'' $Other" -f $Path') | Should -Be 1
			(& $Script:Run '$c = "Set-X ''{0}''" -f @($Path)') | Should -Be 1
		}
		It 'reports file, line, argument and the review question' {
			$F = Join-Path $Script:UlDir 'report.ps1'
			Set-Content -LiteralPath $F -Value ("`$a = 1`r`n`$b = `"Set-X '{0}'`" -f `$v")
			$Out = PSHG-TestUnescapedLiteral -Path $F -PassThru 6>&1
			$Obj = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] -and $_.PSObject.Properties['Arg'] })
			$Obj.Count | Should -Be 1
			$Obj[0].Line | Should -Be 2
			$Obj[0].Arg | Should -Be 0
			$Obj[0].Text | Should -Match '-f'
			$Text = $Out | Out-String
			$Text | Should -Match 'user/disk controlled'
			$Text | Should -Match 'parsed as PowerShell or as a data file'
			$Text | Should -Match 'REVIEW - 1 site'
		}
	}

	Context 'sites that must pass' {
		It 'passes the shipped Good example' {
			$null = PSHG-TestUnescapedLiteral -Path (Join-Path $Script:GoodDir 'CorrectUnescapedLiteral.ps1') 6>$null
			$Global:LASTEXITCODE | Should -Be 0
		}
		It 'passes Format-EscapedLiteral in every call shape and spelling' {
			(& $Script:Run '$c = "Set-X ''{0}''" -f (Format-EscapedLiteral $P)') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f (Format-EscapedLiteral -Value $P)') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f ($P | Format-EscapedLiteral)') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f $(Format-EscapedLiteral $P)') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f (format-escapedliteral $P)') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f (SomeModule\Format-EscapedLiteral $P)') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f ([string](Format-EscapedLiteral $P))') | Should -Be 0
			(& $Script:Run '$c = [string]::Format("Set-X ''{0}''", (Format-EscapedLiteral $P))') | Should -Be 0
		}
		It 'passes the typographic-covering Regex.Replace and the .NET escape method' {
			(& $Script:Run '$c = "Set-X ''{0}''" -f ([Regex]::Replace($P, "[''\u2019]", ''$0$0''))') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f ([System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($P))') | Should -Be 0
		}
		It 'reports a Regex.Replace that covers only the ASCII quote' {
			(& $Script:Run '$c = "Set-X ''{0}''" -f ([Regex]::Replace($P, "''", "''''"))') | Should -Be 1
		}
		It 'passes constants and literals' {
			(& $Script:Run '$c = "Set-X ''{0}''" -f ''literal''') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f 42') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f $true') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f "no variables here"') | Should -Be 0
		}
		It 'passes int, guid, datetime and bool typed values (casts, parameters, typed assignments)' {
			(& $Script:Run '$c = "Set-X ''{0}''" -f [int]$P') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f ([guid]$P)') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f [datetime]$P') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f [bool]$P') | Should -Be 0
			(& $Script:Run 'Function F { Param([int]$N) return ("Set-X ''{0}''" -f $N) }') | Should -Be 0
			(& $Script:Run 'Function F { Param([guid]$Id, [datetime]$When, [bool]$On) return ("Set-X ''{0}'' ''{1}'' ''{2}''" -f $Id, $When, $On) }') | Should -Be 0
			(& $Script:Run 'Function F { [int]$N = Get-Thing; return ("Set-X ''{0}''" -f $N) }') | Should -Be 0
			(& $Script:Run 'Function F { Param([System.IO.FileAttributes]$A) return ("Set-X ''{0}''" -f $A) }') | Should -Be 0
		}
		It 'passes a ValidateSet parameter whose values hold no quote' {
			(& $Script:Run 'Function F { Param([ValidateSet(''Alpha'', ''Beta'')][String]$Mode) return ("Set-X ''{0}''" -f $Mode) }') | Should -Be 0
		}
		It 'reports a ValidateSet parameter whose values hold a quote' {
			(& $Script:Run 'Function F { Param([ValidateSet("a''b", ''Beta'')][String]$Mode) return ("Set-X ''{0}''" -f $Mode) }') | Should -Be 1
		}
		It 'passes ToString with a number/date/guid format, Get-Date -Format, New-Guid and NewGuid' {
			(& $Script:Run '$c = "Set-X ''{0}''" -f $Id.ToString(''N'')') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f $Id.ToString(''D'')') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f $When.ToString(''yyyy-MM-dd HH:mm:ss'')') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f ((Get-Date).ToString(''o''))') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f (Get-Date -Format ''yyyy-MM-dd'')') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f [guid]::NewGuid().ToString(''N'')') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f (New-Guid)') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''{0}''" -f $List.Count') | Should -Be 0
		}
		It 'passes a variable whose assignment in the same function is an escape call' {
			$Body = @'
Function F {
	Param($Path)
	$PathEsc = Format-EscapedLiteral $Path
	return ("Set-X '{0}'" -f $PathEsc)
}
'@
			(& $Script:Run $Body) | Should -Be 0
		}
		It 'passes an escaped variable whatever its name' {
			$Body = @'
Function F {
	Param($Path)
	$Safe = Format-EscapedLiteral $Path
	$Cmd = "Set-X '{0}'" -f $Safe
	$Private:Other = Format-EscapedLiteral -Value $Path
	return ("Set-Y '{0}'" -f $Private:Other)
}
'@
			(& $Script:Run $Body) | Should -Be 0
		}
		It 'passes a variable escaped by a typographic-covering replace, and one assigned a constant' {
			$Body = '$V = [Regex]::Replace($P, "[''{0}{1}]", ''$0$0'')' -f [char]0x2018, [char]0x2019
			$Body = $Body + "`r`n" + '$c = "Set-X ''{0}''" -f $V'
			(& $Script:Run $Body) | Should -Be 0
			(& $Script:Run ('$V = ''fixed''' + "`r`n" + '$c = "Set-X ''{0}''" -f $V')) | Should -Be 0
		}
		It 'passes a variable that is escaped in an outer function scope and used in a nested one' {
			$Body = @'
Function Outer {
	$V = Format-EscapedLiteral $Path
	Function Inner { return ("Set-X '{0}'" -f $V) }
}
'@
			(& $Script:Run $Body) | Should -Be 0
		}
		It 'passes a variable chain: escaped, then copied' {
			$Body = @'
Function F {
	$A = Format-EscapedLiteral $Path
	$B = $A
	return ("Set-X '{0}'" -f $B)
}
'@
			(& $Script:Run $Body) | Should -Be 0
		}
		It 'passes a variable assigned from If/Else with only safe values' {
			$Body = @'
Function F {
	$T = If ($x) { 'D' } Else { 'P' }
	return ("Set-X '{0}'" -f $T)
}
'@
			(& $Script:Run $Body) | Should -Be 0
		}
		It 'reports an If/Else with a raw branch, or an If without Else' {
			(& $Script:Run 'Function F { $T = If ($x) { ''D'' } Else { $Raw }; return ("Set-X ''{0}''" -f $T) }') | Should -Be 1
			(& $Script:Run 'Function F { $T = If ($x) { ''D'' }; return ("Set-X ''{0}''" -f $T) }') | Should -Be 1
		}
		It 'ignores placeholders that are not directly between single quotes' {
			(& $Script:Run '$c = "Set-X {0}" -f $Path') | Should -Be 0
			(& $Script:Run '$c = ''Set-X "{0}"'' -f $Path') | Should -Be 0
			(& $Script:Run '$c = ''Set-X ''''{0}\sub'''''' -f $Path') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''x'' {0}" -f $Path') | Should -Be 0
		}
		It 'ignores escaped braces that only look like a placeholder' {
			(& $Script:Run '$c = "Set-X ''{{0}}''" -f $Path') | Should -Be 0
		}
		It 'ignores an argument index with no argument, and code without -f' {
			(& $Script:Run '$c = "Set-X ''{1}''" -f $Path') | Should -Be 0
			(& $Script:Run '$c = "Set-X ''$Path''"') | Should -Be 0
			(& $Script:Run '$c = $Path -replace "a", "b"') | Should -Be 0
		}
		It 'ignores a quote placeholder whose argument is a number-valued expression' {
			(& $Script:Run '$c = "Set-X ''{0}''" -f ($i - 1)') | Should -Be 0
		}
	}

	Context 'display-only sites' {
		It 'skips a -f result that is only written, warned or thrown' {
			(& $Script:Run 'Write-Host ("Doing ''{0}''" -f $Path)') | Should -Be 0
			(& $Script:Run 'Write-Verbose ("Doing ''{0}''" -f $Path)') | Should -Be 0
			(& $Script:Run 'Write-Warning ("Doing ''{0}''" -f $Path)') | Should -Be 0
			(& $Script:Run 'throw ("Failed ''{0}''" -f $Path)') | Should -Be 0
			(& $Script:Run '("Doing ''{0}''" -f $Path) | Write-Host') | Should -Be 0
			(& $Script:Run 'Write-Host -Object ("Doing ''{0}''" -f $Path) -ForegroundColor Red') | Should -Be 0
		}
		It '-IncludeDisplay reports them' {
			(& $Script:Run 'Write-Host ("Doing ''{0}''" -f $Path)' @{ IncludeDisplay = $true }) | Should -Be 1
			(& $Script:Run 'throw ("Failed ''{0}''" -f $Path)' @{ IncludeDisplay = $true }) | Should -Be 1
		}
		It '-DisplayCommand adds names' {
			(& $Script:Run 'Write-MyLog ("Doing ''{0}''" -f $Path)') | Should -Be 1
			(& $Script:Run 'Write-MyLog ("Doing ''{0}''" -f $Path)' @{ DisplayCommand = 'Write-MyLog' }) | Should -Be 0
		}
		It 'does not skip a result that is returned, assigned, output or passed to another command' {
			(& $Script:Run 'Write-Output ("Doing ''{0}''" -f $Path)') | Should -Be 1
			(& $Script:Run '$m = ("Doing ''{0}''" -f $Path); Write-Host $m') | Should -Be 1
			(& $Script:Run 'Invoke-Thing -Command ("Doing ''{0}''" -f $Path)') | Should -Be 1
			(& $Script:Run 'return ("Doing ''{0}''" -f $Path)') | Should -Be 1
		}
	}

	Context 'behaviour' {
		It 'accepts pipeline input and scans a folder recursively' {
			$Dir = Join-Path $Script:UlDir 'tree\sub'
			$null = New-Item -ItemType Directory -Path $Dir -Force
			Set-Content -LiteralPath (Join-Path $Dir 'a.ps1') -Value '$c = "Set-X ''{0}''" -f $Path'
			$null = PSHG-TestUnescapedLiteral -Path (Join-Path $Script:UlDir 'tree') 6>$null
			$Global:LASTEXITCODE | Should -Be 1
			$null = (Join-Path $Dir 'a.ps1') | PSHG-TestUnescapedLiteral 6>$null
			$Global:LASTEXITCODE | Should -Be 1
		}
		It 'skips Original, _RetiredModules, .archive and _PlanningDocs folders' {
			ForEach ($D in 'Original', '_RetiredModules', '.archive', '_PlanningDocs')
			{
				$Dir = Join-Path $Script:UlDir ('skip\' + $D)
				$null = New-Item -ItemType Directory -Path $Dir -Force
				Set-Content -LiteralPath (Join-Path $Dir 'a.ps1') -Value '$c = "Set-X ''{0}''" -f $Path'
			}
			$null = PSHG-TestUnescapedLiteral -Path (Join-Path $Script:UlDir 'skip') 6>$null
			$Global:LASTEXITCODE | Should -Be 0
		}
		It 'skips test files in a scanned folder unless -IncludeTests, but scans a test file passed by name' {
			$Dir = Join-Path $Script:UlDir 'withtests\Tests'
			$null = New-Item -ItemType Directory -Path $Dir -Force
			$Top = Join-Path $Script:UlDir 'withtests'
			Set-Content -LiteralPath (Join-Path $Dir 'a.ps1') -Value '$c = "Set-X ''{0}''" -f $Path'
			Set-Content -LiteralPath (Join-Path $Top 'b.Tests.ps1') -Value '$c = "Set-X ''{0}''" -f $Path'
			$null = PSHG-TestUnescapedLiteral -Path $Top 6>$null
			$Global:LASTEXITCODE | Should -Be 0
			$null = PSHG-TestUnescapedLiteral -Path $Top -IncludeTests 6>$null
			$Global:LASTEXITCODE | Should -Be 1
			$null = PSHG-TestUnescapedLiteral -Path (Join-Path $Top 'b.Tests.ps1') 6>$null
			$Global:LASTEXITCODE | Should -Be 1
		}
		It 'does not consult a baseline: the same site is reported on every run' {
			$F = Join-Path $Script:UlDir 'twice.ps1'
			Set-Content -LiteralPath $F -Value '$c = "Set-X ''{0}''" -f $Path'
			$null = PSHG-TestUnescapedLiteral -Path $F 6>$null; $Global:LASTEXITCODE | Should -Be 1
			$null = PSHG-TestUnescapedLiteral -Path $F 6>$null; $Global:LASTEXITCODE | Should -Be 1
			(Get-Command PSHG-TestUnescapedLiteral).Parameters.Keys | Should -Not -Contain 'Baseline'
		}
		It 'writes a CSV of the findings' {
			$F = Join-Path $Script:UlDir 'csv.ps1'
			Set-Content -LiteralPath $F -Value '$c = "Set-X ''{0}''" -f $Path'
			$C = Join-Path $Script:UlDir 'out.csv'
			$null = PSHG-TestUnescapedLiteral -Path $F -Csv $C 6>$null
			$Rows = @(Import-Csv -LiteralPath $C)
			$Rows.Count | Should -Be 1
			$Rows[0].Line | Should -Be 1
			$Rows[0].Arg | Should -Be 0
			$Rows[0].Kind | Should -Be 'value'
			$Rows[0].Value | Should -Be '$Path'
		}
		It '-Quiet drops the banner and the review line but keeps the finding and verdict' {
			$F = Join-Path $Script:UlDir 'quiet.ps1'
			Set-Content -LiteralPath $F -Value '$c = "Set-X ''{0}''" -f $Path'
			$Out = PSHG-TestUnescapedLiteral -Path $F -Quiet 6>&1 | Out-String
			$Out | Should -Not -Match 'Scanned'
			$Out | Should -Not -Match 'user/disk controlled'
			$Out | Should -Match 'quiet\.ps1:1'
			$Out | Should -Match 'REVIEW - 1 site'
		}
		It 'a file that cannot be parsed is NOT clean (exit 2) and a missing path is not clean either' {
			$F = Join-Path $Script:UlDir 'broken.ps1'
			Set-Content -LiteralPath $F -Value 'Function { ('
			$null = PSHG-TestUnescapedLiteral -Path $F 6>$null
			$Global:LASTEXITCODE | Should -Be 2
			$null = PSHG-TestUnescapedLiteral -Path (Join-Path $Script:UlDir 'nope.ps1') 6>$null
			$Global:LASTEXITCODE | Should -Be 2
		}
		It 'is exported' {
			(Get-Command PSHG-TestUnescapedLiteral -Module PSHygieneGuard).Name | Should -Be 'PSHG-TestUnescapedLiteral'
		}
	}
}
