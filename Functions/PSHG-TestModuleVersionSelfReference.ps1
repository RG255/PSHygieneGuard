Function PSHG-TestModuleVersionSelfReference
{
	<#
		.SYNOPSIS
		Finds a module's own files still referencing an OLDER version of ITSELF - the class of bug a
		version branch leaves behind (a hardcoded path/import/pin that should have followed the bump).

		.DESCRIPTION
		Applies to any codebase that versions a module as SIBLING VERSION FOLDERS (e.g.
		`MyModule\0.5\`, `MyModule\0.6\`) - a common convention for keeping older, frozen versions
		around as backstops while active development happens in the newest one. Neither checking a
		consumer's pin against a module, nor comparing source against a deployed copy, checks whether
		a module's OWN files stay self-consistent about their OWN version number after a branch - a
		fresh branch can leave Tests\ scripts (or any other file) still hardcoding the OLD version in
		an `Import-Module -RequiredVersion`, a literal path segment, or a `Name`/`Version` hashtable
		pair - each one would silently import or test the WRONG (old, frozen) version instead of the
		one actually being worked on, with no error to signal it.

		Findings are GRADED, because not every mention of an older version number is a bug - a
		comment citing a planning doc at its own historical path, or a changelog note referencing a
		defect found in an old version, is accurate and must NOT be flagged:

		  FUNCTIONAL - the older version appears in a real, executable reference: an `Import-Module`
		               statement, a `-RequiredVersion` pin, or a `Name`/`Version`-style hashtable pair
		               naming THIS module. These are real bugs: the code would load the wrong version
		               at runtime with no error. Returns 1.
		  INFORMATIONAL - the older version appears anywhere else (comments, docs, single-line hash
		               remarks, block-comment bodies) - printed for a human to judge, never fails the
		               run. Most of these are legitimate historical citations.

		Comment detection is line-based, not full AST: a line whose trimmed text starts with a hash,
		or any line inside a block comment, is treated as commentary. A trailing hash-comment on an
		otherwise executable line is NOT detected as commentary (a known, accepted limitation - full
		AST parsing would remove this gap at real added complexity, and this checker is only meant to
		run once, right after a branch, not on every edit).

		.PARAMETER RootPath
		Folder containing the module's version subfolders, i.e. the PARENT of `<Module>\<Version>\`.
		Defaults to the current directory.

		.PARAMETER Module
		Module name, e.g. 'MyModule'.

		.PARAMETER Version
		Version folder to check for SELF-consistency (e.g. '0.6' - the newly branched version).
		Defaults to the newest version folder under the module.

		.PARAMETER ShowInfo
		Also print INFORMATIONAL findings (default: only the summary count is shown for those; use
		this to review them, e.g. right after a branch, to confirm nothing was missed).

		.EXAMPLE
		PSHG-TestModuleVersionSelfReference -RootPath 'C:\MyProject\Modules' -Module MyModule -Version 0.6

		.NOTES
		Returns 0 = no FUNCTIONAL findings, 1 = FUNCTIONAL findings (real bugs), 2 = module/version
		not found (wrap the call in `PSHG-TestModuleVersionSelfReference ...; exit $LASTEXITCODE` for a process
		exit code). Version folders have two or more numeric parts (0.17, 1.2.3), and a version only matches at a boundary (0.1 does not match inside 0.17, 0.10 or 0.1.5). A relative -RootPath is resolved first. A FUNCTIONAL pin is recognised as -RequiredVersion or -ModuleVersion followed by the old version, with the module name on the SAME line (a call that splits them over several lines is missed). Only useful right after a version branch, not on a routine release.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Coloured console report, matching the other functions in this toolkit')]
	[CmdletBinding()]
	Param (
		[String]$RootPath = $PWD.ProviderPath,
		[Parameter(Mandatory)]
		[String]$Module,
		[String]$Version,
		[Switch]$ShowInfo
	)

	# Absolute root, so the file names printed below are relative to it however it was given.
	If (Test-Path -LiteralPath $RootPath -PathType Container) { $RootPath = (Resolve-Path -LiteralPath $RootPath).ProviderPath }
	$ModuleDir = Join-Path -Path $RootPath -ChildPath $Module
	If (-not (Test-Path -LiteralPath $ModuleDir -PathType Container))
	{
		Write-Host ('Module not found: [{0}]' -f $ModuleDir) -ForegroundColor Red
		$Global:LASTEXITCODE = 2; return
	}

	# Version folders: two or more numeric parts (0.17, 1.2.3).
	$Private:_allVersions = @(Get-ChildItem -LiteralPath $ModuleDir -Directory -ErrorAction SilentlyContinue |
			Where-Object { $_.Name -match '^\d+(\.\d+)+$' } | Select-Object -ExpandProperty Name)
	If (-not $Version)
	{ $Version = ($Private:_allVersions | Sort-Object { [Version]$_ } -Descending | Select-Object -First 1) }
	If ($Version -notin $Private:_allVersions)
	{
		Write-Host ('Version [{0}] not found under [{1}]' -f $Version, $ModuleDir) -ForegroundColor Red
		$Global:LASTEXITCODE = 2; return
	}
	$TargetDir = Join-Path -Path $ModuleDir -ChildPath $Version

	# Every OTHER version folder for this module - a self-reference to any of these is the thing being
	# hunted for. Not "any number that looks like a version" - only ones that genuinely exist as a
	# sibling, so an unrelated number (e.g. a size like '0.5GB') is never mistaken for a version.
	$OlderVersions = @($Private:_allVersions | Where-Object { $_ -ne $Version })
	If (-not $OlderVersions)
	{
		Write-Host ('No other version folders exist for [{0}] - nothing to compare against.' -f $Module) -ForegroundColor Yellow
		$Global:LASTEXITCODE = 0; return
	}

	Write-Host ('Checking {0} {1} for self-references to older version(s): {2}' -f $Module, $Version, ($OlderVersions -join ', ')) -ForegroundColor Cyan

	$Functional = [System.Collections.Generic.List[PSCustomObject]]::new()
	$Informational = [System.Collections.Generic.List[PSCustomObject]]::new()

	$Files = Get-ChildItem -LiteralPath $TargetDir -Recurse -File -ErrorAction SilentlyContinue |
		Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.md' }

	ForEach ($File in $Files)
	{
		$Lines = [System.IO.File]::ReadAllLines($File.FullName)
		$InBlockComment = $false
		For ($Private:_i = 0; $Private:_i -lt $Lines.Count; $Private:_i++)
		{
			$Private:_line  = $Lines[$Private:_i]
			$Private:_trim  = $Private:_line.Trim()
			$Private:_isMd  = $File.Extension -ieq '.md'

			# Track <# #> block-comment state (only meaningful for .ps1/.psm1/.psd1).
			$Private:_isComment = $Private:_isMd -or $InBlockComment -or $Private:_trim.StartsWith('#')
			If (-not $Private:_isMd)
			{
				If ($Private:_trim -match '<#') { $InBlockComment = $true }
				If ($Private:_trim -match '#>') { $InBlockComment = $false }
			}

			ForEach ($Old in $OlderVersions)
			{
				# The version must end at a boundary: 0.1 must not match inside 0.17, 0.10 or 0.1.5.
				$Private:_verEsc = '{0}(?!\d|\.\d)' -f [Regex]::Escape($Old)
				# Three FUNCTIONAL shapes: a path segment "<Module>\<OldVersion>\", a RequiredVersion
				# pin naming this module nearby, or a Name/Version hashtable pair with this module's
				# Name alongside it on the same line.
				$Private:_pathHit    = $Private:_line -match ('{0}\\{1}\\' -f [Regex]::Escape($Module), $Private:_verEsc)
				$Private:_pinHit     = ($Private:_line -match ('(?i)-(?:Required|Module)Version\s+[''"]?{0}' -f $Private:_verEsc)) -and
				($Private:_line -match ('(?i){0}' -f [Regex]::Escape($Module)))
				$Private:_loadHit    = ($Private:_line -match ('(?i)Name\s*=\s*''{0}''' -f [Regex]::Escape($Module))) -and
				($Private:_line -match ('(?i)Version\s*=\s*''{0}''' -f $Private:_verEsc))
				$Private:_anyHit = $Private:_pathHit -or $Private:_pinHit -or $Private:_loadHit

				If (-not $Private:_anyHit) { Continue }

				$Private:_row = [PSCustomObject]@{
					File    = $File.FullName.Substring($RootPath.Length).TrimStart('\')
					Line    = $Private:_i + 1
					Text    = $Private:_trim
					OldVer  = $Old
				}
				If ($Private:_isComment)
				{ $Informational.Add($Private:_row) }
				Else
				{ $Functional.Add($Private:_row) }
			}
		}
	}

	If ($Functional.Count -gt 0)
	{
		Write-Host ("`nFUNCTIONAL - real self-reference bug(s), version did not carry through:" ) -ForegroundColor Red
		ForEach ($F in $Functional)
		{ Write-Host ('  {0}:{1}  [{2}]' -f $F.File, $F.Line, $F.Text) -ForegroundColor Red }
	}

	Write-Host ("`n{0} functional finding(s), {1} informational (comment/doc) finding(s)." -f $Functional.Count, $Informational.Count) -ForegroundColor $(If ($Functional.Count) { 'Red' } Else { 'Green' })

	If ($ShowInfo -and $Informational.Count -gt 0)
	{
		Write-Host "`nINFORMATIONAL (comment/doc mentions - review, not auto-flagged as broken):" -ForegroundColor DarkGray
		ForEach ($I in $Informational)
		{ Write-Host ('  {0}:{1}  [{2}]' -f $I.File, $I.Line, $I.Text) -ForegroundColor DarkGray }
	}

	If ($Functional.Count -gt 0) { $Global:LASTEXITCODE = 1; return }
	$Global:LASTEXITCODE = 0; return
}
