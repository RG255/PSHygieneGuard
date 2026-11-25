#requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
	.SYNOPSIS
	Pester suite for PSHygieneGuard, run against the module's own Examples\ fixtures.

	.DESCRIPTION
	Every assertion here uses the SHIPPED Examples\Good\ and Examples\Bad.zip fixtures - the
	same files a new user is pointed at in the README - so a test failure here means the
	documented example set and the actual checker behavior have drifted apart.

	Examples\Bad\ ships as a ZIP, not live .ps1 files (see Demo\Invoke-Demo.ps1's own help for
	why) - this suite extracts it to a disposable temp folder in BeforeAll and cleans it up in
	AfterAll, never touching the shipped .zip itself.
#>

BeforeAll {
	Remove-Module -Name PSHygieneGuard -Force -ErrorAction SilentlyContinue
	Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\PSHygieneGuard.psd1') -Force

	$Script:ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
	$Script:GoodDir    = Join-Path $Script:ModuleRoot 'Examples\Good'
	$Script:BadZip     = Join-Path $Script:ModuleRoot 'Examples\Bad.zip'
	$Script:BadDir     = Join-Path $env:TEMP ('pshg-bad-extracted-' + [guid]::NewGuid().ToString('N'))
	Expand-Archive -LiteralPath $Script:BadZip -DestinationPath $Script:BadDir -Force
}

AfterAll {
	Remove-Item -LiteralPath $Script:BadDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Module manifest' {
	It 'exports exactly the 17 documented functions' {
		$Exported = (Get-Command -Module PSHygieneGuard).Name
		$Exported.Count | Should -Be 17
		$Exported | Should -Contain 'PSHG-TestLivePinLiteral'
		$Exported | Should -Contain 'PSHG-TestTypographicQuoteEscape'
		$Exported | Should -Contain 'PSHG-TestUnescapedLiteral'
		$Exported | Should -Contain 'PSHG-TestJoinPathDriveRoot'
		$Exported | Should -Contain 'PSHG-TestScriptSyntax'
		$Exported | Should -Contain 'PSHG-TestScriptErrorHandling'
	}
}

Describe 'PSHG-TestScriptSyntax' {
	It 'reports clean parse (return 3, no PSScriptAnalyzer findings expected) or clean findings for a well-formed Good example' {
		$Private:Result = PSHG-TestScriptSyntax -Path (Join-Path $Script:GoodDir 'CorrectBareKeywordUsage.ps1') 6>$null
		# Returns 0 (clean) or 3 (PSScriptAnalyzer not installed, parse-only) - never 1 (parse error).
		$Global:LASTEXITCODE | Should -Not -Be 1
	}
}

