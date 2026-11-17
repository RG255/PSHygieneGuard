Function PSHG-FindDriveLetterAssumption
{
	<#
		.SYNOPSIS
		Finds code that assumes a DRIVE LETTER and so silently mishandles folder mounts / letter-less volumes.

		.DESCRIPTION
		Three distinct real-world trigger shapes motivate this checker:

		  1. An UNANCHORED drive-letter regex (e.g. '^([A-Za-z]):' with no trailing '$') matches a
		     FOLDER access path too, so a pre-mount collision check can think a folder mount wants the
		     drive letter it happens to sit on.
		  2. An accessibility probe that only runs for partitions WITH a letter, so a folder mount is
		     silently treated as inaccessible/locked.
		  3. A verify/gate condition anchored as '^[A-Za-z]:$' only, so a letter-less mount point (e.g.
		     a BitLocker volume reporting '\\?\Volume{GUID}\') can never satisfy it and sits unproven
		     forever.

		The pattern is consistent across all three: the drive-letter path gets written first and the
		folder-mount path gets assumed away. This function lists candidate sites so they can be judged,
		rather than waiting to trip over the next one - it does NOT decide; most hits are legitimate.

		WHAT IS USUALLY FINE (do not "fix" these):
		  - gated on MountType, e.g.  If ($MountType -ieq 'D') { $Path.TrimEnd(':') + ':\' } Else { $MountPath }
		  - a letter used only for DISPLAY
		  - USB / physical backup drives, which genuinely have letters
		  - a lettered lookup that FALLS BACK to a letter-less one
		  - matching on .Path / .AccessPaths as well as .DriveLetter

		WHAT IS SUSPECT:
		  - an anchored-at-the-start-only letter regex ('^([A-Za-z]):' with no '$')
		  - a skip / continue / return when no letter is present, in a path that must support folder mounts
		  - filtering partitions to those WITH a drive letter and having no fallback

		SUB-CLASSIFICATION of the raw 'trim-colon' pattern (built from a real
		codebase review): 'TrimEnd(":")' on its own says nothing about what happens next, so
		four further, narrower shapes are recognized and relabeled when a hit is CONFIRMED safe by
		its own surrounding code, not guessed:
		  - 'trim-reattach-colon' - the trim is immediately followed by putting exactly one colon
		    back, either via string concatenation (TrimEnd(':') + ':') or a format string whose
		    template itself supplies the colon ('{0}:\' -f (...).TrimEnd(':')). A defensive
		    normalization, not an assumption.
		  - 'trim-for-driveletter-api' - the trimmed result is fed straight into a real -DriveLetter
		    parameter (Get-Volume, Get-Partition, Set-Partition, ...), assigned to a variable first
		    or passed inline - that parameter's OWN documented contract wants the bare letter, so
		    trimming is REQUIRED, not assumed. Confirmed against real code.
		Two further real, hand-verified-safe cases were found but deliberately NOT automated - see
		.NOTES "Why two known-safe hits still report as plain trim-colon".

		CONSISTENCY IS THE LOAD-BEARING ASSUMPTION, not variable naming. These sub-classifications
		do NOT assume any particular variable name (they either match same-line SHAPE, which never
		looks at names at all, or capture whatever name the assignment actually used and search for
		THAT SAME captured name reused later) - a codebase using `$dl` instead of `$DriveLetter`
		classifies identically, because the tool never hardcodes the variable's own name, only
		Microsoft's own storage-cmdlet surface (.DriveLetter the property, -DriveLetter the
		parameter), which is universal to any PowerShell code calling those cmdlets, not a
		per-repo convention. What genuinely IS an assumption: that the codebase being scanned
		applies ITS OWN chosen bare-vs-colon-qualified convention CONSISTENTLY throughout. If one
		corner of a codebase strips a colon and reliably reattaches it (or reliably keeps it bare
		for a -DriveLetter call) while another corner does something DIFFERENT with the same-
		looking code, a hit that superficially matches one of these "safe" shapes could still be a
		genuine bug - this tool verifies SHAPE, never actual runtime behavior, so a real defect
		hiding behind a coincidentally-safe-looking shape would still be missed. Verified sound for
		the codebase this was built against (read by hand, not just pattern-matched, before trusting each
		reclassification) - not something to assume holds elsewhere without the same manual check.

		.PARAMETER Path
		Root to scan. Defaults to the current directory.

		.PARAMETER Csv
		Optional path to write the full candidate list to.

		.PARAMETER DecisionsOnly
		Show only hits that look like a DECISION (if / Where-Object / continue / return / -not), which is
		where the silent-skip defects live. Display-only uses are dropped.

		.EXAMPLE
		PSHG-FindDriveLetterAssumption -DecisionsOnly

		.EXAMPLE
		PSHG-FindDriveLetterAssumption -Path 'C:\MyProject' -Csv 'C:\Temp\letters.csv'

		.NOTES
		Why two known-safe hits still report as plain trim-colon (deliberate, not an oversight):
		found in the codebase this was built against, both confirmed safe by hand-reading the surrounding
		code, neither automated:
		  - Case 1 - safe because the trimmed value is later compared (-ine)
		    against ANOTHER variable, and THAT variable was itself assigned from a real .DriveLetter
		    property 50 lines earlier. Verifying this needs a two-hop trace: find the comparison,
		    then find where the COMPARISON PARTNER (not the trimmed value itself) was assigned.
		  - Case 2 - safe because the same field gets re-trimmed-and-reattached
		    again in a different function, further down the same file. Verifying this
		    needs recognizing that another ALREADY-CLASSIFIED trim-reattach-colon row later in the
		    file references the same field name.
		Both are a different order of complexity from the four same-line/nearby-line patterns above
		- tracking variable IDENTITY across dozens of lines or function boundaries starts trading
		away reliability (a coincidental variable-name reuse could produce a false "safe" verdict)
		for a shrinking return (2 hits, in one module, after four rounds of narrower refinement).
		Left as manual review on purpose - a human reading two lines is cheaper and more trustworthy
		than a text-matcher attempting real dataflow analysis.

		FOR LATER (raised, not built): a caller-supplied extension point for a codebase with its
		own additional safe idioms (its own -DriveLetter-shaped internal function, say) - the
		natural template is PSHG-TestScriptErrorHandling's own -KnownSignalFunction parameter
		(added for the same reason: built-in recognition covers only the patterns it was built
		against, an extra parameter lets a DIFFERENT codebase teach the checker its own
		equivalents without editing the tool itself).
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject[]])]
	Param (
		[String]$Path = $PWD.ProviderPath,
		[String]$Csv,
		[Switch]$DecisionsOnly
	)

	$Patterns = [ordered]@{
		'letter-regex' = "'\^\[A-Za-z\]|\^\[A-Z\]|-match\s+'\^\w:|\[A-Za-z\]:"
		'driveletter'  = '\.DriveLetter'
		'trim-colon'   = "TrimEnd\('':''\)|TrimEnd\(':'\)"
		'substring2'   = 'Substring\(0,\s*2\)'
	}
	$Skip = '\\_RetiredModules\\|\\\.archive\\|\\Original\\|\\Originals\\|\\\.git\\'

	$Files = Get-ChildItem -LiteralPath $Path -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue |
		Where-Object { $_.FullName -notmatch $Skip }

	$Rows = @()
	foreach ($Name in $Patterns.Keys)
	{
		foreach ($Hit in ($Files | Select-String -Pattern $Patterns[$Name]))
		{
			$Text = ($Hit.Line.Trim() -replace '\s+', ' ')
			if ($Text -match '^\s*#') { continue }
			if ($DecisionsOnly -and ($Text -notmatch '\bif\b|\bWhere-Object\b|\bcontinue\b|\breturn\b|-not')) { continue }
			$Rows += [PSCustomObject]@{
				Pattern = $Name
				File    = $Hit.Path
				Line    = $Hit.LineNumber
				Text    = $Text
			}
		}
	}

	# Sub-classify 'trim-colon' hits that reattach exactly one colon right after trimming it -
	# TrimEnd(':') alone just removes the colon and tells nothing about what happens next, but
	# TrimEnd(':') + ':' (whitespace-tolerant either side of '+') is the specific idiom that
	# strips-then-reattaches to guarantee EXACTLY one colon regardless of what the caller passed
	# in - a defensive normalization, not an assumption. $Text is already whitespace-collapsed to
	# single spaces above, so this compares on SHAPE, not on incidental formatting differences
	# (extra/missing spaces around '+', doubled vs. single-escaped quotes). Kept as its OWN
	# distinct pattern name rather than dropped from the list entirely - the tool's own posture is
	# "candidate list, human decides", so even a near-certainly-safe idiom stays visible, just
	# grouped so a reviewer can recognize and skip the whole bucket by eye.
	$ReattachPattern = "(TrimEnd\('':''\)|TrimEnd\(':'\))\s?\+\s?[`"']:"
	foreach ($Row in $Rows)
	{
		if ($Row.Pattern -eq 'trim-colon' -and $Row.Text -match $ReattachPattern)
		{ $Row.Pattern = 'trim-reattach-colon' }
	}

	# Second sub-classification: a remaining bare trim (no reattach) whose result is assigned to
	# a variable that gets fed straight into a known "-DriveLetter"-parameter call (Get-Volume,
	# Get-Partition, Set-Partition, ...) is equally safe - not a guess, but confirmed correct by
	# that PARAMETER'S OWN documented contract, which wants the bare letter with no colon. Example:
	# `$DriveLetter = $VolSpec.TrimEnd(':')` followed immediately by
	# `Get-Volume -DriveLetter $DriveLetter`.
	# Needs the surrounding lines, since the assignment and its use are usually on DIFFERENT
	# lines (unlike the same-line reattach idiom above) - reads each affected file once, cached,
	# rather than working from the single already-captured line of $Text. Deliberately narrow: a
	# small, closed vocabulary of storage cmdlets checked by PARAMETER NAME on a nearby line, not
	# general cross-file variable-flow tracking - that broader version would be far less reliable
	# and was deliberately not attempted (see the conversation this was built from).
	$FileContentCache = @{}
	$WindowLines = 10
	foreach ($Row in $Rows)
	{
		if ($Row.Pattern -ne 'trim-colon') { continue }
		if ($Row.Text -notmatch '^\$([\w:]+)\s*=') { continue }
		$VarName = $Matches[1]

		if (-not $FileContentCache.ContainsKey($Row.File))
		{ $FileContentCache[$Row.File] = Get-Content -LiteralPath $Row.File -ErrorAction SilentlyContinue }
		$Lines = $FileContentCache[$Row.File]
		if (-not $Lines -or $Lines.Count -eq 0) { continue }

		$WindowStart = $Row.Line - 1   # 0-indexed, starting at the trim line itself
		$WindowEnd   = [Math]::Min($Lines.Count - 1, $WindowStart + $WindowLines)
		if ($WindowEnd -lt $WindowStart) { continue }
		$Window = $Lines[$WindowStart..$WindowEnd] -join ' '

		if ($Window -match ('-DriveLetter\s+\$' + [Regex]::Escape($VarName) + '\b'))
		{ $Row.Pattern = 'trim-for-driveletter-api' }
	}

	# Two more SAME-LINE variants of patterns already covered above, both left over in
	# 'trim-colon' after the two refinements above:
	#
	# (a) The reattach idiom spelled via a FORMAT STRING instead of '+': ('{0}:\' -f
	#     (...).TrimEnd(':')) reattaches the colon through the template's own literal '{0}:'
	#     rather than string concatenation - same safe shape as trim-reattach-colon above, just a
	#     different way to write it.
	# (b) The -DriveLetter-parameter case above ONLY matched when the trim result was assigned to
	#     a variable first (searched forward for -DriveLetter $VarName). Get-Volume -DriveLetter
	#     ($X.TrimEnd(':')) does the exact same thing INLINE, with no
	#     intermediate variable - same-line, so no cross-line window needed for this variant.
	$FormatReattachPattern    = "[`"']\{0\}:.*-f\s"
	$InlineDriveLetterPattern = '-DriveLetter\s*\(.*TrimEnd\('
	foreach ($Row in $Rows)
	{
		if ($Row.Pattern -ne 'trim-colon') { continue }
		if ($Row.Text -match $FormatReattachPattern) { $Row.Pattern = 'trim-reattach-colon'; continue }
		if ($Row.Text -match $InlineDriveLetterPattern) { $Row.Pattern = 'trim-for-driveletter-api'; continue }
	}

	Write-Host ('Candidate sites: {0}{1}' -f $Rows.Count, $(if ($DecisionsOnly) { ' (decisions only)' } else { '' })) -ForegroundColor Cyan
	Write-Host ''
	foreach ($Group in ($Rows | Group-Object Pattern | Sort-Object Count -Descending))
	{ Write-Host ('  {0,-14} {1,3}' -f $Group.Name, $Group.Count) }
	Write-Host ''
	foreach ($Row in ($Rows | Sort-Object File, Line))
	{
		Write-Host ('  [{0}] {1}:{2}' -f $Row.Pattern, $Row.File, $Row.Line) -ForegroundColor DarkGray
		Write-Host ('      {0}' -f $Row.Text.Substring(0, [Math]::Min(110, $Row.Text.Length)))
	}

	if ($Csv)
	{
		$Rows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
		Write-Host ''
		Write-Host ('CSV: {0}' -f $Csv) -ForegroundColor DarkGray
	}

	# Unary comma REQUIRED: without it, a single-element (or zero-element) $Rows silently
	# unwraps into a scalar (or $null) on return instead of staying an array, so a caller's
	# .Count check breaks specifically at 0 or 1 results - found live via this module's own
	# Pester suite.
	return ,$Rows
}
