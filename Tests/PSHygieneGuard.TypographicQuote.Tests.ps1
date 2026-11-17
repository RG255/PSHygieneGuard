#requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
	.SYNOPSIS
	Pester suite for PSHG-TestTypographicQuoteEscape. Fixtures are written to $TestDrive; typographic
	quotes are built from char codes so this file stays ASCII.
#>

BeforeAll {
	Remove-Module -Name PSHygieneGuard -Force -ErrorAction SilentlyContinue
	Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\PSHygieneGuard.psd1') -Force

	$Script:ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
	$Script:GoodDir    = Join-Path $Script:ModuleRoot 'Examples\Good'
	$Script:TqDir      = Join-Path $TestDrive 'tq'
	$null = New-Item -ItemType Directory -Path $Script:TqDir -Force

	# Writes Body to a new .ps1 and returns the exit code of the check on it.
	$Script:Run = {
		Param ([String]$Body)
		$F = Join-Path $Script:TqDir ('f-' + [guid]::NewGuid().ToString('N') + '.ps1')
		Set-Content -LiteralPath $F -Value $Body
		$null = PSHG-TestTypographicQuoteEscape -Path $F 6>$null
		$Global:LASTEXITCODE
	}
	$Script:Rsq = [string][char]0x2019
	$Script:Ldq = [string][char]0x201C
}

