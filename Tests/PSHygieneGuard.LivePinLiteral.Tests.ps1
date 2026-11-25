#requires -Modules @{ ModuleName = 'Pester'; RequiredVersion = '5.7.1' }
<#
	.SYNOPSIS
	Pester suite for PSHG-TestLivePinLiteral. Every case builds a small Modules tree under $TestDrive
	(<Module>\LiveVersion.psd1 plus version folders) and scans scripts inside it.
#>

BeforeAll {
	Remove-Module -Name PSHygieneGuard -Force -ErrorAction SilentlyContinue
	Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\PSHygieneGuard.psd1') -Force

	# Builds <base>\Modules with NamedPipe 0.17 + 0.18 (live 0.18) and VaultTools 0.6 + 0.7 (live 0.7); returns the base.
	$Script:NewTree = {
		$Base = Join-Path $TestDrive ('t' + [guid]::NewGuid().ToString('N'))
		ForEach ($Pair in @(@('NamedPipe', '0.17'), @('NamedPipe', '0.18'), @('VaultTools', '0.6'), @('VaultTools', '0.7')))
		{
			$D = Join-Path $Base ('Modules\{0}\{1}' -f $Pair[0], $Pair[1])
			$null = New-Item -ItemType Directory -Path $D -Force
			Set-Content -LiteralPath (Join-Path $D ($Pair[0] + '.psd1')) -Value "@{ ModuleVersion = '$($Pair[1])' }"
		}
		Set-Content -LiteralPath (Join-Path $Base 'Modules\NamedPipe\LiveVersion.psd1') -Value "@{ Module = 'NamedPipe'; LiveVersion = '0.18' }"
		Set-Content -LiteralPath (Join-Path $Base 'Modules\VaultTools\LiveVersion.psd1') -Value "@{ Module = 'VaultTools'; LiveVersion = '0.7' }"
		$null = New-Item -ItemType Directory -Path (Join-Path $Base 'Tools') -Force
		$Base
	}

	# Writes Body to <base>\<Rel> and returns the sites (objects) from a scan of the whole base, plus the exit code.
	$Script:Scan = {
		Param ([String]$Base, [String]$Rel, [String]$Body, [Hashtable]$Extra = @{})
		If ($Rel) { $F = Join-Path $Base $Rel; $null = New-Item -ItemType Directory -Path (Split-Path $F -Parent) -Force; Set-Content -LiteralPath $F -Value $Body }
		$Sites = @(PSHG-TestLivePinLiteral -Path $Base -ModulesRoot (Join-Path $Base 'Modules') -PassThru -Quiet @Extra 6>$null)
		[PSCustomObject]@{ Sites = $Sites; Exit = $Global:LASTEXITCODE }
	}
}

