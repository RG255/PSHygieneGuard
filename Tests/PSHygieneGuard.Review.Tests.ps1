#requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
	.SYNOPSIS
	Pester suite for the files-not-checked, coverage, boundary and safe-rewrite fixes of 2026-11.

	.DESCRIPTION
	Each test builds its own small fixture under $TestDrive and asserts one behaviour that the earlier code got wrong.
	The shipped Examples\Bad.zip is extracted to a temp folder for the .psm1 coverage cases.
#>

BeforeAll {
	Remove-Module -Name PSHygieneGuard -Force -ErrorAction SilentlyContinue
	Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\PSHygieneGuard.psd1') -Force

	$Script:ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
	$Script:BadDir     = Join-Path $env:TEMP ('pshg-review-bad-' + [guid]::NewGuid().ToString('N'))
	Expand-Archive -LiteralPath (Join-Path $Script:ModuleRoot 'Examples\Bad.zip') -DestinationPath $Script:BadDir -Force

	$Script:Bom   = New-Object System.Text.UTF8Encoding($true)
	$Script:NoBom = New-Object System.Text.UTF8Encoding($false)

	# Writes a file (BOM'd UTF-8) and returns its path.
	function Initialize-ReviewFile
	{
		Param ([String]$Dir, [String]$Name, [String]$Body)
		$Private:Folder = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath $Dir
		$null = New-Item -ItemType Directory -Path $Private:Folder -Force
		$Private:File = Join-Path $Private:Folder $Name
		[System.IO.File]::WriteAllText($Private:File, $Body, $Script:Bom)
		return $Private:File
	}
}

