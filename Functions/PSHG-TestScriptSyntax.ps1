Function PSHG-TestScriptSyntax
{
	<#
		.SYNOPSIS
		Parse-checks and lints one or more .ps1 files - the fast per-file check while editing.

		.DESCRIPTION
		Two passes, in order:

		  1. PARSE via [System.Management.Automation.Language.Parser]::ParseFile. Always runs,
		     needs nothing installed, and catches the errors that matter most.
		  2. PSScriptAnalyzer, but ONLY if the file parsed. Running the analyzer on a file with
		     a syntax error produces a cascade of misleading findings.

		A missing PSScriptAnalyzer install is reported explicitly and the run continues
		parse-only, returning 3 - never silently treated as "clean."

		NOISE FILTERING - PSAvoidUsingWriteHost is suppressed by default. A console-reporting
		tool where Write-Host is the correct choice can produce dozens of these findings that
		drown out everything else. Use -IncludeWriteHost to see them.

		NOT a replacement for PSHG-TestRepoLint, which is the baseline GATE for a whole
		codebase (ShouldProcess / SingularNouns-style accepted debt). This is the fast
		per-file check while editing.

		A file containing ONLY PowerShell class definition(s) - no top-level executable
		statements - is exempt from being flagged when its only parse errors are "Unable to find
		type [...]" for every error. Standalone per-file parsing cannot resolve a class's reference
		to a SIBLING type (a base class, a property typed as another class in the same module) -
		only loading the whole module together can - so this is a false positive of checking class
		files one at a time, generic to any module using PowerShell classes, not specific to any
		one repo or module. A genuine mistake in such a file still surfaces where it always has:
		Pester's own Import-Module -Force loads every class together, so any real error is still
		caught, module-wide.

		.PARAMETER Path
		Files or folders. Folders are searched recursively for *.ps1 and *.psm1. Accepts pipeline input.

		.PARAMETER Severity
		PSScriptAnalyzer severities to report. Default Error + Warning.

		.PARAMETER IncludeWriteHost
		Do not filter out PSAvoidUsingWriteHost.

		.PARAMETER ExcludeRule
		Additional rule names to suppress.

		.PARAMETER Pwsh
		Report that the target is PS7-only. Does not re-launch - run this whole session
		under pwsh.exe for a true PS7 analysis.

		.EXAMPLE
		PSHG-TestScriptSyntax -Path .\MyScript.ps1

		.EXAMPLE
		PSHG-TestScriptSyntax -Path .\MyProject -ExcludeRule PSUseSingularNouns

		.EXAMPLE
		Get-ChildItem .\MyProject -Filter *.ps1 -Recurse | PSHG-TestScriptSyntax

		.NOTES
		Returns 0 = clean, 1 = parse errors OR a path/file that could not be checked (not found, unreadable,
		analyzer error on it), 2 = analyzer findings only, 3 = PSScriptAnalyzer
		not installed (parse-only run) - wrap the call in `PSHG-TestScriptSyntax ...; exit $LASTEXITCODE`
		for a process exit code. Folders are searched for .ps1 and .psm1.
	#>
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[Alias('FullName')]
		[String[]]$Path,

		[ValidateSet('Error', 'Warning', 'Information')]
		[String[]]$Severity = @('Error', 'Warning'),

		[Switch]$IncludeWriteHost,
		[String[]]$ExcludeRule,
		[Switch]$Pwsh
	)

	Begin
	{
		$Script:SyntaxQueue           = New-Object System.Collections.Generic.List[String]
		$Script:ParseErrorFiles = 0
		$Script:UncheckedFiles  = 0
		$Script:FindingCount    = 0
		$Script:FileCount       = 0

		$Script:HaveAnalyzer = $null -ne (Get-Command -Name 'Invoke-ScriptAnalyzer' -ErrorAction SilentlyContinue)
		if (-not $Script:HaveAnalyzer)
		{
			# Try to load it before deciding it is absent.
			if (Get-Module -ListAvailable -Name PSScriptAnalyzer -ErrorAction SilentlyContinue)
			{
				try { Import-Module PSScriptAnalyzer -ErrorAction Stop; $Script:HaveAnalyzer = $true }
				catch
				{
					# Listed but unloadable is NOT the same as absent - say which, or the
					# parse-only fallback looks like a clean bill of health on a broken install.
					Write-Host ('NOTE: PSScriptAnalyzer is installed but failed to load: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
				}
			}
		}
		if (-not $Script:HaveAnalyzer)
		{
			Write-Host 'NOTE: PSScriptAnalyzer is not installed - running PARSE ONLY.' -ForegroundColor Yellow
			Write-Host '      See README.md''s Requirements section to install it for the full check.' -ForegroundColor DarkGray
		}
		if ($Pwsh)
		{
			Write-Host ('NOTE: PS7-only target. Current host is PowerShell {0}.' -f $PSVersionTable.PSVersion) -ForegroundColor Yellow
		}

		$Script:Suppressed = New-Object System.Collections.Generic.List[String]
		if (-not $IncludeWriteHost) { $Script:Suppressed.Add('PSAvoidUsingWriteHost') }
		foreach ($r in $ExcludeRule) { $Script:Suppressed.Add($r) }
	}

	Process
	{
		foreach ($item in $Path) { [void]$Script:SyntaxQueue.Add($item) }
	}

	End
	{
		foreach ($item in $Script:SyntaxQueue)
		{
			if (-not (Test-Path -LiteralPath $item))
			{
				$Script:UncheckedFiles++
				Write-Host ('NOT FOUND (not checked): {0}' -f $item) -ForegroundColor Red
				continue
			}

			$files = if (Test-Path -LiteralPath $item -PathType Container)
			{
				Get-ChildItem -LiteralPath $item -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } | Select-Object -ExpandProperty FullName
			}
			else { @($item) }

			foreach ($f in $files)
			{
				$Script:FileCount++
				$name = Split-Path $f -Leaf

				$parseErrors = $null
				$parseTokens = $null
				try { $parseAst = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$parseTokens, [ref]$parseErrors) }
				catch
				{
					$Script:UncheckedFiles++
					Write-Host ('{0}: NOT CHECKED - cannot read: {1}' -f $name, $_.Exception.Message) -ForegroundColor Red
					continue
				}

				if ($parseErrors.Count -gt 0)
				{
					# A file that only DEFINES PowerShell class(es) - no top-level executable
					# statements of its own - cannot be parsed in isolation if any of those classes
					# reference a sibling type (a base class, a property/parameter typed as another
					# class in the same module): the parser resolves member/inheritance types at
					# parse time, and a lone file has no way to see types that only exist once the
					# whole module loads together. This is not a real defect in the file - it is a
					# structural limitation of checking class files one at a time, and it affects any class that
					# references a sibling type defined in another file of the same module. A GENUINE problem in a class file
					# (a real typo, a missing brace) still surfaces exactly where it always has -
					# Pester's own Import-Module -Force loads the whole module together, so every
					# type resolves and any actual error is caught there, module-wide, same as any
					# other cross-file mistake would be.
					$Private:_isPureClassFile = $parseAst -and
					$parseAst.EndBlock.Statements.Count -gt 0 -and
					(@($parseAst.EndBlock.Statements) |
						Where-Object { $_ -isnot [System.Management.Automation.Language.TypeDefinitionAst] }).Count -eq 0
					$Private:_onlyTypeResolutionErrors = $Private:_isPureClassFile -and
					(@($parseErrors) | Where-Object { $_.ErrorId -ne 'TypeNotFound' }).Count -eq 0

					if ($Private:_onlyTypeResolutionErrors)
					{
						Write-Host ('{0}: class file - cross-type references unresolved standalone (verified at module import instead)' -f $name) -ForegroundColor DarkGray
						continue
					}

					$Script:ParseErrorFiles++
					Write-Host ('{0}: PARSE ERROR' -f $name) -ForegroundColor Red
					foreach ($e in $parseErrors)
					{
						Write-Host ('  line {0}: {1}' -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
					}
					continue   # analyzer output on an unparseable file is noise
				}

				if (-not $Script:HaveAnalyzer)
				{
					Write-Host ('{0}: parses OK (not analyzed)' -f $name) -ForegroundColor DarkGray
					continue
				}

				# -Path takes wildcards, so escape [ and ] in the file name.
				$saErrors = $null
				$sa = @(Invoke-ScriptAnalyzer -Path ([WildcardPattern]::Escape($f)) -Severity $Severity -ErrorAction SilentlyContinue -ErrorVariable saErrors |
						Where-Object { $Script:Suppressed -notcontains $_.RuleName })
				if ($saErrors)
				{
					$Script:UncheckedFiles++
					Write-Host ('{0}: NOT ANALYZED - PSScriptAnalyzer reported: {1}' -f $name, $saErrors[0].Exception.Message) -ForegroundColor Red
					continue
				}

				if ($sa.Count -eq 0)
				{
					Write-Host ('{0}: Clean' -f $name) -ForegroundColor Green
				}
				else
				{
					$Script:FindingCount += $sa.Count
					Write-Host ('{0}:' -f $name) -ForegroundColor Yellow
					foreach ($s in $sa)
					{
						Write-Host ('  [{0}] line {1}: {2} - {3}' -f $s.Severity, $s.Line, $s.RuleName, $s.Message)
					}
				}
			}
		}

		Write-Host ''
		$bits = @('{0} file(s)' -f $Script:FileCount)
		if ($Script:ParseErrorFiles) { $bits += '{0} with PARSE ERRORS' -f $Script:ParseErrorFiles }
		if ($Script:UncheckedFiles)  { $bits += '{0} NOT CHECKED' -f $Script:UncheckedFiles }
		if ($Script:FindingCount)    { $bits += '{0} finding(s)' -f $Script:FindingCount }
		if ($Script:Suppressed.Count -and -not $IncludeWriteHost)
		{
			$bits += ('suppressed: {0}' -f ($Script:Suppressed -join ', '))
		}
		Write-Host ('=== {0} ===' -f ($bits -join ', ')) -ForegroundColor Magenta

		if ($Script:ParseErrorFiles -gt 0 -or $Script:UncheckedFiles -gt 0) { $Global:LASTEXITCODE = 1; return }
		if (-not $Script:HaveAnalyzer)     { $Global:LASTEXITCODE = 3; return }
		if ($Script:FindingCount -gt 0)    { $Global:LASTEXITCODE = 2; return }
		$Global:LASTEXITCODE = 0; return
	}
}