Describe 'PSHG-TestLivePinLiteral' {
	It 'is exported' {
		(Get-Command -Module PSHygieneGuard -Name PSHG-TestLivePinLiteral -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
	}

	Context 'sites that must be reported' {
		It 'Import-Module on a live module with a literal -RequiredVersion (exit 1, kind Import, live version shown)' {
			$B = & $Script:NewTree
			$R = & $Script:Scan $B 'Tools\a.ps1' 'Import-Module NamedPipe -RequiredVersion 0.17 -ErrorAction Stop'
			$R.Exit | Should -Be 1
			$R.Sites.Count | Should -Be 1
			$R.Sites[0].Kind | Should -Be 'Import'
			$R.Sites[0].Module | Should -Be 'NamedPipe'
			$R.Sites[0].Version | Should -Be '0.17'
			$R.Sites[0].Live | Should -Be '0.18'
			$R.Sites[0].File | Should -Be 'Tools\a.ps1'
		}
		It 'the -Name form, quoted names, a parameter between name and version, and -Param:Value' {
			$B = & $Script:NewTree
			$Body = @'
Import-Module -Name 'NamedPipe' -Force -RequiredVersion '0.18'
Import-Module "VaultTools" -Global -RequiredVersion:0.7
Import-Module -ErrorAction Stop NamedPipe -RequiredVersion 0.18
'@
			$R = & $Script:Scan $B 'Tools\b.ps1' $Body
			$R.Sites.Count | Should -Be 3
			($R.Sites.Module | Sort-Object) -join ',' | Should -Be 'NamedPipe,NamedPipe,VaultTools'
		}
		It 'Open-MyElevatedSession -ModuleName X -ModuleVersion <literal> (kind Elevated)' {
			$B = & $Script:NewTree
			$R = & $Script:Scan $B 'Tools\c.ps1' "Open-MyElevatedSession -ModuleName 'VaultTools' -ModuleVersion '0.7' -Verbose"
			$R.Exit | Should -Be 1
			$R.Sites[0].Kind | Should -Be 'Elevated'
		}
		It 'an Import-Module command inside a string built for a child process (kind InString), with the right line' {
			$B = & $Script:NewTree
			$Body = "`$x = 1`n`$cmd = `"Import-Module NamedPipe -RequiredVersion 0.18; Do-It`"`n"
			$R = & $Script:Scan $B 'Tools\d.ps1' $Body
			$R.Sites.Count | Should -Be 1
			$R.Sites[0].Kind | Should -Be 'InString'
			$R.Sites[0].Line | Should -Be 2
		}
	}

	Context 'test files' {
		It 'a string in a test file is a fixture, not a pin, unless -IncludeTests; a real command in a test file still counts' {
			$B = & $Script:NewTree
			$Body = "`$x = 'Import-Module NamedPipe -RequiredVersion 0.18'`nImport-Module VaultTools -RequiredVersion 0.7`n"
			$R = & $Script:Scan $B 'Tools\Tests\a.Tests.ps1' $Body
			$R.Sites.Count | Should -Be 1
			$R.Sites[0].Kind | Should -Be 'Import'
			$R2 = & $Script:Scan $B '' '' @{ IncludeTests = $true }
			$R2.Sites.Count | Should -Be 2
		}
	}

	Context 'what is not a site' {
		It 'a version held in a variable, a comment, an unknown module, an import without a version' {
			$B = & $Script:NewTree
			$Body = @'
$v = '0.18'
Import-Module NamedPipe -RequiredVersion $v
# Import-Module NamedPipe -RequiredVersion 0.18
Import-Module Pester -RequiredVersion 5.7.1
Import-Module NamedPipe
Import-Module NamedPipe -MinimumVersion 0.17
Open-MyElevatedSession -ModuleName VaultTools -ModuleVersion $v
'@
			$R = & $Script:Scan $B 'Tools\e.ps1' $Body
			$R.Exit | Should -Be 0
			$R.Sites.Count | Should -Be 0
		}
		It 'a module''s own reference to itself is skipped by default and reported with -IncludeSelf (Self = true)' {
			$B = & $Script:NewTree
			$R = & $Script:Scan $B 'Modules\NamedPipe\0.18\Tests\x.Tests.ps1' 'Import-Module NamedPipe -RequiredVersion 0.18'
			$R.Sites.Count | Should -Be 0
			$R2 = & $Script:Scan $B '' '' @{ IncludeSelf = $true }
			$R2.Sites.Count | Should -Be 1
			$R2.Sites[0].Self | Should -BeTrue
		}
		It 'code in a FROZEN version folder is skipped by default and reported with -IncludeFrozen (Frozen = true)' {
			$B = & $Script:NewTree
			$R = & $Script:Scan $B 'Modules\VaultTools\0.6\Functions\old.ps1' 'Import-Module NamedPipe -RequiredVersion 0.17'
			$R.Sites.Count | Should -Be 0
			$R.Exit | Should -Be 0
			$R2 = & $Script:Scan $B '' '' @{ IncludeFrozen = $true }
			$R2.Sites.Count | Should -Be 1
			$R2.Sites[0].Frozen | Should -BeTrue
		}
		It 'code in the NEWEST version folder of another module is a site' {
			$B = & $Script:NewTree
			$R = & $Script:Scan $B 'Modules\VaultTools\0.7\Functions\new.ps1' 'Import-Module NamedPipe -RequiredVersion 0.18'
			$R.Sites.Count | Should -Be 1
			$R.Sites[0].Frozen | Should -BeFalse
		}
		It 'Original, _RetiredModules and .archive folders are never scanned' {
			$B = & $Script:NewTree
			$null = & $Script:Scan $B '_RetiredModules\NamedPipe\0.8\x.ps1' 'Import-Module NamedPipe -RequiredVersion 0.8'
			$null = & $Script:Scan $B '.archive\y.ps1' 'Import-Module NamedPipe -RequiredVersion 0.8'
			$R = & $Script:Scan $B 'Tools\Original\z.ps1' 'Import-Module NamedPipe -RequiredVersion 0.8'
			$R.Sites.Count | Should -Be 0
		}
	}

	Context 'baseline gate' {
		It 'accepted sites pass (exit 0), a NEW site fails (exit 1), and -UpdateBaseline writes a BOM file keyed without line numbers' {
			$B = & $Script:NewTree
			$null = & $Script:Scan $B 'Tools\f.ps1' "Import-Module NamedPipe -RequiredVersion 0.18`r`nImport-Module VaultTools -RequiredVersion 0.7"
			$Base = Join-Path $B 'base.psd1'
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath $Base -UpdateBaseline -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 0
			$Bytes = [System.IO.File]::ReadAllBytes($Base)
			($Bytes[0..2] -join ',') | Should -Be '239,187,191'
			$Entries = (Import-PowerShellDataFile -LiteralPath $Base).Entries
			$Entries.Count | Should -Be 2
			$Entries | Should -Contain 'LivePinLiteral|Tools\f.ps1|NamedPipe|Import'
			($Entries -join ' ') | Should -Not -Match ':\d+'
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath $Base -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 0
			# a line moved: still accepted; a new file: new
			Set-Content -LiteralPath (Join-Path $B 'Tools\f.ps1') -Value "# moved down`r`nImport-Module NamedPipe -RequiredVersion 0.18`r`nImport-Module VaultTools -RequiredVersion 0.7"
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath $Base -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 0
			Set-Content -LiteralPath (Join-Path $B 'Tools\g.ps1') -Value 'Import-Module NamedPipe -RequiredVersion 0.18'
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath $Base -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 1
		}
		It 'a file name containing an apostrophe or a typographic quote still gives a readable baseline' {
			$B = & $Script:NewTree
			$Name = 'Ray' + [string][char]0x2019 + 's it' + [string][char]39 + 's.ps1'
			$null = & $Script:Scan $B ('Tools\' + $Name) 'Import-Module NamedPipe -RequiredVersion 0.18'
			$Base = Join-Path $B 'base.psd1'
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath $Base -UpdateBaseline -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 0
			(Import-PowerShellDataFile -LiteralPath $Base).Entries | Should -Contain ('LivePinLiteral|Tools\{0}|NamedPipe|Import' -f $Name)
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath $Base -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 0
		}
		It '-All also lists accepted sites; -UpdateBaseline without -BaselinePath is refused (exit 2)' {
			$B = & $Script:NewTree
			$null = & $Script:Scan $B 'Tools\f.ps1' 'Import-Module NamedPipe -RequiredVersion 0.18'
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -UpdateBaseline -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 2
			$Base = Join-Path $B 'base.psd1'
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath $Base -UpdateBaseline -Quiet 6>$null
			$S = @(PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath $Base -All -PassThru -Quiet 6>$null)
			$S.Count | Should -Be 1
			$S[0].Accepted | Should -BeTrue
		}
		It 'an unreadable baseline is exit 2, never a pass' {
			$B = & $Script:NewTree
			Set-Content -LiteralPath (Join-Path $B 'bad.psd1') -Value '@{ Entries = ( '
			$null = PSHG-TestLivePinLiteral -Path $B -ModulesRoot (Join-Path $B 'Modules') -BaselinePath (Join-Path $B 'bad.psd1') -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 2
		}
	}

	Context 'runs that cannot be trusted' {
		It 'no modules root with a LiveVersion.psd1 anywhere above the path is exit 2' {
			$D = Join-Path $TestDrive ('n' + [guid]::NewGuid().ToString('N'))
			$null = New-Item -ItemType Directory -Path $D -Force
			Set-Content -LiteralPath (Join-Path $D 'a.ps1') -Value 'Import-Module NamedPipe -RequiredVersion 0.18'
			$null = PSHG-TestLivePinLiteral -Path $D -Quiet 6>$null
			$Global:LASTEXITCODE | Should -Be 2
		}
		It 'a file that does not parse is listed as NOT CHECKED and the run is exit 2 when nothing else was found' {
			$B = & $Script:NewTree
			$R = & $Script:Scan $B 'Tools\broken.ps1' 'Write-Host ('
			$R.Exit | Should -Be 2
			# a finding in a partly parsed file is still reported (exit 1), the file is still listed as not checked
			$R = & $Script:Scan $B 'Tools\broken.ps1' 'Import-Module NamedPipe -RequiredVersion 0.18 ('
			$R.Exit | Should -Be 1
		}
		It 'the modules root is found by walking up from the scanned path' {
			$B = & $Script:NewTree
			Set-Content -LiteralPath (Join-Path $B 'Tools\h.ps1') -Value 'Import-Module NamedPipe -RequiredVersion 0.18'
			$S = @(PSHG-TestLivePinLiteral -Path (Join-Path $B 'Tools') -PassThru -Quiet 6>$null)
			$S.Count | Should -Be 1
			$S[0].File | Should -Be 'Tools\h.ps1'
		}
	}
}