AfterAll {
	Remove-Item -LiteralPath $Script:BadDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'A run that could not check every file is not clean' {
	BeforeAll {
		$Script:Broken = Initialize-ReviewFile -Dir 'unchecked' -Name 'broken.ps1' -Body "function Get-X {`n  if ( {`n"
		$Script:Dir    = Split-Path -Path $Script:Broken -Parent
		$Script:Fns = 'PSHG-TestBareKeywordCommand', 'PSHG-TestFinallyThrow', 'PSHG-TestGetNewClosureScope', 'PSHG-TestGetNewClosurePrivateScope', 'PSHG-TestJoinPathDriveRoot'
	}

	It '<Fn> exits 2 for a file with a parse error' -ForEach @(
		@{ Fn = 'PSHG-TestBareKeywordCommand' }, @{ Fn = 'PSHG-TestFinallyThrow' }, @{ Fn = 'PSHG-TestGetNewClosureScope' },
		@{ Fn = 'PSHG-TestGetNewClosurePrivateScope' }, @{ Fn = 'PSHG-TestJoinPathDriveRoot' }) {
		$Private:Out = & $Fn -Path $Script:Broken *>&1 | Out-String
		$Global:LASTEXITCODE | Should -Be 2
		$Private:Out | Should -Match 'NOT CHECKED'
		$Private:Out | Should -Match 'broken\.ps1'
	}

	It 'PSHG-TestScriptErrorHandling exits 2 and warns (so 6>$null cannot hide it) for a parse error' {
		$Warn = $null
		$null = PSHG-TestScriptErrorHandling -Path $Script:Broken -WarningVariable Warn 6>$null
		$Global:LASTEXITCODE | Should -Be 2
		"$Warn" | Should -Match 'SKIPPED .*broken\.ps1'
	}

	It 'PSHG-TestScriptErrorHandling exits 2 for a path that is not a file' {
		$null = PSHG-TestScriptErrorHandling -Path (Join-Path $Script:Dir 'missing.ps1') 3>$null 6>$null
		$Global:LASTEXITCODE | Should -Be 2
	}

	It 'PSHG-TestScriptErrorHandling still reports findings (exit 1) when another file was skipped' {
		$Private:Bad = Initialize-ReviewFile -Dir 'unchecked-mixed' -Name 'empty-catch.ps1' -Body "function Get-Y { try { 1 } catch { } }`n"
		$null = PSHG-TestScriptErrorHandling -Path $Private:Bad, $Script:Broken -Quiet 3>$null 6>$null
		$Global:LASTEXITCODE | Should -Be 1
	}

	It 'PSHG-InvokeSilentFailureSweep exits 2 when a file under the tree cannot be parsed' {
		$null = PSHG-InvokeSilentFailureSweep -Path $Script:Dir *>&1
		$Global:LASTEXITCODE | Should -Be 2
	}

	It 'PSHG-FindHardcodedWindowsPath exits 2 when nothing was found but a file was skipped' {
		$null = PSHG-FindHardcodedWindowsPath -Path $Script:Dir *>&1
		$Global:LASTEXITCODE | Should -Be 2
	}

	It 'an unreadable (locked) file is NOT CHECKED, not skipped silently' {
		$Private:Locked = Initialize-ReviewFile -Dir 'locked' -Name 'locked.ps1' -Body "function Get-Z { 1 }`n"
		$Private:Handle = [System.IO.File]::Open($Private:Locked, 'Open', 'ReadWrite', 'None')
		try { $null = PSHG-TestBareKeywordCommand -Path $Private:Locked *>&1 }
		finally { $Private:Handle.Dispose() }
		$Global:LASTEXITCODE | Should -Be 2
	}

	It 'PSHG-TestScriptSyntax exits 1 for a path that does not exist' {
		$null = PSHG-TestScriptSyntax -Path (Join-Path $Script:Dir 'nothing-here.ps1') *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}

	It 'a class file whose only parse errors are unresolved sibling types is scanned, not skipped' {
		$Private:Class = Initialize-ReviewFile -Dir 'classfile' -Name 'class.ps1' -Body "class A : NoSuchBase { [string]`$P }`n"
		$null = PSHG-TestBareKeywordCommand -Path $Private:Class *>&1
		$Global:LASTEXITCODE | Should -Be 0
		$null = PSHG-TestScriptErrorHandling -Path $Private:Class -Quiet 3>$null 6>$null
		$Global:LASTEXITCODE | Should -Be 0
	}
}

Describe 'AST checkers scan .psm1 files' {
	BeforeAll {
		# Copies a shipped Bad example to <TestDrive>\<Dir>\module.psm1 and returns the folder.
		function Copy-BadAsPsm1
		{
			Param ([String]$Dir, [String]$Example)
			$Private:Folder = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath $Dir
			$null = New-Item -ItemType Directory -Path $Private:Folder -Force
			Copy-Item -LiteralPath (Join-Path $Script:BadDir $Example) -Destination (Join-Path $Private:Folder 'module.psm1')
			return $Private:Folder
		}
	}

	It 'PSHG-TestBareKeywordCommand flags a .psm1' {
		$null = PSHG-TestBareKeywordCommand -Path (Copy-BadAsPsm1 -Dir 'psm1-bare' -Example 'BareKeywordMisparse.ps1') *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'PSHG-TestFinallyThrow flags a .psm1' {
		$null = PSHG-TestFinallyThrow -Path (Copy-BadAsPsm1 -Dir 'psm1-finally' -Example 'ThrowInsideFinally.ps1') *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'PSHG-TestGetNewClosurePrivateScope flags a .psm1' {
		$null = PSHG-TestGetNewClosurePrivateScope -Path (Copy-BadAsPsm1 -Dir 'psm1-priv' -Example 'ClosurePrivateScopeCapture.ps1') *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'PSHG-TestJoinPathDriveRoot flags a .psm1' {
		$null = PSHG-TestJoinPathDriveRoot -Path (Copy-BadAsPsm1 -Dir 'psm1-join' -Example 'JoinPathDriveRoot.ps1') *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'PSHG-TestGetNewClosureScope flags a .psm1' {
		$Private:File = Initialize-ReviewFile -Dir 'psm1-closure' -Name 'module.psm1' -Body "function Outer {`n    `$Kept = 1`n    `$SB = { `$Kept + `$Missing }.GetNewClosure()`n}`n"
		$null = PSHG-TestGetNewClosureScope -Path (Split-Path $Private:File -Parent) *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'PSHG-TestScriptSyntax folder mode reports a parse error in a .psm1' {
		$Private:File = Initialize-ReviewFile -Dir 'psm1-syntax' -Name 'module.psm1' -Body "function Get-X {`n"
		$null = PSHG-TestScriptSyntax -Path (Split-Path $Private:File -Parent) *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}
}

Describe 'PSHG-TestFinallyThrow nesting' {
	It 'flags a throw in a catch that sits inside a finally' {
		$Private:File = Initialize-ReviewFile -Dir 'finally-nested' -Name 'a.ps1' -Body "function F { try { 1 } finally { try { 2 } catch { throw } } }`n"
		$null = PSHG-TestFinallyThrow -Path $Private:File *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'does not flag a throw in the BODY of a try that has a catch, inside a finally' {
		$Private:File = Initialize-ReviewFile -Dir 'finally-handled' -Name 'a.ps1' -Body "function F { try { 1 } finally { try { throw 'x' } catch { } } }`n"
		$null = PSHG-TestFinallyThrow -Path $Private:File *>&1
		$Global:LASTEXITCODE | Should -Be 0
	}
}

Describe 'Wildcard characters in paths' {
	It 'AST checkers accept a folder whose name contains [ and ]' {
		$Private:File = Initialize-ReviewFile -Dir 'bracket[1]' -Name 'a.ps1' -Body "function Get-Q { 1 }`n"
		$null = PSHG-TestBareKeywordCommand -Path (Split-Path $Private:File -Parent) *>&1
		$Global:LASTEXITCODE | Should -Be 0
	}
}

Describe 'PSHG-TestModuleVersionSelfReference boundaries' {
	BeforeAll {
		# Builds <Root>\Widget\<each of -Versions>, writes $Line into <Current>\Open.ps1, returns exit code and output.
		function Test-VersionLine
		{
			Param ([String]$Name, [String[]]$Versions, [String]$Current, [String]$Line, [String]$RootPath)
			$Private:Root = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath $Name
			foreach ($Private:V in $Versions) { $null = New-Item -ItemType Directory -Path (Join-Path $Private:Root "Widget\$Private:V") -Force }
			Set-Content -LiteralPath (Join-Path $Private:Root "Widget\$Current\Open.ps1") -Value $Line
			$Private:Splat = @{ RootPath = $(if ($RootPath) { $RootPath } else { $Private:Root }); Module = 'Widget'; Version = $Current }
			$Private:Out = PSHG-TestModuleVersionSelfReference @Private:Splat *>&1 | Out-String
			[PSCustomObject]@{ Code = $Global:LASTEXITCODE; Out = $Private:Out; Root = $Private:Root }
		}
	}

	It 'does not report 0.1 as a self-reference when the line pins 0.17' {
		(Test-VersionLine -Name 'b1' -Versions '0.1', '0.17' -Current '0.17' -Line 'Import-Module -Name Widget -RequiredVersion 0.17').Code | Should -Be 0
	}
	It 'does not report 0.1 inside 0.10' {
		(Test-VersionLine -Name 'b2' -Versions '0.1', '0.10' -Current '0.10' -Line "Open-Thing -ModuleName 'Widget' -ModuleVersion '0.10'").Code | Should -Be 0
	}
	It 'does not report 0.1 for a path segment, name/version pair or pin that names 0.17' {
		(Test-VersionLine -Name 'b3' -Versions '0.1', '0.17' -Current '0.17' -Line "`$p = 'Widget\0.17\x.ps1'").Code | Should -Be 0
		(Test-VersionLine -Name 'b4' -Versions '0.1', '0.17' -Current '0.17' -Line "@{ Name = 'Widget'; Version = '0.17' }").Code | Should -Be 0
	}
	It 'still reports a real pin on 0.1' {
		(Test-VersionLine -Name 'b5' -Versions '0.1', '0.17' -Current '0.17' -Line 'Import-Module -Name Widget -RequiredVersion 0.1').Code | Should -Be 1
		(Test-VersionLine -Name 'b6' -Versions '0.1', '0.17' -Current '0.17' -Line "Open-Thing -ModuleName 'Widget' -ModuleVersion '0.1'").Code | Should -Be 1
	}
	It 'recognises version folders with three numeric parts' {
		(Test-VersionLine -Name 'b7' -Versions '0.17', '0.17.1' -Current '0.17.1' -Line 'Import-Module -Name Widget -RequiredVersion 0.17').Code | Should -Be 1
	}
	It 'prints file names relative to the root when -RootPath is relative' {
		$Private:Base = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'rel'
		$null = New-Item -ItemType Directory -Path (Join-Path $Private:Base 'Widget\1.0'), (Join-Path $Private:Base 'Widget\1.1') -Force
		Set-Content -LiteralPath (Join-Path $Private:Base 'Widget\1.1\Open.ps1') -Value 'Import-Module Widget -RequiredVersion 1.0'
		Push-Location -LiteralPath (Resolve-Path -Path $TestDrive).ProviderPath
		try { $Private:Out = PSHG-TestModuleVersionSelfReference -RootPath '.\rel' -Module Widget -Version 1.1 *>&1 | Out-String }
		finally { Pop-Location }
		$Private:Out | Should -Match '  Widget\\1\.1\\Open\.ps1:1'
	}
}

Describe 'PSHG-FindHardcodedWindowsPath -Fix safety' {
	It 'does not rewrite a regex-escaped path literal' {
		$Private:File = Initialize-ReviewFile -Dir 'fix-regex' -Name 'a.ps1' -Body "`$pattern = 'C:\\Windows\\System32'`nif (`$x -match `$pattern) { 1 }`n"
		$Private:Before = [System.IO.File]::ReadAllText($Private:File)
		$null = PSHG-FindHardcodedWindowsPath -Path $Private:File -Fix *>&1
		[System.IO.File]::ReadAllText($Private:File) | Should -Be $Private:Before
	}
	It 'does not rewrite the operand of -match' {
		$Private:File = Initialize-ReviewFile -Dir 'fix-match' -Name 'a.ps1' -Body "`$ok = `$x -match 'C:\Windows'`n"
		$Private:Before = [System.IO.File]::ReadAllText($Private:File)
		$null = PSHG-FindHardcodedWindowsPath -Path $Private:File -Fix *>&1
		[System.IO.File]::ReadAllText($Private:File) | Should -Be $Private:Before
	}
	It 'does not rewrite code in a .psd1 data file' {
		$Private:File = Initialize-ReviewFile -Dir 'fix-psd1' -Name 'data.psd1' -Body "`$d = 'C:\ProgramData\x'`n@{ A = 1 }`n"
		$Private:Before = [System.IO.File]::ReadAllText($Private:File)
		$null = PSHG-FindHardcodedWindowsPath -Path $Private:File -Fix *>&1
		[System.IO.File]::ReadAllText($Private:File) | Should -Be $Private:Before
	}
	It 'does not treat a string inside a script block as a decision site because the word Path appears elsewhere in the command' {
		$Private:File = Initialize-ReviewFile -Dir 'fix-cmdtext' -Name 'a.ps1' -Body "Get-ChildItem . | ForEach-Object { Write-Host 'C:\Windows\x'; `$FilePath = 1 }`n"
		$Private:Before = [System.IO.File]::ReadAllText($Private:File)
		$null = PSHG-FindHardcodedWindowsPath -Path $Private:File -Fix *>&1
		[System.IO.File]::ReadAllText($Private:File) | Should -Be $Private:Before
	}
	It 'still rewrites a literal bound to a path parameter' {
		$Private:File = Initialize-ReviewFile -Dir 'fix-param' -Name 'a.ps1' -Body "Get-ChildItem -Path 'C:\ProgramData\MyApp'`n"
		$null = PSHG-FindHardcodedWindowsPath -Path $Private:File -Fix *>&1
		[System.IO.File]::ReadAllText($Private:File) | Should -Match ([Regex]::Escape('$env:ProgramData'))
	}
	It 'refuses a file that is not valid UTF-8 and leaves its bytes unchanged' {
		$Private:Dir = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'fix-ansi'
		$null = New-Item -ItemType Directory -Path $Private:Dir -Force
		$Private:File = Join-Path $Private:Dir 'ansi.ps1'
		$Private:Bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes("# caf" + [char]0xE9 + "`n`$d = 'C:\ProgramData\x'`n")
		[System.IO.File]::WriteAllBytes($Private:File, $Private:Bytes)
		$Private:Out = PSHG-FindHardcodedWindowsPath -Path $Private:File -Fix *>&1 | Out-String
		([System.IO.File]::ReadAllBytes($Private:File) -join ',') | Should -Be ($Private:Bytes -join ',')
		$Private:Out | Should -Match 'REFUSED'
	}
	It '-WhatIf writes nothing' {
		$Private:File = Initialize-ReviewFile -Dir 'fix-whatif' -Name 'a.ps1' -Body "`$d = 'C:\ProgramData\x'`n"
		$Private:Before = [System.IO.File]::ReadAllText($Private:File)
		$null = PSHG-FindHardcodedWindowsPath -Path $Private:File -Fix -WhatIf *>&1
		[System.IO.File]::ReadAllText($Private:File) | Should -Be $Private:Before
	}
}

Describe 'PSHG-TestFileEncoding -Fix edge cases' {
	BeforeAll {
		function Initialize-ByteFile
		{
			Param ([String]$Name, [Byte[]]$Bytes)
			$Private:Dir = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'enc'
			$null = New-Item -ItemType Directory -Path $Private:Dir -Force
			$Private:File = Join-Path $Private:Dir $Name
			[System.IO.File]::WriteAllBytes($Private:File, $Bytes)
			return $Private:File
		}
	}

	It 'repairs a file that is only two BOMs to exactly one BOM' {
		$Private:File = Initialize-ByteFile -Name 'only-boms.ps1' -Bytes ([Byte[]](0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF))
		$null = PSHG-TestFileEncoding -Path $Private:File -Fix *>&1
		([System.IO.File]::ReadAllBytes($Private:File) -join ',') | Should -Be '239,187,191'
	}
	It 'repairs a doubled BOM in front of a valid body' {
		$Private:File = Initialize-ByteFile -Name 'double.ps1' -Bytes ([Byte[]](0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x61, 0x0A))
		$null = PSHG-TestFileEncoding -Path $Private:File -Fix *>&1
		([System.IO.File]::ReadAllBytes($Private:File) -join ',') | Should -Be '239,187,191,35,32,97,10'
	}
	It 'leaves a doubled BOM in front of an ANSI body untouched and reports it for review' {
		$Private:Bytes = [Byte[]](0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A)
		$Private:File = Initialize-ByteFile -Name 'double-ansi.ps1' -Bytes $Private:Bytes
		$null = PSHG-TestFileEncoding -Path $Private:File -Fix *>&1
		$Global:LASTEXITCODE | Should -Be 2
		([System.IO.File]::ReadAllBytes($Private:File) -join ',') | Should -Be ($Private:Bytes -join ',')
	}
	It 'does not count a BOM in front of an invalid UTF-8 body as compliant' {
		$Private:File = Initialize-ByteFile -Name 'bom-ansi.ps1' -Bytes ([Byte[]](0xEF, 0xBB, 0xBF, 0x23, 0x20, 0x63, 0x61, 0x66, 0xE9, 0x0A))
		$null = PSHG-TestFileEncoding -Path $Private:File *>&1
		$Global:LASTEXITCODE | Should -Be 2
	}
	It 'reports a named path that does not exist instead of ignoring it' {
		$null = PSHG-TestFileEncoding -Path (Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'enc\no-such.ps1') *>&1
		$Global:LASTEXITCODE | Should -Be 2
	}
	It '-Fix -WhatIf writes nothing and still reports work to do' {
		$Private:Bytes = [Byte[]](0x23, 0x20, 0x61, 0x0A)
		$Private:File = Initialize-ByteFile -Name 'whatif.ps1' -Bytes $Private:Bytes
		$null = PSHG-TestFileEncoding -Path $Private:File -Fix -WhatIf *>&1
		([System.IO.File]::ReadAllBytes($Private:File) -join ',') | Should -Be ($Private:Bytes -join ',')
		$Global:LASTEXITCODE | Should -Be 1
	}
}

Describe 'PSHG-TestRepoLint with a failing analyzer, custom rules and the shipped baseline' {
	$HasPssa = [Boolean](Get-Module -ListAvailable -Name PSScriptAnalyzer)
	BeforeAll {
		$Script:ShippedLint  = Join-Path $Script:ModuleRoot 'PSHygieneGuardBaseline\RepoLint-Baseline.psd1'
		$Script:ShippedError = Join-Path $Script:ModuleRoot 'PSHygieneGuardBaseline\ErrorHandling-Baseline.psd1'
	}

	It 'is not a pass when a file could not be analyzed (exit 2)' -Skip:(-not $HasPssa) {
		$Private:File = Initialize-ReviewFile -Dir 'lint-locked' -Name 'b.ps1' -Body "function Set-B { 1 }`n"
		$Private:Dir = Split-Path $Private:File -Parent
		$Private:Baseline = Join-Path $Private:Dir 'base.psd1'
		Set-Content -LiteralPath $Private:Baseline -Value '@{ Accepted = @() }'
		$Private:Handle = [System.IO.File]::Open($Private:File, 'Open', 'ReadWrite', 'None')
		try { $null = PSHG-TestRepoLint -Path $Private:Dir -BaselinePath $Private:Baseline -RepoRoot $Private:Dir -Rule PSUseShouldProcessForStateChangingFunctions *>&1 }
		finally { $Private:Handle.Dispose() }
		$Global:LASTEXITCODE | Should -Be 2
	}

	It 'a baselined finding of a custom rule does not accept a later one in the same file' -Skip:(-not $HasPssa) {
		$Private:File = Initialize-ReviewFile -Dir 'lint-custom' -Name 'c.ps1' -Body "function One { gci . }`nfunction Two { gci . }`n"
		$Private:Dir = Split-Path $Private:File -Parent
		$Private:Baseline = Join-Path $Private:Dir 'base.psd1'
		Set-Content -LiteralPath $Private:Baseline -Value '@{ Accepted = @() }'
		$null = PSHG-TestRepoLint -Path $Private:Dir -BaselinePath $Private:Baseline -RepoRoot $Private:Dir -Rule PSAvoidUsingCmdletAliases -UpdateBaseline *>&1
		$null = PSHG-TestRepoLint -Path $Private:Dir -BaselinePath $Private:Baseline -RepoRoot $Private:Dir -Rule PSAvoidUsingCmdletAliases *>&1
		$Global:LASTEXITCODE | Should -Be 0
		[System.IO.File]::WriteAllText($Private:File, "function One { gci . }`nfunction Two { gci . }`nfunction Three { gci . }`n", $Script:Bom)
		$null = PSHG-TestRepoLint -Path $Private:Dir -BaselinePath $Private:Baseline -RepoRoot $Private:Dir -Rule PSAvoidUsingCmdletAliases *>&1
		$Global:LASTEXITCODE | Should -Be 1
	}

	It 'accepts a folder whose name contains [ and ]' -Skip:(-not $HasPssa) {
		$Private:File = Initialize-ReviewFile -Dir 'lint[x]' -Name 'a.ps1' -Body "function Get-A { 1 }`n"
		$Private:Dir = Split-Path $Private:File -Parent
		$Private:Baseline = Join-Path (Split-Path $Private:Dir -Parent) 'lint-brackets-base.psd1'
		Set-Content -LiteralPath $Private:Baseline -Value '@{ Accepted = @() }'
		$null = PSHG-TestRepoLint -Path $Private:Dir -BaselinePath $Private:Baseline -RepoRoot (Split-Path $Private:Dir -Parent) *>&1
		$Global:LASTEXITCODE | Should -Be 0
	}

	It 'PSHG-TestRepoLint -UpdateBaseline without -BaselinePath exits 2 and leaves the shipped template unchanged' -Skip:(-not $HasPssa) {
		$Private:Before = (Get-FileHash -LiteralPath $Script:ShippedLint -Algorithm SHA256).Hash
		$Private:File = Initialize-ReviewFile -Dir 'lint-shipped' -Name 'a.ps1' -Body "function Set-A { 1 }`n"
		$null = PSHG-TestRepoLint -Path (Split-Path $Private:File -Parent) -UpdateBaseline *>&1
		$Global:LASTEXITCODE | Should -Be 2
		(Get-FileHash -LiteralPath $Script:ShippedLint -Algorithm SHA256).Hash | Should -Be $Private:Before
	}

	It 'PSHG-TestScriptErrorHandling -UpdateBaseline without -Baseline exits 2 and leaves the shipped template unchanged' {
		$Private:Before = (Get-FileHash -LiteralPath $Script:ShippedError -Algorithm SHA256).Hash
		$Private:File = Initialize-ReviewFile -Dir 'eh-shipped' -Name 'a.ps1' -Body "function Get-Y { try { 1 } catch { } }`n"
		$null = PSHG-TestScriptErrorHandling -Path $Private:File -UpdateBaseline -Quiet 3>$null 6>$null
		$Global:LASTEXITCODE | Should -Be 2
		(Get-FileHash -LiteralPath $Script:ShippedError -Algorithm SHA256).Hash | Should -Be $Private:Before
	}
}

Describe 'PSHG-TestScriptErrorHandling input handling' {
	It 'treats a trailing slash on -RepoRoot like none (same baseline key)' {
		$Private:File = Initialize-ReviewFile -Dir 'eh-slash' -Name 'a.ps1' -Body "function Get-Z { try { 1 } catch { } }`n"
		$Private:Root = Split-Path $Private:File -Parent
		$Private:K1 = (PSHG-TestScriptErrorHandling -Path $Private:File -RepoRoot $Private:Root -Quiet 3>$null 6>$null).Key
		$Private:K2 = (PSHG-TestScriptErrorHandling -Path $Private:File -RepoRoot ($Private:Root + '\') -Quiet 3>$null 6>$null).Key
		$Private:K1 | Should -Match '^AP7\|a\.ps1\|Get-Z\|'
		$Private:K2 | Should -Be $Private:K1
	}
	It 'warns when a file lies outside -RepoRoot (its key would hold an absolute path)' {
		$Private:File = Initialize-ReviewFile -Dir 'eh-outside' -Name 'a.ps1' -Body "function Get-Z { try { 1 } catch { } }`n"
		$Warn = $null
		$null = PSHG-TestScriptErrorHandling -Path $Private:File -RepoRoot (Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'elsewhere') -Quiet -WarningVariable Warn 6>$null
		"$Warn" | Should -Match 'outside -RepoRoot'
	}
	It 'rejects a -WrapperName or -CollectorName that is not a plain function name' {
		$Private:File = Initialize-ReviewFile -Dir 'eh-names' -Name 'a.ps1' -Body "function Get-Z { 1 }`n"
		$ScanFile = $Private:File
		{ PSHG-TestScriptErrorHandling -Path $ScanFile -TestWrapper -WrapperName 'x; Get-Date' } | Should -Throw
		{ PSHG-TestScriptErrorHandling -Path $ScanFile -TestWrapper -CollectorName '$(Get-Date)' } | Should -Throw
	}
	It 'documents that -TestWrapper runs code from the scanned file' {
		(Get-Help PSHG-TestScriptErrorHandling -Full | Out-String) | Should -Match 'EXECUTES code taken from the file being scanned'
	}
}

Describe 'Module structure' {
	It 'no two functions share a $Script: variable name' {
		$Private:Owners = @{}
		foreach ($Private:F in (Get-ChildItem -LiteralPath (Join-Path $Script:ModuleRoot 'Functions') -Filter '*.ps1'))
		{
			$Private:Ast = [System.Management.Automation.Language.Parser]::ParseFile($Private:F.FullName, [ref]$null, [ref]$null)
			$Private:Names = $Private:Ast.FindAll({ Param($N) $N -is [System.Management.Automation.Language.VariableExpressionAst] -and $N.VariablePath.IsScript }, $true) |
				ForEach-Object { $_.VariablePath.UserPath -replace '^(?i:script):', '' } | Sort-Object -Unique
			foreach ($Private:Name in $Private:Names)
			{
				if (-not $Private:Owners.ContainsKey($Private:Name)) { $Private:Owners[$Private:Name] = [System.Collections.Generic.List[String]]::new() }
				$Private:Owners[$Private:Name].Add($Private:F.Name)
			}
		}
		$Private:Shared = @($Private:Owners.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 } | ForEach-Object { '{0}: {1}' -f $_.Key, ($_.Value -join ', ') })
		$Private:Shared | Should -BeNullOrEmpty
	}

	It 'importing a copy of the module without its Functions folder fails loudly' {
		$Private:Copy = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'broken-module\PSHygieneGuard'
		$null = New-Item -ItemType Directory -Path $Private:Copy -Force
		Copy-Item -LiteralPath (Join-Path $Script:ModuleRoot 'PSHygieneGuard.psd1'), (Join-Path $Script:ModuleRoot 'PSHygieneGuard.psm1') -Destination $Private:Copy
		$CopyManifest = Join-Path $Private:Copy 'PSHygieneGuard.psd1'
		{ Import-Module $CopyManifest -Force -ErrorAction Stop -WarningAction SilentlyContinue } | Should -Throw
		# Restore the real module for any test that runs after this one.
		Import-Module (Join-Path $Script:ModuleRoot 'PSHygieneGuard.psd1') -Force -WarningAction SilentlyContinue
	}

	It 'the atomic writer replaces a file, creates a missing one, and leaves no temp file behind' {
		$Private:Dir = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'atomic'
		$null = New-Item -ItemType Directory -Path $Private:Dir -Force
		InModuleScope PSHygieneGuard -Parameters @{ Dir = $Private:Dir } {
			Param ($Dir)
			$Existing = Join-Path $Dir 'existing.txt'
			[System.IO.File]::WriteAllBytes($Existing, [Byte[]](1, 2, 3))
			Write-PSHGFileAtomic -Path $Existing -Bytes ([Byte[]](9, 8))
			([System.IO.File]::ReadAllBytes($Existing) -join ',') | Should -Be '9,8'
			$New = Join-Path $Dir 'new.txt'
			Write-PSHGFileAtomic -Path $New -Bytes ([Byte[]](7))
			([System.IO.File]::ReadAllBytes($New) -join ',') | Should -Be '7'
			@(Get-ChildItem -LiteralPath $Dir -Filter '*.tmp').Count | Should -Be 0
		}
	}
}