Describe 'PSHG-TestTypographicQuoteEscape' {
	Context 'sites that must be reported' {
		It 'flags -replace with the ASCII single quote doubled' {
			(& $Script:Run '$v -replace "''", "''''"') | Should -Be 1
		}
		It 'flags -replace written with single-quoted literals' {
			$Body = @'
$v -replace '''', ''''''
'@
			(& $Script:Run $Body) | Should -Be 1
		}
		It 'flags -creplace and -ireplace' {
			(& $Script:Run '$v -creplace "''", "''''"') | Should -Be 1
			(& $Script:Run '$v -ireplace "''", "''''"') | Should -Be 1
		}
		It 'flags .Replace()' {
			(& $Script:Run '$v.Replace("''", "''''")') | Should -Be 1
		}
		It 'flags [regex]::Replace' {
			(& $Script:Run '[regex]::Replace($v, "''", "''''")') | Should -Be 1
			(& $Script:Run '[System.Text.RegularExpressions.Regex]::Replace($v, "''", "''''")') | Should -Be 1
		}
		It 'flags a site inside a function body and inside parentheses' {
			(& $Script:Run 'Function F { Param($v) return (''x'' + ($v -replace "''", "''''")) }') | Should -Be 1
		}
		It 'flags the double-quote forms (doubled and backtick)' {
			(& $Script:Run '$v -replace ''"'', ''""''') | Should -Be 1
			(& $Script:Run '$v.Replace(''"'', ''`"'')') | Should -Be 1
		}
		It 'flags a chain that covers the other quote kind only' {
			# a double-quote cover does not excuse the single-quote site
			(& $Script:Run ('$v.Replace("''", "''''").Replace(''{0}'', ''{0}{0}'')' -f $Script:Ldq)) | Should -Be 1
		}
		It 'reports file, line, kind and the expression, and PassThru emits objects' {
			$F = Join-Path $Script:TqDir 'report.ps1'
			Set-Content -LiteralPath $F -Value ("`$a = 1`r`n`$b = `$v -replace `"'`", `"''`"")
			$Out = PSHG-TestTypographicQuoteEscape -Path $F -PassThru 6>&1
			$Obj = @($Out | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] -and $_.PSObject.Properties['Kind'] })
			$Obj.Count | Should -Be 1
			$Obj[0].Line | Should -Be 2
			$Obj[0].Kind | Should -Be 'single'
			$Obj[0].Text | Should -Match '-replace'
			($Out | Out-String) | Should -Match 'Format-EscapedLiteral'
		}
	}

	Context 'sites that must pass' {
		It 'passes the shipped Good example (class replace and a covering chain)' {
			$null = PSHG-TestTypographicQuoteEscape -Path (Join-Path $Script:GoodDir 'CorrectTypographicQuoteEscape.ps1') 6>$null
			$Global:LASTEXITCODE | Should -Be 0
		}
		It 'passes the Format-EscapedLiteral form (a character class, not the bare ASCII quote)' {
			$Body = '[Regex]::Replace($Value, "[''{0}{1}{2}{3}]", ''$0$0'')' -f [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B
			(& $Script:Run $Body) | Should -Be 0
		}
		It 'passes the typographic regex form used as a -replace' {
			(& $Script:Run ('$v -replace "[''{0}{1}]", "$0$0"' -f [char]0x2018, [char]0x2019)) | Should -Be 0
		}
		It 'passes a chain that also doubles a typographic quote (literal, hex and decimal forms)' {
			(& $Script:Run ('$v.Replace("''", "''''").Replace("{0}", "{0}{0}")' -f $Script:Rsq)) | Should -Be 0
			(& $Script:Run '($v -replace "''", "''''") -replace [string][char]0x2019, ''xx''') | Should -Be 0
			(& $Script:Run '$v.Replace("''", "''''").Replace([string][char]8217, ''xx'')') | Should -Be 0
		}
		It 'passes the double-quote chain that covers U+201C' {
			(& $Script:Run ('$v.Replace(''"'', ''""'').Replace(''{0}'', ''{0}{0}'')' -f $Script:Ldq)) | Should -Be 0
		}
		It 'ignores replaces that are not quote doubling' {
			(& $Script:Run '$v -replace "''", ""') | Should -Be 0
			(& $Script:Run '$v -replace "a", "b"') | Should -Be 0
			(& $Script:Run '$v.Replace("''", $r)') | Should -Be 0
			(& $Script:Run '$v -replace $p, "''''"') | Should -Be 0
			(& $Script:Run '$v.Replace("x", "''''")') | Should -Be 0
		}
	}

	Context 'behaviour' {
		It 'accepts pipeline input and scans a folder recursively' {
			$Dir = Join-Path $Script:TqDir 'tree\sub'
			$null = New-Item -ItemType Directory -Path $Dir -Force
			Set-Content -LiteralPath (Join-Path $Dir 'a.ps1') -Value '$v.Replace("''", "''''")'
			$null = PSHG-TestTypographicQuoteEscape -Path (Join-Path $Script:TqDir 'tree') 6>$null
			$Global:LASTEXITCODE | Should -Be 1
			$null = (Join-Path $Dir 'a.ps1') | PSHG-TestTypographicQuoteEscape 6>$null
			$Global:LASTEXITCODE | Should -Be 1
		}
		It 'skips Original, _RetiredModules, .archive and _PlanningDocs folders' {
			ForEach ($D in 'Original', '_RetiredModules', '.archive', '_PlanningDocs')
			{
				$Dir = Join-Path $Script:TqDir ('skip\' + $D)
				$null = New-Item -ItemType Directory -Path $Dir -Force
				Set-Content -LiteralPath (Join-Path $Dir 'a.ps1') -Value '$v.Replace("''", "''''")'
			}
			$null = PSHG-TestTypographicQuoteEscape -Path (Join-Path $Script:TqDir 'skip') 6>$null
			$Global:LASTEXITCODE | Should -Be 0
		}
		It 'does not consult a baseline: the same site is reported on every run' {
			$F = Join-Path $Script:TqDir 'twice.ps1'
			Set-Content -LiteralPath $F -Value '$v.Replace("''", "''''")'
			$null = PSHG-TestTypographicQuoteEscape -Path $F 6>$null; $Global:LASTEXITCODE | Should -Be 1
			$null = PSHG-TestTypographicQuoteEscape -Path $F 6>$null; $Global:LASTEXITCODE | Should -Be 1
			(Get-Command PSHG-TestTypographicQuoteEscape).Parameters.Keys | Should -Not -Contain 'Baseline'
		}
		It 'writes a CSV of the findings' {
			$F = Join-Path $Script:TqDir 'csv.ps1'
			Set-Content -LiteralPath $F -Value '$v.Replace("''", "''''")'
			$C = Join-Path $Script:TqDir 'out.csv'
			$null = PSHG-TestTypographicQuoteEscape -Path $F -Csv $C 6>$null
			$Rows = @(Import-Csv -LiteralPath $C)
			$Rows.Count | Should -Be 1
			$Rows[0].Line | Should -Be 1
			$Rows[0].Kind | Should -Be 'single'
		}
		It '-Quiet drops the banner and the suggestion line but keeps the finding and verdict' {
			$F = Join-Path $Script:TqDir 'quiet.ps1'
			Set-Content -LiteralPath $F -Value '$v.Replace("''", "''''")'
			$Out = PSHG-TestTypographicQuoteEscape -Path $F -Quiet 6>&1 | Out-String
			$Out | Should -Not -Match 'Scanned'
			$Out | Should -Not -Match 'Format-EscapedLiteral'
			$Out | Should -Match 'quiet\.ps1:1'
			$Out | Should -Match 'FAIL - 1 finding'
		}
		It 'a file that cannot be parsed is NOT clean (exit 2) and a missing path is not clean either' {
			$F = Join-Path $Script:TqDir 'broken.ps1'
			Set-Content -LiteralPath $F -Value 'Function { ('
			$null = PSHG-TestTypographicQuoteEscape -Path $F 6>$null
			$Global:LASTEXITCODE | Should -Be 2
			$null = PSHG-TestTypographicQuoteEscape -Path (Join-Path $Script:TqDir 'nope.ps1') 6>$null
			$Global:LASTEXITCODE | Should -Be 2
		}
	}
}
