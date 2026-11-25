#requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
	.SYNOPSIS
	Pester suite for the three places PSHygieneGuard writes a value into a single-quoted literal of a file it generates
	(-Fix of PSHG-FindHardcodedWindowsPath, and the baseline files written by PSHG-TestRepoLint and PSHG-TestScriptErrorHandling).
	Each value contains an ASCII apostrophe and the four typographic single quotes (U+2018-U+201B), built from char codes
	so this file stays ASCII; the generated file must still parse and give the value back unchanged.
#>

BeforeAll {
	Remove-Module -Name PSHygieneGuard -Force -ErrorAction SilentlyContinue
	Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\PSHygieneGuard.psd1') -Force -WarningAction SilentlyContinue

	# The name carries every single-quote character PowerShell recognises.
	$Script:Tq = ([char]0x2018).ToString() + [char]0x2019 + [char]0x201A + [char]0x201B + "'"
	$Script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
	# Doubles each quote character one at a time (independent of the code under test).
	$Script:Double = {
		Param ([String]$Text)
		$Sb = New-Object System.Text.StringBuilder
		foreach ($Ch in $Text.ToCharArray())
		{
			[void]$Sb.Append($Ch)
			if ($Ch -eq [char]39 -or ($Ch -ge [char]0x2018 -and $Ch -le [char]0x201B)) { [void]$Sb.Append($Ch) }
		}
		$Sb.ToString()
	}
}

Describe 'PSHG-FindHardcodedWindowsPath -Fix with quotes in the path tail' {
	It 'rewrites the path into an expression that still returns the same path' {
		$Name = 'Ray' + $Script:Tq + 's'
		$Probe = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath ('fix-' + [guid]::NewGuid().ToString('N') + '.ps1')
		$Source = "Function Test-QuoteFixProbe`n{`n`t`$Dir = 'C:\ProgramData\" + (& $Script:Double $Name) + "\sub'`n`treturn `$Dir`n}`n"
		[System.IO.File]::WriteAllText($Probe, $Source, $Script:Utf8Bom)
		$null = PSHG-FindHardcodedWindowsPath -Path $Probe -Fix 6>$null
		$Errs = $null
		$null = [System.Management.Automation.Language.Parser]::ParseFile($Probe, [ref]$null, [ref]$Errs)
		$Errs.Count | Should -Be 0
		. $Probe
		(Test-QuoteFixProbe) | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $env:ProgramData ($Name + '\sub'))))
	}
}

Describe 'PSHG-TestRepoLint -UpdateBaseline with quotes in a path' {
	It 'writes a baseline that parses and holds the key unchanged' -Skip:(-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
		$Rule = 'PSUseShouldProcessForStateChangingFunctions'
		$Root = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'lint'
		$null = New-Item -ItemType Directory -Path (Join-Path $Root 'App') -Force
		$FileName = 'a' + $Script:Tq + 'b.ps1'
		[System.IO.File]::WriteAllText((Join-Path $Root ('App\' + $FileName)), "function Set-AThing { }`r`n", $Script:Utf8Bom)
		$Baseline = Join-Path $Root 'baseline.psd1'
		$null = PSHG-TestRepoLint -Path (Join-Path $Root 'App') -BaselinePath $Baseline -RepoRoot $Root -Rule $Rule -UpdateBaseline 6>$null
		$Global:LASTEXITCODE | Should -Be 0
		@((Import-PowerShellDataFile -Path $Baseline).Accepted) | Should -Contain ('{0}|App\{1}|Set-AThing' -f $Rule, $FileName)
	}
}

Describe 'PSHG-TestScriptErrorHandling -UpdateBaseline with quotes in a path' {
	It 'writes a baseline that parses and holds a key naming the file unchanged' {
		$Root = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'eh'
		$null = New-Item -ItemType Directory -Path $Root -Force
		$FileName = 'c' + $Script:Tq + 'd.ps1'
		$Body = "function Test-Swallow`r`n{`r`n`ttry { Get-Item -LiteralPath 'C:\nope-nope' -ErrorAction Stop }`r`n`tcatch { }`r`n}`r`n"
		[System.IO.File]::WriteAllText((Join-Path $Root $FileName), $Body, $Script:Utf8Bom)
		$Baseline = Join-Path $Root 'baseline.psd1'
		$null = PSHG-TestScriptErrorHandling -Path (Join-Path $Root $FileName) -Baseline $Baseline -UpdateBaseline -Quiet 3>$null 6>$null
		Test-Path -LiteralPath $Baseline | Should -BeTrue
		$Keys = @((Import-PowerShellDataFile -Path $Baseline).Keys)
		$Keys.Count | Should -BeGreaterThan 0
		@($Keys | Where-Object { $_.Contains($FileName) }).Count | Should -BeGreaterThan 0
	}
}
