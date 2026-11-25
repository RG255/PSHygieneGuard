Function PSHG-TestLivePinLiteral
{
	<#
		.SYNOPSIS
		Finds a literal version pin on a module that publishes its live version in a LiveVersion.psd1 - the
		pin goes stale the day that module is branched.

		.DESCRIPTION
		Some codebases keep one tiny data file per module, <ModulesRoot>\<Module>\LiveVersion.psd1, saying which
		version folder of that module is live (@{ Module = 'X'; LiveVersion = '1.2' }). A caller that asks the file
		(Get-LiveModuleVersion / Import-LiveModule) follows a branch for free; a caller that writes the version out
		keeps loading the old one until somebody remembers it. This check lists the second kind.

		Reported, by AST (comments, help text and variables are never matched):

		    Import-Module X -RequiredVersion 0.18                      # Kind = Import
		    Open-MyElevatedSession -ModuleName X -ModuleVersion 0.7    # Kind = Elevated
		    "Import-Module X -RequiredVersion 0.7"  (inside a string)  # Kind = InString: a script text built for a child process

		but only when X has a LiveVersion.psd1 under the modules root. A version held in a variable is not a literal
		and is not reported.

		A site is skipped by default when
		  - it sits in a FROZEN version folder (a version folder that is not the newest of its module under the
		    modules root - older versions are backstops that keep their literals); -IncludeFrozen reports them too, with Frozen = true;
		  - it is a SELF reference (a file of module X importing X itself - the module's own tests and helpers); those are
		    derived from the running module, not read from the file; -IncludeSelf reports them too, with Self = true.

		Baseline-gated like the other PSHG checks: with -BaselinePath, sites already in the baseline are accepted debt and
		do not fail the run; a NEW site does. Entries are keyed 'LivePinLiteral|<path relative to RepoRoot>|<Module>|<Kind>',
		never a line number, so editing above a site does not make it new. -UpdateBaseline records every current site.

		Uses the PowerShell language parser only - no PSScriptAnalyzer dependency.

		.PARAMETER Path
		File or directory to scan (recurses; .ps1 and .psm1). Accepts pipeline input. Defaults to the current directory.

		.PARAMETER ModulesRoot
		The folder that holds <Module>\LiveVersion.psd1. Default: found by walking up from the first path (the folder
		itself, or a Modules folder beside it, that contains such a file).

		.PARAMETER RepoRoot
		Base for the relative paths in the report and the baseline. Default: the parent of ModulesRoot.

		.PARAMETER BaselinePath
		A .psd1 of accepted sites: @{ Entries = @( 'LivePinLiteral|...' ) }. Without it every site is new.

		.PARAMETER UpdateBaseline
		Write every current site to -BaselinePath as accepted. Requires -BaselinePath.

		.PARAMETER IncludeFrozen
		Also report sites in frozen version folders.

		.PARAMETER IncludeSelf
		Also report a module's own references to itself.

		.PARAMETER IncludeTests
		Also look inside strings in test files (a Tests folder or *.Tests.ps1); by default only the commands there are checked, because a string in
		a test is usually a fixture, not a pin.

		.PARAMETER All
		Also list accepted (baselined) sites.

		.PARAMETER Quiet
		Print only the sites and the verdict line.

		.PARAMETER Csv
		Write every reported site to this CSV file.

		.PARAMETER PassThru
		Also emit each reported site as an object (File, Line, Module, Version, Live, Kind, Frozen, Self, Accepted, Text).

		.EXAMPLE
		PSHG-TestLivePinLiteral -Path 'C:\Repo\Modules\VHDTools\0.13' -BaselinePath 'C:\Repo\Tools\LivePin-Baseline.psd1'

		.NOTES
		Returns 0 = no new site, 1 = at least one new site, 2 = could not run reliably (no modules root with LiveVersion.psd1 files,
		an unreadable baseline, or a file that could not be read or parsed and nothing else found). Follow the call with
		`exit $LASTEXITCODE` for a process exit code. Folders named Original, Originals, _RetiredModules, .archive, _PlanningDocs
		and .git are skipped. Not seen: a pin whose module name or version is built at run time, and ModuleToLoad-style hashtables.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console report is the entire purpose of this tool (matches module convention)')]
	[CmdletBinding()]
	Param (
		[Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[Alias('FullName')]
		[String[]]$Path = @($PWD.ProviderPath),

		[String]$ModulesRoot,
		[String]$RepoRoot,
		[String]$BaselinePath,
		[Switch]$UpdateBaseline,
		[Switch]$IncludeFrozen,
		[Switch]$IncludeSelf,
		[Switch]$IncludeTests,
		[Switch]$All,
		[Switch]$Quiet,
		[String]$Csv,
		[Switch]$PassThru
	)

	Begin
	{
		$Script:TlpPaths = [System.Collections.Generic.List[String]]::new()
	}

	Process
	{
		ForEach ($Private:P in $Path) { $Script:TlpPaths.Add($Private:P) }
	}

	End
	{
		Try
		{
			$Private:Skipped = [System.Collections.Generic.List[String]]::new()
			$Private:Exclude = '\\Original(s)?\\|\\_RetiredModules\\|\\\.archive\\|\\_PlanningDocs\\|\\\.git\\'
			$Private:VerPattern = '^\d+(\.\d+)+$'

			If ($UpdateBaseline -and -not $BaselinePath)
			{ Write-Host 'FAIL - -UpdateBaseline requires -BaselinePath.' -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }

			# Modules root: given, else the nearest folder above the first path that holds <Module>\LiveVersion.psd1.
			If (-not $ModulesRoot)
			{
				$Private:Start = $Script:TlpPaths[0]
				If (Test-Path -LiteralPath $Private:Start -PathType Leaf) { $Private:Start = [System.IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $Private:Start).ProviderPath) }
				If (Test-Path -LiteralPath $Private:Start) { $Private:Dir = (Resolve-Path -LiteralPath $Private:Start).ProviderPath } Else { $Private:Dir = $null }
				While ($Private:Dir -and -not $ModulesRoot)
				{
					ForEach ($Private:Cand in @($Private:Dir, (Join-Path -Path $Private:Dir -ChildPath 'Modules')))
					{
						If (-not (Test-Path -LiteralPath $Private:Cand -PathType Container)) { Continue }
						If (@(Get-ChildItem -LiteralPath $Private:Cand -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path -Path $_.FullName -ChildPath 'LiveVersion.psd1') -PathType Leaf }).Count -gt 0)
						{ $ModulesRoot = $Private:Cand; Break }
					}
					$Private:Dir = [System.IO.Path]::GetDirectoryName($Private:Dir)
				}
			}
			If (-not $ModulesRoot -or -not (Test-Path -LiteralPath $ModulesRoot -PathType Container))
			{ Write-Host 'NOT CLEAN - no modules root with <Module>\LiveVersion.psd1 files was found; pass -ModulesRoot.' -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
			$ModulesRoot = (Resolve-Path -LiteralPath $ModulesRoot).ProviderPath.TrimEnd('\')
			If (-not $RepoRoot) { $RepoRoot = [System.IO.Path]::GetDirectoryName($ModulesRoot) }
			$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')

			# Modules that publish a live version, with the version each file names.
			$Private:Live = @{}
			ForEach ($Private:D in (Get-ChildItem -LiteralPath $ModulesRoot -Directory -ErrorAction SilentlyContinue))
			{
				$Private:F = Join-Path -Path $Private:D.FullName -ChildPath 'LiveVersion.psd1'
				If (-not (Test-Path -LiteralPath $Private:F -PathType Leaf)) { Continue }
				$Private:LiveVer = '?'
				Try { $Private:Data = Import-PowerShellDataFile -LiteralPath $Private:F -ErrorAction Stop; If ($Private:Data.LiveVersion -is [String]) { $Private:LiveVer = $Private:Data.LiveVersion } }
				Catch { $Private:Skipped.Add(('{0} (cannot read: {1})' -f $Private:F, $_.Exception.Message)) }
				$Private:Live[$Private:D.Name.ToLowerInvariant()] = $Private:LiveVer
			}

			# Newest version folder per module, for the frozen test.
			$Private:Newest = @{}
			ForEach ($Private:D in (Get-ChildItem -LiteralPath $ModulesRoot -Directory -ErrorAction SilentlyContinue))
			{
				$Private:Vers = @(Get-ChildItem -LiteralPath $Private:D.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $Private:VerPattern } | Sort-Object { [Version]$_.Name } -Descending)
				If ($Private:Vers.Count -gt 0) { $Private:Newest[$Private:D.Name.ToLowerInvariant()] = $Private:Vers[0].Name }
			}

			# Baseline.
			$Private:Accepted = [System.Collections.Generic.HashSet[String]]::new([StringComparer]::OrdinalIgnoreCase)
			If ($BaselinePath -and -not $UpdateBaseline -and (Test-Path -LiteralPath $BaselinePath -PathType Leaf))
			{
				Try
				{
					$Private:B = Import-PowerShellDataFile -LiteralPath $BaselinePath -ErrorAction Stop
					ForEach ($Private:E in @($Private:B.Entries)) { If ($Private:E) { [void]$Private:Accepted.Add([String]$Private:E) } }
				}
				Catch { Write-Host ('NOT CLEAN - the baseline could not be read: {0}' -f $_.Exception.Message) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
			}

			$Private:Sites = [System.Collections.Generic.List[PSCustomObject]]::new()
			$Private:FileCount = 0
			$Private:Files = [System.Collections.Generic.List[String]]::new()
			ForEach ($Private:P in $Script:TlpPaths)
			{
				If (-not (Test-Path -LiteralPath $Private:P)) { $Private:Skipped.Add(('{0} (path not found)' -f $Private:P)); Continue }
				ForEach ($Private:Fn in @(Get-PSHGScanFile -Path ((Resolve-Path -LiteralPath $Private:P).ProviderPath) -ExcludePattern $Private:Exclude -Problem $Private:Skipped)) { If (-not $Private:Files.Contains($Private:Fn)) { $Private:Files.Add($Private:Fn) } }
			}

			ForEach ($Private:File in $Private:Files)
			{
				$Private:FileCount++
				$Private:Parsed = Read-PSHGAst -File $Private:File
				If (-not $Private:Parsed.Ok)
				{ $Private:Skipped.Add(('{0} ({1})' -f $Private:File, $Private:Parsed.Reason)); If (-not $Private:Parsed.Ast) { Continue } }

				# Which module and version folder the file belongs to (none for a script outside Modules\).
				$Private:Owner = $null; $Private:OwnerVer = $null
				If ($Private:File.StartsWith($ModulesRoot + '\', [StringComparison]::OrdinalIgnoreCase))
				{
					$Private:Parts = @($Private:File.Substring($ModulesRoot.Length + 1) -split '\\')
					If ($Private:Parts.Count -ge 2) { $Private:Owner = $Private:Parts[0] }
					If ($Private:Parts.Count -ge 3 -and $Private:Parts[1] -match $Private:VerPattern) { $Private:OwnerVer = $Private:Parts[1] }
				}
				$Private:Frozen = $false
				If ($Private:Owner -and $Private:OwnerVer -and $Private:Newest.ContainsKey($Private:Owner.ToLowerInvariant()) -and $Private:Newest[$Private:Owner.ToLowerInvariant()] -ne $Private:OwnerVer) { $Private:Frozen = $true }
				If ($Private:Frozen -and -not $IncludeFrozen) { Continue }

				$Private:Rel = If ($Private:File.StartsWith($RepoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { $Private:File.Substring($RepoRoot.Length + 1) } Else { $Private:File }

				$Private:Hits = [System.Collections.Generic.List[PSCustomObject]]::new()

				$Private:Cmds = $Private:Parsed.Ast.FindAll({ Param($N) $N -is [System.Management.Automation.Language.CommandAst] }, $true)
				ForEach ($Private:Cmd in $Private:Cmds)
				{
					$Private:Info = Get-PSHGLivePinCommandInfo -Command $Private:Cmd
					If ($Private:Info) { $Private:Hits.Add([PSCustomObject]@{ Module = $Private:Info.Module; Version = $Private:Info.Version; Kind = $Private:Info.Kind; Line = $Private:Cmd.Extent.StartLineNumber; Text = ($Private:Cmd.Extent.Text -split "`r?`n")[0].Trim() }) }
				}

				# A string in a test file is usually a fixture (a script body written to disk), not a pin: skipped unless -IncludeTests.
				$Private:IsTest = $Private:File -match '\\Tests\\|\.Tests\.ps1$'
				$Private:Strs = If ($Private:IsTest -and -not $IncludeTests) { @() } Else { $Private:Parsed.Ast.FindAll({ Param($N) $N -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $N -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true) }
				ForEach ($Private:S in $Private:Strs)
				{
					ForEach ($Private:M in [regex]::Matches([String]$Private:S.Value, '(?i)Import-Module\s+(?:-Name\s+)?[''"]?(?<m>[A-Za-z][\w.-]*)[''"]?[^\r\n;|]*?-RequiredVersion\s+[''"]?(?<v>\d+(?:\.\d+)+)'))
					{
						$Private:Before = ([String]$Private:S.Value).Substring(0, $Private:M.Index)
						$Private:Line = $Private:S.Extent.StartLineNumber + @([regex]::Matches($Private:Before, "`n")).Count
						$Private:Hits.Add([PSCustomObject]@{ Module = $Private:M.Groups['m'].Value; Version = $Private:M.Groups['v'].Value; Kind = 'InString'; Line = $Private:Line; Text = $Private:M.Value.Trim() })
					}
				}

				ForEach ($Private:H in $Private:Hits)
				{
					$Private:Key = $Private:H.Module.ToLowerInvariant()
					If (-not $Private:Live.ContainsKey($Private:Key)) { Continue }
					$Private:IsSelf = [bool]($Private:Owner -and $Private:Owner -ieq $Private:H.Module)
					If ($Private:IsSelf -and -not $IncludeSelf) { Continue }
					$Private:EntryKey = 'LivePinLiteral|{0}|{1}|{2}' -f $Private:Rel, $Private:H.Module, $Private:H.Kind
					$Private:Sites.Add([PSCustomObject]@{
							File = $Private:Rel; Line = $Private:H.Line; Module = $Private:H.Module; Version = $Private:H.Version
							Live = $Private:Live[$Private:Key]; Kind = $Private:H.Kind; Frozen = $Private:Frozen; Self = $Private:IsSelf
							Accepted = $Private:Accepted.Contains($Private:EntryKey); Key = $Private:EntryKey; Text = $Private:H.Text
						})
				}
			}

			$Private:Sorted = @($Private:Sites | Sort-Object File, Line)
			$Private:LiveNames = (@($Private:Live.Keys) | Sort-Object) -join ', '
			If (-not $Quiet) { Write-Host ('Scanned {0} file(s) for literal pins on modules with a LiveVersion.psd1 ({1})...' -f $Private:FileCount, $Private:LiveNames) -ForegroundColor Cyan }
			Write-PSHGSkipReport -Skipped $Private:Skipped

			If ($Csv -and $Private:Sorted.Count -gt 0)
			{
				$Private:Sorted | Select-Object File, Line, Module, Version, Live, Kind, Frozen, Self, Accepted | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
				Write-Host ('CSV: {0} row(s) -> {1}' -f $Private:Sorted.Count, $Csv) -ForegroundColor DarkGray
			}

			If ($UpdateBaseline)
			{
				$Private:Keys = @($Private:Sorted | ForEach-Object { $_.Key } | Sort-Object -Unique)
				# Every single-quote variant PowerShell accepts is doubled, so a path containing one cannot end the literal.
				$Private:QuoteClass = '[''{0}{1}{2}{3}]' -f [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B
				$Private:Lines = @('@{', "`tEntries = @(") + @($Private:Keys | ForEach-Object { "`t`t'" + [regex]::Replace($_, $Private:QuoteClass, '$0$0') + "'" }) + @("`t)", '}')
				$Private:Text = ($Private:Lines -join "`r`n") + "`r`n"
				$Private:Bytes = (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true).GetPreamble() + [System.Text.Encoding]::UTF8.GetBytes($Private:Text)
				Write-PSHGFileAtomic -Path $BaselinePath -Bytes $Private:Bytes
				Write-Host ('Baseline written: {0} entr(ies) -> {1}' -f $Private:Keys.Count, $BaselinePath) -ForegroundColor Green
				$Global:LASTEXITCODE = 0; return
			}

			$Private:New = @($Private:Sorted | Where-Object { -not $_.Accepted })
			$Private:Show = If ($All) { $Private:Sorted } Else { $Private:New }
			ForEach ($Private:S in $Private:Show)
			{
				$Private:Tags = @()
				If ($Private:S.Accepted) { $Private:Tags += 'accepted' }
				If ($Private:S.Frozen) { $Private:Tags += 'frozen' }
				If ($Private:S.Self) { $Private:Tags += 'self' }
				$Private:TagText = If ($Private:Tags.Count -gt 0) { ' (' + ($Private:Tags -join ', ') + ')' } Else { '' }
				Write-Host ('  {0}:{1}  [{2} pin {3} {4}, live is {5}]{6}' -f $Private:S.File, $Private:S.Line, $Private:S.Kind, $Private:S.Module, $Private:S.Version, $Private:S.Live, $Private:TagText) -ForegroundColor $(If ($Private:S.Accepted -or $Private:S.Frozen) { 'DarkGray' } Else { 'Red' })
				If (-not $Quiet) { Write-Host ('    {0}' -f $Private:S.Text) -ForegroundColor DarkGray }
			}
			If ($PassThru) { $Private:Show }

			If ($Private:New.Count -eq 0)
			{
				If ($Private:Skipped.Count -gt 0) { Write-Host ('NOT CLEAN - no new sites, but {0} path(s)/file(s) were not checked.' -f $Private:Skipped.Count) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
				Write-Host ('PASS - no new literal pin ({0} accepted).' -f ($Private:Sorted.Count - $Private:New.Count)) -ForegroundColor Green
				$Global:LASTEXITCODE = 0; return
			}
			If (-not $Quiet) { Write-Host '  Fix: ask the module instead of naming its version - Get-LiveModuleVersion / Import-LiveModule (LiveModule.ps1), or, for a pin inside a string built for a child process, interpolate the resolved version.' -ForegroundColor Yellow }
			Write-Host ('FAIL - {0} new literal pin(s) on a module with a LiveVersion.psd1.' -f $Private:New.Count) -ForegroundColor Red
			$Global:LASTEXITCODE = 1; return
		}
		Catch
		{
			Write-Host ('NOT CLEAN - PSHG-TestLivePinLiteral failed: {0}' -f $_.Exception.Message) -ForegroundColor Red
			$Global:LASTEXITCODE = 2; return
		}
	}
}

# Private helper (dot-sourced with the module, not exported): the module name and literal version when a command is
# Import-Module <X> -RequiredVersion <literal> or Open-MyElevatedSession -ModuleName <X> -ModuleVersion <literal>, else $null.
Function Get-PSHGLivePinCommandInfo
{
	[CmdletBinding()]
	Param ([Parameter(Mandatory)][System.Management.Automation.Language.CommandAst]$Command)

	Try
	{
		$Private:CmdName = $Command.GetCommandName()
		If ($Private:CmdName -ieq 'Import-Module') { $Private:Kind = 'Import'; $Private:VerParam = 'RequiredVersion'; $Private:NameParam = 'Name' }
		ElseIf ($Private:CmdName -ieq 'Open-MyElevatedSession') { $Private:Kind = 'Elevated'; $Private:VerParam = 'ModuleVersion'; $Private:NameParam = 'ModuleName' }
		Else { return $null }

		# A literal is a constant in the source, never a variable or an expression.
		$Private:LiteralText = {
			Param ($N)
			If ($N -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return [String]$N.Value }
			If ($N -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $N.Extent.Text }
			return $null
		}

		$Private:Mod = $null; $Private:Ver = $null; $Private:Want = ''; $Private:Positional = $false; $Private:SkipNext = $false
		ForEach ($Private:El in ($Command.CommandElements | Select-Object -Skip 1))
		{
			If ($Private:El -is [System.Management.Automation.Language.CommandParameterAst])
			{
				$Private:Pn = $Private:El.ParameterName
				If ($Private:Pn -ieq $Private:VerParam) { $Private:Want = 'Ver' } ElseIf ($Private:Pn -ieq $Private:NameParam) { $Private:Want = 'Name' } Else { $Private:Want = '' }
				# Any other parameter that is not a switch takes the next element as its value (-ErrorAction Stop), which is not the module name.
				If (-not $Private:Want -and -not $Private:El.Argument -and $Private:Pn -notin 'Force', 'Global', 'PassThru', 'DisableNameChecking', 'NoClobber', 'SkipEditionCheck', 'AsCustomObject') { $Private:SkipNext = $true }
				If ($Private:El.Argument)
				{
					$Private:T = & $Private:LiteralText $Private:El.Argument
					If ($Private:Want -eq 'Ver') { $Private:Ver = $Private:T } ElseIf ($Private:Want -eq 'Name') { $Private:Mod = $Private:T }
					$Private:Want = ''
				}
				Continue
			}
			$Private:T = & $Private:LiteralText $Private:El
			If ($Private:Want -eq 'Ver') { $Private:Ver = $Private:T; $Private:Want = ''; Continue }
			If ($Private:Want -eq 'Name') { $Private:Mod = $Private:T; $Private:Want = ''; $Private:Positional = $true; Continue }
			If ($Private:SkipNext) { $Private:SkipNext = $false; Continue }
			If (-not $Private:Positional -and -not $Private:Mod -and $Private:Kind -eq 'Import') { $Private:Mod = $Private:T; $Private:Positional = $true }
		}

		If (-not $Private:Mod -or -not $Private:Ver) { return $null }
		If ($Private:Ver -notmatch '^\d+(\.\d+)+$') { return $null }
		If ($Private:Mod -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$') { return $null }
		return [PSCustomObject]@{ Module = $Private:Mod; Version = $Private:Ver; Kind = $Private:Kind }
	}
	Catch { Write-Verbose ('Get-PSHGLivePinCommandInfo: {0}' -f $_.Exception.Message); return $null }
}