Describe 'PSHG-TestBareKeywordCommand' {
	It 'flags the Bad example' {
		$null = PSHG-TestBareKeywordCommand -Path (Join-Path $Script:BadDir 'BareKeywordMisparse.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'passes the Good example clean' {
		$null = PSHG-TestBareKeywordCommand -Path (Join-Path $Script:GoodDir 'CorrectBareKeywordUsage.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 0
	}
}

Describe 'PSHG-TestJoinPathDriveRoot' {
	# The Bad fixtures are written here rather than shipped in Examples\Bad.zip: the pattern is a few lines and each case matters on its own.
	BeforeAll {
		$Script:JpDir = Join-Path $TestDrive 'jp'
		$null = New-Item -ItemType Directory -Path $Script:JpDir -Force
		$Script:Bad = {
			Param ([String]$Body)
			$F = Join-Path $Script:JpDir ('bad-' + [guid]::NewGuid().ToString('N') + '.ps1')
			Set-Content -LiteralPath $F -Value $Body
			$null = PSHG-TestJoinPathDriveRoot -Path $F 6>$null
			$Global:LASTEXITCODE
		}
	}

	It 'passes the shipped Good example clean (including the line carrying the PSHG-OK marker)' {
		$null = PSHG-TestJoinPathDriveRoot -Path (Join-Path $Script:GoodDir 'CorrectJoinPathDriveRoot.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 0
	}
	It 'flags the shipped Bad example, both functions in it' {
		$null = PSHG-TestJoinPathDriveRoot -Path (Join-Path $Script:BadDir 'JoinPathDriveRoot.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 1
		$Out = PSHG-TestJoinPathDriveRoot -Path (Join-Path $Script:BadDir 'JoinPathDriveRoot.ps1') 6>&1 | Out-String
		$Out | Should -Match '2 finding\(s\)'
	}
	It 'flags a format-string drive root passed with -Path' {
		(& $Script:Bad 'Join-Path -Path (''{0}:\'' -f $L) -ChildPath $R') | Should -Be 1
	}
	It 'flags a format-string drive root passed positionally' {
		(& $Script:Bad 'Join-Path (''{0}:\'' -f $L) $R') | Should -Be 1
	}
	It 'flags an interpolated ${Letter}: drive root' {
		(& $Script:Bad 'Join-Path -Path "${L}:\x" -ChildPath y') | Should -Be 1
	}
	It 'flags an interpolated $($Letter): drive root' {
		(& $Script:Bad 'Join-Path -Path "$($L):\x" -ChildPath y') | Should -Be 1
	}
	It 'flags the drive root even when a switch or other parameter comes first' {
		(& $Script:Bad 'Join-Path -ChildPath $R -Path (''{0}:\'' -f $L) -Resolve') | Should -Be 1
	}
	It 'does not flag a literal drive, a path held in a variable, or a child path that looks like a template' {
		(& $Script:Bad 'Join-Path -Path ''C:\Temp'' -ChildPath ''x''') | Should -Be 0
		(& $Script:Bad 'Join-Path -Path $Base -ChildPath $Name') | Should -Be 0
		(& $Script:Bad 'Join-Path -Path $Base -ChildPath (''{0}:\'' -f $L)') | Should -Be 0
	}
	It 'does not flag the .NET path API that replaces it' {
		(& $Script:Bad '[System.IO.Path]::Combine((''{0}:\'' -f $L), $R)') | Should -Be 0
	}
	It 'skips a line carrying the PSHG-OK marker, and only that line' {
		(& $Script:Bad "Join-Path -Path ('{0}:\' -f `$L) -ChildPath `$R # PSHG-OK: JoinPathDriveRoot") | Should -Be 0
		(& $Script:Bad "Join-Path -Path ('{0}:\' -f `$L) -ChildPath `$R # PSHG-OK: JoinPathDriveRoot`nJoin-Path -Path ('{0}:\' -f `$M) -ChildPath `$R") | Should -Be 1
	}
}

Describe 'PSHG-TestFinallyThrow' {
	It 'flags the Bad example' {
		$null = PSHG-TestFinallyThrow -Path (Join-Path $Script:BadDir 'ThrowInsideFinally.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'passes the Good example clean' {
		$null = PSHG-TestFinallyThrow -Path (Join-Path $Script:GoodDir 'CorrectFinallyUsage.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 0
	}
}

Describe 'PSHG-TestGetNewClosurePrivateScope' {
	It 'flags the Bad example' {
		$null = PSHG-TestGetNewClosurePrivateScope -Path (Join-Path $Script:BadDir 'ClosurePrivateScopeCapture.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'passes the Good example clean' {
		$null = PSHG-TestGetNewClosurePrivateScope -Path (Join-Path $Script:GoodDir 'CorrectClosureVariableCapture.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 0
	}
}

Describe 'PSHG-TestGetNewClosureScope' {
	BeforeAll {
		# Writes $Body to <TestDrive>\<Name>\sample.ps1, runs the checker on it, returns Code (exit code) + Out (console text).
		function Test-ClosureSample
		{
			Param ([String]$Name, [String]$Body, [String]$KnownSafePrefixPattern)
			$Private:Dir = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath $Name
			$null = New-Item -ItemType Directory -Path $Private:Dir -Force
			$Private:File = Join-Path $Private:Dir 'sample.ps1'
			Set-Content -LiteralPath $Private:File -Value $Body
			$Private:Splat = @{ Path = $Private:File }
			If ($KnownSafePrefixPattern) { $Private:Splat['KnownSafePrefixPattern'] = $KnownSafePrefixPattern }
			$Private:Out = PSHG-TestGetNewClosureScope @Private:Splat 6>&1 | Out-String
			[PSCustomObject]@{ Code = $Global:LASTEXITCODE; Out = $Private:Out }
		}
	}

	It 'flags the plain-variable trap and reports Kind Variable with the fix hint' {
		$Private:R = Test-ClosureSample -Name 'badvar' -Body @'
function Outer {
    $Kept = 1
    $SB = { $Kept + $Missing }.GetNewClosure()
}
'@
		$Private:R.Code | Should -Be 1
		$Private:R.Out | Should -Match '\[Variable\]'
		$Private:R.Out | Should -Match '\$Missing'
		$Private:R.Out | Should -Match '1 finding\(s\)'
		$Private:R.Out | Should -Not -Match '\$Kept'
	}
	It 'passes a closure whose references are all copied into the immediate scope first' {
		(Test-ClosureSample -Name 'goodvar' -Body @'
function Outer {
    Param ($FromParam)
    $Copy = 1
    $SB = { $Copy + $FromParam }.GetNewClosure()
}
'@).Code | Should -Be 0
	}
	It 'flags a variable that lives only in an outer scope (immediate scope only)' {
		$Private:R = Test-ClosureSample -Name 'grandparent' -Body @'
function Outer {
    $X = 1
    & {
        $SB = { $X }.GetNewClosure()
    }
}
'@
		$Private:R.Code | Should -Be 1
		$Private:R.Out | Should -Match '\[Variable\]'
	}
	It 'passes a closure that only reads its own parameters, assignments and foreach variable' {
		(Test-ClosureSample -Name 'ownlocals' -Body @'
function Outer {
    $SB = {
        Param ($P)
        $Q = $P + 1
        ForEach ($Item in 1..3) { $Q += $Item }
        $Q
    }.GetNewClosure()
}
'@).Code | Should -Be 0
	}
	It 'never flags automatic variables' {
		(Test-ClosureSample -Name 'autovars' -Body @'
function Outer {
    $SB = { $_; $PSItem; $args; $true; $null; $PSScriptRoot; $ErrorActionPreference }.GetNewClosure()
}
'@).Code | Should -Be 0
	}
	# The parser leaves VariablePath.DriveName empty for scope modifiers, so the exemption below must use IsScript/IsGlobal (and the
	# UsingExpressionAst parent for $using:). An earlier version tested DriveName ($Script:A -> UserPath 'Script:A', IsScript = True;
	# $using:C -> UserPath 'C') and so reported each of them as a Variable finding. Reverting the fix makes the
	# two exemption tests below fail.
	It 'never flags $Script:, $Global: or $using: variables (documented exemption)' {
		(Test-ClosureSample -Name 'safescopes' -Body @'
function Outer {
    $SB = { $Script:A; $Global:B; $using:C }.GetNewClosure()
}
'@).Code | Should -Be 0
	}
	It 'never flags a $Private: variable (that is the sibling checker''s job)' {
		(Test-ClosureSample -Name 'privateskip' -Body @'
function Outer {
    $SB = { $Private:Thing }.GetNewClosure()
}
'@).Code | Should -Be 0
	}
	# Same reason as above: the "assigned via $Script:/$Global: anywhere in the file" set must be filled from IsScript/IsGlobal with the prefix stripped.
	It 'does not flag a plain reference to a name assigned via $Script: elsewhere in the file (documented exemption)' {
		(Test-ClosureSample -Name 'scriptassigned' -Body @'
$Script:Config = 1
function Outer {
    $SB = { $Config }.GetNewClosure()
}
'@).Code | Should -Be 0
	}
	It 'never flags a $using: variable on its own, nor with a member access or an index' {
		(Test-ClosureSample -Name 'usingonly' -Body @'
function Outer {
    $SB = { $using:C; $using:D.Length; $using:E[0] }.GetNewClosure()
}
'@).Code | Should -Be 0
	}
	It 'the scope-qualified exemption is not too wide: a plain unrelated name, a $Local: name and a different $Script:-assigned name are still flagged' {
		$Private:R = Test-ClosureSample -Name 'scopetrap' -Body @'
$Script:Config = 1
function Outer {
    $SB = { $Script:Config; $Other; $Local:Thing; $Config2 }.GetNewClosure()
}
'@
		$Private:R.Code | Should -Be 1
		$Private:R.Out | Should -Match '3 finding\(s\)'
		$Private:R.Out | Should -Match '\$Other'
		$Private:R.Out | Should -Match '\$Local:Thing'
		$Private:R.Out | Should -Match '\$Config2'
		$Private:R.Out | Should -Not -Match '\$Script:Config\s'
	}
	It 'a name assigned via $Global: elsewhere in the file exempts only that name' {
		$Private:R = Test-ClosureSample -Name 'globalassigned' -Body @'
$Global:Shared = 1
function Outer {
    $SB = { $Shared; $NotShared }.GetNewClosure()
}
'@
		$Private:R.Code | Should -Be 1
		$Private:R.Out | Should -Match '1 finding\(s\)'
		$Private:R.Out | Should -Match '\$NotShared'
	}
	It 'honours -KnownSafePrefixPattern (case-sensitive) and still flags other names' {
		$Private:Body = @'
function Outer {
    $SB = { $Ext_Value + $Other }.GetNewClosure()
}
'@
		$Private:R = Test-ClosureSample -Name 'prefix' -Body $Private:Body -KnownSafePrefixPattern '^Ext_'
		$Private:R.Code | Should -Be 1
		$Private:R.Out | Should -Match '1 finding\(s\)'
		$Private:R.Out | Should -Match '\$Other'
		(Test-ClosureSample -Name 'prefixcase' -Body $Private:Body -KnownSafePrefixPattern '^ext_').Out | Should -Match '2 finding\(s\)'
	}
	It 'flags a bare call to a nested function and reports Kind NestedFunction' {
		$Private:R = Test-ClosureSample -Name 'badfn' -Body @'
function Outer {
    function Helper { 1 }
    $SB = { Helper }.GetNewClosure()
}
'@
		$Private:R.Code | Should -Be 1
		$Private:R.Out | Should -Match '\[NestedFunction\]'
	}
	It 'passes a nested function invoked through a captured scriptblock reference' {
		(Test-ClosureSample -Name 'goodfn' -Body @'
function Outer {
    function Helper { 1 }
    $HelperSB = ${function:Helper}
    $SB = { & $HelperSB }.GetNewClosure()
}
'@).Code | Should -Be 0
	}
	It 'ignores a scriptblock that is never closed over with GetNewClosure' {
		(Test-ClosureSample -Name 'noclosure' -Body @'
function Outer {
    function Helper { 1 }
    $SB = { $Missing; Helper }
}
'@).Code | Should -Be 0
	}
	It 'matches the GetNewClosure member name case-insensitively' {
		(Test-ClosureSample -Name 'casing' -Body '$SB = { $Missing }.getnewclosure()').Code | Should -Be 1
	}
	It 'analyses each nested GetNewClosure site on its own' {
		$Private:R = Test-ClosureSample -Name 'nested' -Body @'
function Outer {
    $Mid = 1
    $A = {
        $Inner = 2
        $B = { $Inner + $Mid }.GetNewClosure()
    }.GetNewClosure()
}
'@
		$Private:R.Code | Should -Be 1
		$Private:R.Out | Should -Match '\$Mid'
		$Private:R.Out | Should -Not -Match '\$Inner'
	}
	It 'does not throw on a file with a parse error and still returns an exit code' {
		{ $null = Test-ClosureSample -Name 'parseerr' -Body "function Broken {`n    `$x = (1 + `n" } | Should -Not -Throw
		# 2 = nothing found but the file could not be fully parsed, so the run is not clean.
		(Test-ClosureSample -Name 'parseerr' -Body "function Broken {`n    `$x = (1 + `n").Code | Should -Be 2
	}
	It 'still reports a finding that sits ahead of a parse error elsewhere in the file' {
		(Test-ClosureSample -Name 'parseerr2' -Body "function Outer { `$SB = { `$Missing }.GetNewClosure() }`nfunction Broken {`n    `$x = (1 + `n").Code | Should -Be 1
	}
	It 'throws for a path that does not exist' {
		{ PSHG-TestGetNewClosureScope -Path (Join-Path $TestDrive 'no-such-file.ps1') 6>$null } | Should -Throw '*Path not found*'
	}
	It 'scans a directory recursively, reports the relative path, and skips Originals, _RetiredModules and .git folders' {
		$Private:Root = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath 'dirmode'
		$Private:Bad = 'function Outer { $SB = { $Missing }.GetNewClosure() }'
		ForEach ($Private:Sub in 'sub', 'Originals\old', '_RetiredModules\x', '.git\y')
		{
			$null = New-Item -ItemType Directory -Path (Join-Path $Private:Root $Private:Sub) -Force
			Set-Content -LiteralPath (Join-Path $Private:Root "$Private:Sub\bad.ps1") -Value $Private:Bad
		}
		$Private:Out = PSHG-TestGetNewClosureScope -Path $Private:Root 6>&1 | Out-String
		$Global:LASTEXITCODE | Should -Be 1
		$Private:Out | Should -Match '1 finding\(s\)'
		$Private:Out | Should -Match 'sub\\bad\.ps1:1 \[Variable\]'
		$Private:Out | Should -Match 'Scanning 1 file\(s\)'
	}
	It 'passes (exit 0) on an empty directory' {
		$Private:Dir = Join-Path $TestDrive 'emptydir'
		$null = New-Item -ItemType Directory -Path $Private:Dir -Force
		$null = PSHG-TestGetNewClosureScope -Path $Private:Dir 6>$null
		$Global:LASTEXITCODE | Should -Be 0
	}
	It 'passes the shipped Good closure example clean' {
		$null = PSHG-TestGetNewClosureScope -Path (Join-Path $Script:GoodDir 'CorrectClosureVariableCapture.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 0
	}
}

Describe 'PSHG-FindDriveLetterAssumption' {
	It 'flags the unanchored regex in the Bad example' {
		$Rows = PSHG-FindDriveLetterAssumption -Path (Join-Path $Script:BadDir 'DriveLetterUnanchored.ps1') 6>$null
		$Rows.Count | Should -BeGreaterThan 0
	}
	It 'finds nothing in the Good example' {
		$Rows = PSHG-FindDriveLetterAssumption -Path (Join-Path $Script:GoodDir 'CorrectDriveLetterCheck.ps1') 6>$null
		$Rows.Count | Should -Be 0
	}
}

Describe 'PSHG-FindHardcodedWindowsPath' {
	$Private:Cases = @(
		@{ Pattern = 'ProgramData';     Bad = 'HardcodedWindowsPath.ps1';       Good = 'CorrectEnvironmentVariablePath.ps1' }
		@{ Pattern = 'ProgramFiles';    Bad = 'HardcodedProgramFiles.ps1';      Good = 'CorrectProgramFilesPath.ps1' }
		@{ Pattern = 'ProgramFilesX86'; Bad = 'HardcodedProgramFilesX86.ps1';   Good = 'CorrectProgramFilesX86Path.ps1' }
		@{ Pattern = 'Windows';         Bad = 'HardcodedWindowsFolder.ps1';     Good = 'CorrectWindowsFolderPath.ps1' }
		@{ Pattern = 'UsersNamed';      Bad = 'HardcodedUserProfilePath.ps1';   Good = 'CorrectUserProfilePath.ps1' }
		@{ Pattern = 'UsersPublic';     Bad = 'HardcodedUsersPublicPath.ps1';   Good = 'CorrectUsersPublicPath.ps1' }
	)

	It 'flags the <Pattern> pattern in its Bad example' -ForEach $Private:Cases {
		$Rows = PSHG-FindHardcodedWindowsPath -Path (Join-Path $Script:BadDir $Bad) 6>$null
		$Rows.Count | Should -BeGreaterThan 0
		$Rows[0].Pattern | Should -Be $Pattern
	}
	It 'finds nothing in the <Pattern> Good example' -ForEach $Private:Cases {
		$Rows = PSHG-FindHardcodedWindowsPath -Path (Join-Path $Script:GoodDir $Good) 6>$null
		$Rows.Count | Should -Be 0
	}

	It 'catches a hardcoded path used as a COMPLETE path with no trailing backslash (regression test)' {
		# User-found gap: an earlier version required a literal trailing \\, so a bare
		# Test-Path 'C:\ProgramData' (nothing after it) matched nothing at all.
		$Private:Probe = Join-Path $env:TEMP ('pshg-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
		"Test-Path 'C:\ProgramData'" | Set-Content -LiteralPath $Private:Probe -Encoding UTF8
		try
		{
			$Rows = PSHG-FindHardcodedWindowsPath -Path $Private:Probe 6>$null
			$Rows.Count | Should -Be 1
			$Rows[0].Pattern | Should -Be 'ProgramData'
		}
		finally { Remove-Item -LiteralPath $Private:Probe -Force -ErrorAction SilentlyContinue }
	}

	It 'counts "Program Files (x86)" once, under ProgramFilesX86 only, not also as plain ProgramFiles' {
		$Private:Probe = Join-Path $env:TEMP ('pshg-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
		"Test-Path 'C:\Program Files (x86)\LegacyTool'" | Set-Content -LiteralPath $Private:Probe -Encoding UTF8
		try
		{
			$Rows = PSHG-FindHardcodedWindowsPath -Path $Private:Probe 6>$null
			$Rows.Count | Should -Be 1
			$Rows[0].Pattern | Should -Be 'ProgramFilesX86'
		}
		finally { Remove-Item -LiteralPath $Private:Probe -Force -ErrorAction SilentlyContinue }
	}

	It 'finds a hardcoded path inside a COMMENT (comments carry no AST expression, scanned via the token stream)' {
		$Private:Probe = Join-Path $env:TEMP ('pshg-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
		"# See C:\ProgramData\MyApp\config.json for the schema`n`$x = 1" | Set-Content -LiteralPath $Private:Probe -Encoding UTF8
		try
		{
			$Rows = PSHG-FindHardcodedWindowsPath -Path $Private:Probe 6>$null
			$Rows.Count | Should -Be 1
			$Rows[0].Pattern | Should -Be 'ProgramData'
			$Rows[0].InComment | Should -Be $true
		}
		finally { Remove-Item -LiteralPath $Private:Probe -Force -ErrorAction SilentlyContinue }
	}

	Context '-Fix' {
		It 'rewrites a code hit at a decision site into a working, correctly-resolving expression' {
			$Private:Probe = Join-Path $env:TEMP ('pshg-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
			@'
Function Test-FixProbe
{
	$ConfigDir = 'C:\ProgramData\MyApp'
	return $ConfigDir
}
'@ | Set-Content -LiteralPath $Private:Probe -Encoding UTF8
			try
			{
				$null = PSHG-FindHardcodedWindowsPath -Path $Private:Probe -Fix 6>$null
				$Private:Fixed = Get-Content -LiteralPath $Private:Probe -Raw
				# The generated code must keep the '-f' placeholder (a real, prior bug silently
				# dropped it, producing a bare literal string with the env var discarded entirely)
				# and must be wrapped in its own (...) (a real, prior bug left it bare, which broke
				# as a command argument in a sibling test below).
				$Private:Fixed | Should -Match ([Regex]::Escape("([System.IO.Path]::GetFullPath(('{0}\MyApp' -f `$env:ProgramData)))"))
				# Prove it does not just PARSE - prove it actually RUNS and resolves correctly.
				. $Private:Probe
				(Test-FixProbe) | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $env:ProgramData 'MyApp')))
			}
			finally { Remove-Item -LiteralPath $Private:Probe -Force -ErrorAction SilentlyContinue }
		}

		It 'rewrites a bare-literal COMMAND ARGUMENT (e.g. Join-Path) into a still-valid, working call' {
			# Regression test: an earlier version substituted a bare, unparenthesized expression
			# here, which parses as several separate arguments instead of one value in command-
			# argument position - exactly this Join-Path shape.
			$Private:Probe = Join-Path $env:TEMP ('pshg-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
			@'
Function Test-FixProbeJoin
{
	$Exe = Join-Path 'C:\Program Files\MyApp' 'app.exe'
	return $Exe
}
'@ | Set-Content -LiteralPath $Private:Probe -Encoding UTF8
			try
			{
				$null = PSHG-FindHardcodedWindowsPath -Path $Private:Probe -Fix 6>$null
				. $Private:Probe
				(Test-FixProbeJoin) | Should -Be (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'MyApp'))) 'app.exe')
			}
			finally { Remove-Item -LiteralPath $Private:Probe -Force -ErrorAction SilentlyContinue }
		}

		It 'rewrites a COMMENT hit with a plain text substitution, not a live expression' {
			$Private:Probe = Join-Path $env:TEMP ('pshg-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
			"# See C:\ProgramData\MyApp\config.json for the schema`n`$x = 1" | Set-Content -LiteralPath $Private:Probe -Encoding UTF8
			try
			{
				$null = PSHG-FindHardcodedWindowsPath -Path $Private:Probe -Fix 6>$null
				$Private:Fixed = Get-Content -LiteralPath $Private:Probe -Raw
				$Private:Fixed | Should -Match ([Regex]::Escape('# See $env:ProgramData\MyApp\config.json for the schema'))
				$Private:Fixed | Should -Not -Match 'C:\\ProgramData'
			}
			finally { Remove-Item -LiteralPath $Private:Probe -Force -ErrorAction SilentlyContinue }
		}

		It 'never touches Users\<name> - genuinely ambiguous (current user vs. a specific other user), code or comment' {
			$Private:Probe = Join-Path $env:TEMP ('pshg-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
			@'
Function Test-FixProbeUser
{
	# lives at C:\Users\Alice\Desktop
	$UserFile = 'C:\Users\Alice\Documents\notes.txt'
	return $UserFile
}
'@ | Set-Content -LiteralPath $Private:Probe -Encoding UTF8
			try
			{
				$Private:Original = Get-Content -LiteralPath $Private:Probe -Raw
				$null = PSHG-FindHardcodedWindowsPath -Path $Private:Probe -Fix 6>$null
				(Get-Content -LiteralPath $Private:Probe -Raw) | Should -Be $Private:Original
			}
			finally { Remove-Item -LiteralPath $Private:Probe -Force -ErrorAction SilentlyContinue }
		}

		It 'never touches a code hit that is not a decision site (an incidental mention, e.g. a bare display string)' {
			$Private:Probe = Join-Path $env:TEMP ('pshg-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
			@'
Function Test-FixProbeDisplay
{
	Write-Host 'C:\Program Files (x86)\MyApp'
}
'@ | Set-Content -LiteralPath $Private:Probe -Encoding UTF8
			try
			{
				$Private:Original = Get-Content -LiteralPath $Private:Probe -Raw
				$null = PSHG-FindHardcodedWindowsPath -Path $Private:Probe -Fix 6>$null
				(Get-Content -LiteralPath $Private:Probe -Raw) | Should -Be $Private:Original
			}
			finally { Remove-Item -LiteralPath $Private:Probe -Force -ErrorAction SilentlyContinue }
		}

		It 'preserves the file''s BOM state exactly (present stays present, absent stays absent)' {
			$Private:ProbeBom   = Join-Path $env:TEMP ('pshg-probe-bom-' + [guid]::NewGuid().ToString('N') + '.ps1')
			$Private:ProbeNoBom = Join-Path $env:TEMP ('pshg-probe-nobom-' + [guid]::NewGuid().ToString('N') + '.ps1')
			$Private:Content = "Function Test-FixProbeBom { `$x = 'C:\ProgramData\MyApp'; return `$x }`n"
			[System.IO.File]::WriteAllText($Private:ProbeBom, $Private:Content, (New-Object System.Text.UTF8Encoding($true)))
			[System.IO.File]::WriteAllText($Private:ProbeNoBom, $Private:Content, (New-Object System.Text.UTF8Encoding($false)))
			try
			{
				$null = PSHG-FindHardcodedWindowsPath -Path $Private:ProbeBom -Fix 6>$null
				$null = PSHG-FindHardcodedWindowsPath -Path $Private:ProbeNoBom -Fix 6>$null

				$Private:BytesBom   = [System.IO.File]::ReadAllBytes($Private:ProbeBom)
				$Private:BytesNoBom = [System.IO.File]::ReadAllBytes($Private:ProbeNoBom)
				($Private:BytesBom[0] -eq 0xEF -and $Private:BytesBom[1] -eq 0xBB -and $Private:BytesBom[2] -eq 0xBF) | Should -Be $true
				($Private:BytesNoBom[0] -eq 0xEF -and $Private:BytesNoBom[1] -eq 0xBB) | Should -Be $false
			}
			finally
			{
				Remove-Item -LiteralPath $Private:ProbeBom, $Private:ProbeNoBom -Force -ErrorAction SilentlyContinue
			}
		}
	}
}

Describe 'PSHG-TestFileEncoding' {
	It 'reports the deliberately-unBOM''d example as non-compliant' {
		$null = PSHG-TestFileEncoding -Path (Join-Path $Script:BadDir 'MisencodedFile.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 1
	}
	It 'reports a Good example as compliant' {
		$null = PSHG-TestFileEncoding -Path (Join-Path $Script:GoodDir 'CorrectlyEncodedFile.ps1') 6>$null
		$Global:LASTEXITCODE | Should -Be 0
	}
}

Describe 'PSHG-TestScriptErrorHandling / PSHG-InvokeSilentFailureSweep' {
	It 'PSHG-TestScriptErrorHandling flags the empty-catch Bad example (AP7)' {
		$Private:Findings = (Join-Path $Script:BadDir 'SilentEmptyCatch.ps1') | PSHG-TestScriptErrorHandling -Quiet 6>$null
		$Private:Findings | Where-Object { $_.Rule -eq 'AP7' } | Should -Not -BeNullOrEmpty
	}
	It 'PSHG-InvokeSilentFailureSweep does not leak its own status code onto the object stream (regression test)' {
		# Known behaviour: converting "exit N" to "return N"
		# inside a function leaks the integer onto the SAME stream as any real pipeline
		# output the function already produced (Write-Output'd finding objects, here) -
		# fixed by using $Global:LASTEXITCODE instead. Every returned object must be a real
		# finding, never a bare Int32 status value.
		$Private:Results = PSHG-InvokeSilentFailureSweep -Path $Script:BadDir 6>$null
		foreach ($Private:R in $Private:Results) { $Private:R | Should -Not -BeOfType [Int32] }
	}
}

Describe 'PSHG-TestRepoLint' {
	It 'runs clean against a freshly generated empty baseline for a well-behaved example' {
		# Scoped to CorrectBareKeywordUsage.ps1 specifically (Get-StatusLabel, a read-only verb) -
		# most of the OTHER Good\ examples use state-changing verbs (New-/Remove-/Stop-) chosen for
		# their OWN narrative clarity (an empty-catch or closure example reads better as
		# "Remove-TempFile" than as a made-up read-only verb), which legitimately trips
		# PSUseShouldProcessForStateChangingFunctions - a genuine, unrelated finding, not a bug in
		# this checker. This test proves the LINT MECHANISM works, not that every example file is
		# clean on every rule simultaneously.
		$Private:TempBaseline = Join-Path $env:TEMP ('pshg-baseline-test-' + [guid]::NewGuid().ToString('N') + '.psd1')
		"@{ Accepted = @() }" | Set-Content -LiteralPath $Private:TempBaseline -Encoding UTF8
		try
		{
			$null = PSHG-TestRepoLint -Path (Join-Path $Script:GoodDir 'CorrectBareKeywordUsage.ps1') -BaselinePath $Private:TempBaseline 6>$null
			# DELIBERATE CANARY: this is the one PSScriptAnalyzer-dependent test with no -Skip:(-not $HasPssa). Without the analyzer
			# PSHG-TestRepoLint exits 2 and this test FAILS on purpose while the other analyzer-dependent tests skip, so a machine
			# or session that cannot see PSScriptAnalyzer is noticed instead of passing quietly with skipped tests.
			$Global:LASTEXITCODE | Should -Be 0 -Because 'exit code 2 here means PSScriptAnalyzer was not found by this session (check Get-Module -ListAvailable PSScriptAnalyzer and PSModulePath); the PSHG-FormatPS1File and PSHG-TestRepoLint baseline tests are SKIPPED in that case'
		}
		finally { Remove-Item -LiteralPath $Private:TempBaseline -Force -ErrorAction SilentlyContinue }
	}
}

Describe 'PSHG-FormatPS1File' {
	# Needs PSScriptAnalyzer (Invoke-Formatter); without it the function exits 2 and these cannot run.
	$HasPssa = [Boolean](Get-Module -ListAvailable -Name PSScriptAnalyzer)
	BeforeAll {
		$Script:FmtDir = Join-Path $TestDrive 'fmt'
		$null = New-Item -ItemType Directory -Path $Script:FmtDir -Force
		# Two-space indent: the formatter rewrites it to a tab, so a changed file proves a real write happened.
		$Script:FmtSource = "function Get-Thing {`r`n  1`r`n}`r`n"
	}

	It 'REFUSES a file with invalid UTF-8 bytes and leaves it byte-for-byte unchanged' -Skip:(-not $HasPssa) {
		$Private:File = Join-Path $Script:FmtDir 'ansi.ps1'
		# "Write-Host 'caf" + 0xE9 (Windows-1252 e-acute, not valid UTF-8 on its own) + "'"
		$Private:Bytes = [Byte[]](0x57, 0x72, 0x69, 0x74, 0x65, 0x2D, 0x48, 0x6F, 0x73, 0x74, 0x20, 0x27, 0x63, 0x61, 0x66, 0xE9, 0x27)
		[System.IO.File]::WriteAllBytes($Private:File, $Private:Bytes)
		$Private:Out = PSHG-FormatPS1File -Path $Private:File *>&1 | Out-String
		$Global:LASTEXITCODE | Should -Be 1
		$Private:Out | Should -Match 'REFUSED'
		([System.IO.File]::ReadAllBytes($Private:File) -join ',') | Should -Be ($Private:Bytes -join ',')
	}

	It 'keeps the BOM on a valid file that has one, and really reformats it' -Skip:(-not $HasPssa) {
		$Private:File = Join-Path $Script:FmtDir 'with-bom.ps1'
		[System.IO.File]::WriteAllText($Private:File, $Script:FmtSource, (New-Object System.Text.UTF8Encoding($true)))
		$null = PSHG-FormatPS1File -Path $Private:File *>&1
		$Global:LASTEXITCODE | Should -Be 0
		$Private:After = [System.IO.File]::ReadAllBytes($Private:File)
		($Private:After[0], $Private:After[1], $Private:After[2]) -join ',' | Should -Be '239,187,191'
		[System.IO.File]::ReadAllText($Private:File) | Should -Match "`t1"
	}

	It 'does not add a BOM to a valid file that has none, and really reformats it' -Skip:(-not $HasPssa) {
		$Private:File = Join-Path $Script:FmtDir 'no-bom.ps1'
		[System.IO.File]::WriteAllText($Private:File, $Script:FmtSource, (New-Object System.Text.UTF8Encoding($false)))
		$null = PSHG-FormatPS1File -Path $Private:File *>&1
		$Global:LASTEXITCODE | Should -Be 0
		$Private:After = [System.IO.File]::ReadAllBytes($Private:File)
		$Private:After[0] | Should -Be ([Byte][Char]'f')
		[System.IO.File]::ReadAllText($Private:File) | Should -Match "`t1"
	}
}

Describe 'PSHG-TestRepoLint baseline handling' {
	# Needs PSScriptAnalyzer: without it the function exits 2 before reaching any of this logic.
	$HasPssa = [Boolean](Get-Module -ListAvailable -Name PSScriptAnalyzer)
	BeforeAll {
		$Script:RuleName = 'PSUseShouldProcessForStateChangingFunctions'
		# Builds <TestDrive>\<name>\App\a.ps1 and \AppLegacy\b.ps1, each defining one state-changing function,
		# and returns the tree root.
		function Initialize-LintTree
		{
			Param ([String]$Name)
			$Private:Root = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath $Name
			foreach ($Private:Sub in 'App', 'AppLegacy') { $null = New-Item -ItemType Directory -Path (Join-Path $Private:Root $Private:Sub) -Force }
			Set-Content -LiteralPath (Join-Path $Private:Root 'App\a.ps1') -Value 'function Set-AThing { }'
			Set-Content -LiteralPath (Join-Path $Private:Root 'AppLegacy\b.ps1') -Value 'function Set-BThing { }'
			return $Private:Root
		}
		function Initialize-LintBaseline
		{
			Param ([String]$File, [String[]]$Key)
			$Private:Items = ($Key | ForEach-Object { "'{0}'" -f $_ }) -join ', '
			Set-Content -LiteralPath $File -Value ('@{{ Accepted = @({0}) }}' -f $Private:Items)
		}
	}

	It 'scoped -UpdateBaseline merges on a path boundary: a sibling folder sharing a name prefix is kept' -Skip:(-not $HasPssa) {
		$Private:Root = Initialize-LintTree -Name 'merge'
		$Private:Baseline = Join-Path $Private:Root 'baseline.psd1'
		$Private:KeyA      = '{0}|App\a.ps1|Set-AThing' -f $Script:RuleName
		$Private:KeyLegacy = '{0}|AppLegacy\b.ps1|Set-BThing' -f $Script:RuleName
		$Private:KeyGone   = '{0}|App\gone.ps1|Set-Gone' -f $Script:RuleName
		Initialize-LintBaseline -File $Private:Baseline -Key $Private:KeyA, $Private:KeyLegacy, $Private:KeyGone

		$null = PSHG-TestRepoLint -Path (Join-Path $Private:Root 'App') -BaselinePath $Private:Baseline -RepoRoot $Private:Root -Rule $Script:RuleName -UpdateBaseline 6>$null
		$Global:LASTEXITCODE | Should -Be 0

		$Private:Accepted = @((Import-PowerShellDataFile -Path $Private:Baseline).Accepted)
		$Private:Accepted | Should -Contain $Private:KeyA
		$Private:Accepted | Should -Contain $Private:KeyLegacy
		# Inside the scanned folder and no longer firing: pruned, which proves the scoped part of the merge still works.
		$Private:Accepted | Should -Not -Contain $Private:KeyGone
	}

	It 'a trailing slash on -RepoRoot behaves exactly like none' -Skip:(-not $HasPssa) {
		$Private:Root = Initialize-LintTree -Name 'slash'
		$Private:Baseline = Join-Path $Private:Root 'baseline.psd1'
		Initialize-LintBaseline -File $Private:Baseline -Key ('{0}|App\a.ps1|Set-AThing' -f $Script:RuleName)
		$Private:Scope = Join-Path $Private:Root 'App'

		$null = PSHG-TestRepoLint -Path $Private:Scope -BaselinePath $Private:Baseline -RepoRoot $Private:Root -Rule $Script:RuleName 6>$null
		$Private:WithoutSlash = $Global:LASTEXITCODE
		$null = PSHG-TestRepoLint -Path $Private:Scope -BaselinePath $Private:Baseline -RepoRoot ($Private:Root + '\') -Rule $Script:RuleName 6>$null
		$Private:WithSlash = $Global:LASTEXITCODE

		# 0 = the accepted entry matched (relative path computed correctly); 1 would mean a NEW finding.
		$Private:WithoutSlash | Should -Be 0
		$Private:WithSlash | Should -Be 0
	}

	# Import-PowerShellDataFile reports an unparsable file as a NON-terminating error unless -ErrorAction Stop
	# is given; without it the catch never fires and the baseline is silently treated as empty (exit 1, not 2).
	It 'an unparsable baseline gives exit 2 and a message naming the file' -Skip:(-not $HasPssa) {
		$Private:Root = Initialize-LintTree -Name 'badbaseline'
		$Private:Baseline = Join-Path $Private:Root 'broken.psd1'
		Set-Content -LiteralPath $Private:Baseline -Value '@{ Accepted = @('
		$Private:Out = PSHG-TestRepoLint -Path (Join-Path $Private:Root 'App') -BaselinePath $Private:Baseline -RepoRoot $Private:Root -Rule $Script:RuleName *>&1 | Out-String
		$Global:LASTEXITCODE | Should -Be 2
		# The message distinguishes this from the other exit-2 cause (PSScriptAnalyzer missing).
		$Private:Out | Should -Match 'Cannot read baseline'
		$Private:Out | Should -Match 'broken\.psd1'
	}
}

Describe 'PSHG-TestModuleVersionSelfReference' {
	BeforeAll {
		# Builds <TestDrive>\<name>\Widget\1.0 (old) and \1.1 (current); writes $Line into 1.1\Open.ps1; returns the exit code.
		function Test-SelfRefLine
		{
			Param ([String]$Name, [String]$Line)
			$Private:Root = Join-Path (Resolve-Path -Path $TestDrive).ProviderPath $Name
			$null = New-Item -ItemType Directory -Path (Join-Path $Private:Root 'Widget\1.0') -Force
			$null = New-Item -ItemType Directory -Path (Join-Path $Private:Root 'Widget\1.1') -Force
			Set-Content -LiteralPath (Join-Path $Private:Root 'Widget\1.1\Open.ps1') -Value $Line
			$null = PSHG-TestModuleVersionSelfReference -RootPath $Private:Root -Module 'Widget' -Version '1.1' 6>$null
			return $Global:LASTEXITCODE
		}
	}

	It 'flags a -ModuleVersion pin on the older version of the same module' {
		Test-SelfRefLine -Name 'modver' -Line "Open-Thing -ModuleName 'Widget' -ModuleVersion '1.0'" | Should -Be 1
	}
	It 'flags a -RequiredVersion pin on the older version of the same module' {
		Test-SelfRefLine -Name 'reqver' -Line "Import-Module -Name Widget -RequiredVersion 1.0" | Should -Be 1
	}
	It 'accepts a -ModuleVersion pin on the current version' {
		Test-SelfRefLine -Name 'curver' -Line "Open-Thing -ModuleName 'Widget' -ModuleVersion '1.1'" | Should -Be 0
	}
	It 'does not flag an old-version pin when the module name is not on the same line' {
		Test-SelfRefLine -Name 'othermod' -Line "Open-Thing -ModuleName 'Other' -ModuleVersion '1.0'" | Should -Be 0
	}
}

Describe 'PSHG-InvokeSilentFailureSweep error handling' {
	It 'exits 2 (not a clean pass) when the scan job errors and nothing is found' {
		# Remove-Job empties the job's live Error collection, so the function must snapshot it BEFORE removing
		# the job; otherwise an errored scan is counted as zero errors and exits 0.
		$Private:Dir = Join-Path $TestDrive 'sweep-err'
		$null = New-Item -ItemType Directory -Path $Private:Dir -Force
		Set-Content -LiteralPath (Join-Path $Private:Dir 'clean.ps1') -Value 'function Get-Thing { 1 }'
		# A baseline that cannot be parsed makes the checker Write-Error inside the job.
		$Private:Bad = Join-Path $Private:Dir 'broken.psd1'
		Set-Content -LiteralPath $Private:Bad -Value 'not a hashtable'
		$null = PSHG-InvokeSilentFailureSweep -Path $Private:Dir -Baseline $Private:Bad *>&1
		$Global:LASTEXITCODE | Should -Be 2
	}
}

Describe 'Demo\Invoke-Demo.ps1' {
	It 'never writes to the shipped Examples\ folder (hash-verified, not just intended)' {
		$Private:ExamplesDir = Join-Path $Script:ModuleRoot 'Examples'
		$Private:Before = Get-ChildItem -Path $Private:ExamplesDir -Recurse -File | ForEach-Object {
			[PSCustomObject]@{ Path = $_.FullName; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
		}

		& (Join-Path $Script:ModuleRoot 'Demo\Invoke-Demo.ps1') *> $null

		$Private:After = Get-ChildItem -Path $Private:ExamplesDir -Recurse -File | ForEach-Object {
			[PSCustomObject]@{ Path = $_.FullName; Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
		}

		$Private:After.Count | Should -Be $Private:Before.Count
		foreach ($Private:B in $Private:Before)
		{
			$Private:A = $Private:After | Where-Object { $_.Path -eq $Private:B.Path }
			$Private:A | Should -Not -BeNullOrEmpty
			$Private:A.Hash | Should -Be $Private:B.Hash
		}

		Remove-Item -LiteralPath (Join-Path $Script:ModuleRoot 'Demo\_run') -Recurse -Force -ErrorAction SilentlyContinue
	}
}
