Function PSHG-TestFileEncoding
{
	<#
		.SYNOPSIS
		Enforces UTF-8-WITH-BOM encoding on every .ps1 / .psm1 / .psd1 file - one of two tools in
		this toolkit that actually FIXES the file, not just reports it (with -Fix).

		.DESCRIPTION
		WHY BOM, and why unconditional:
		  - Windows PowerShell 5.1 reads a file with NO BOM as ANSI/Windows-1252, NOT UTF-8. Any
		    non-ASCII byte in such a file is therefore mis-decoded. PowerShell 7 reads UTF-8 either
		    way.
		  - So BOM is safe under BOTH hosts; no-BOM is safe ONLY while a file stays pure ASCII.
		  - A conditional rule ("BOM only if the file has non-ASCII") is unenforceable: a pure-ASCII
		    file is fine right up until someone types a smart quote into it, then breaks silently.
		    An unconditional rule cannot rot this way.

		SAFETY - this is why the function does not simply rewrite everything:
		A file that is genuinely ANSI-encoded (byte sequences that are NOT valid UTF-8) would be
		CORRUPTED by re-encoding it as UTF-8. Every file is therefore strict-UTF-8 validated first;
		anything that fails is reported as NEEDS-REVIEW and left completely untouched for a human to
		convert deliberately. This includes a file that already has a BOM but whose body is not valid UTF-8.

		Also detects and (with -Fix) repairs a DOUBLED BOM - a real, reproducible bug where a second
		BOM sequence sits immediately after the first. PowerShell's parser strips it fine, but a
		`. $file` dot-source leaves a literal U+FEFF glued to the first token, which fails at RUNTIME
		with CommandNotFoundException while every static check stays silent.

		.PARAMETER Path
		Repo root, folder, or individual files. Defaults to the current directory.

		.PARAMETER Fix
		Add the BOM to non-compliant files (and repair a doubled BOM). Without this the function
		only reports (returns 1 if any are wrong).

		.PARAMETER IncludeFrozen
		Also process _RetiredModules / .archive / Original / Originals. Off by default - those are
		frozen backstops and rewriting them gains nothing while risking a change to code kept for
		reference.

		.EXAMPLE
		PSHG-TestFileEncoding
		Report only.

		.EXAMPLE
		PSHG-TestFileEncoding -Fix
		Convert non-compliant files.

		.NOTES
		Returns 0 = all compliant, 1 = non-compliant found (or fixed), 2 = files need manual review: not valid
		UTF-8 (with or without a BOM), unreadable, or a named path that does not exist
		(wrap the call in `PSHG-TestFileEncoding ...; exit $LASTEXITCODE` for a process exit code). Supports
		-WhatIf with -Fix (nothing is written; the exit code stays 1 while files remain to convert). Rewrites go
		through a temp file in the same folder, so an interrupted write cannot leave a half-written file. Related:
		PSHG-FormatPS1File preserves whatever BOM state a file already has, so it will not fight
		this function.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
		Justification = 'Console reporter, consistent with the other functions in this toolkit.')]
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[String[]]$Path,
		[Switch]$Fix,
		[Switch]$IncludeFrozen
	)

	if (-not $Path) { $Path = @($PWD.ProviderPath) }

	$frozenPattern = '\\(\.git|\.claude|\.vscode|_RetiredModules|\.archive|Original|Originals|Reports|Snapshots)\\'
	$targets = New-Object System.Collections.Generic.List[System.IO.FileInfo]

	$compliant  = 0
	$converted  = 0
	$needsBom   = New-Object System.Collections.Generic.List[String]
	$needsCheck = New-Object System.Collections.Generic.List[String]
	$doubledBom = New-Object System.Collections.Generic.List[String]

	foreach ($item in $Path)
	{
		if (-not (Test-Path -LiteralPath $item)) { $needsCheck.Add(('{0} (path not found)' -f $item)); continue }
		if (Test-Path -LiteralPath $item -PathType Container)
		{
			Get-ChildItem -LiteralPath $item -Recurse -File -ErrorAction SilentlyContinue |
				Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
				Where-Object { $IncludeFrozen -or $_.FullName -notmatch $frozenPattern } |
				ForEach-Object { $targets.Add($_) }
		}
		else { $targets.Add((Get-Item -LiteralPath $item)) }
	}

	# Strict UTF-8 decoder: throws on any byte sequence that is not valid UTF-8.
	$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
	$bomEncoder = New-Object System.Text.UTF8Encoding($true)

	$bomBytes   = [Byte[]](0xEF, 0xBB, 0xBF)
	$pendingFix = 0

	foreach ($file in $targets)
	{
		$bytes = $null
		try { $bytes = [System.IO.File]::ReadAllBytes($file.FullName) }
		catch
		{
			$needsCheck.Add(('{0} (cannot read: {1})' -f $file.FullName, $_.Exception.Message))
			continue
		}
		if ($bytes.Length -eq 0) { continue }

		# Leading BOM count: one is the standard, more is the doubled-BOM defect.
		$bomCount = 0
		while (($bomCount * 3) + 2 -lt $bytes.Length -and $bytes[$bomCount * 3] -eq 0xEF -and $bytes[$bomCount * 3 + 1] -eq 0xBB -and $bytes[$bomCount * 3 + 2] -eq 0xBF) { $bomCount++ }
		$bodyStart = $bomCount * 3

		# The body must be valid UTF-8 whether or not a BOM is present: a BOM in front of ANSI bytes would be
		# counted compliant, and re-encoding such a body would corrupt it.
		$body = $null
		try { $body = $strictUtf8.GetString($bytes, $bodyStart, $bytes.Length - $bodyStart) }
		catch
		{
			$needsCheck.Add($file.FullName)
			continue
		}

		if ($bomCount -eq 1) { $compliant++; continue }

		if ($bomCount -gt 1) { $doubledBom.Add($file.FullName) } else { $needsBom.Add($file.FullName) }
		if ($Fix)
		{
			if ($PSCmdlet.ShouldProcess($file.FullName, 'Rewrite as UTF-8 with exactly one BOM'))
			{
				Write-PSHGFileAtomic -Path $file.FullName -Bytes ([Byte[]]($bomBytes + $bomEncoder.GetBytes($body)))
				$converted++
			}
			else { $pendingFix++ }
		}
	}

	$repoRoot = $PWD.ProviderPath
	Write-Host ''
	Write-Host ('=== Encoding check: {0} PowerShell file(s) ===' -f $targets.Count) -ForegroundColor Magenta
	Write-Host ('  already UTF-8 with BOM : {0}' -f $compliant) -ForegroundColor Green

	if ($needsBom.Count -gt 0)
	{
		$verb = if ($Fix) { 'CONVERTED' } else { 'MISSING BOM' }
		$col  = if ($Fix) { 'Green' } else { 'Yellow' }
		Write-Host ('  {0,-22} : {1}' -f $verb, $needsBom.Count) -ForegroundColor $col
		if (-not $Fix)
		{
			$needsBom | Select-Object -First 15 | ForEach-Object { Write-Host ('      {0}' -f $_.Replace($repoRoot, '.')) -ForegroundColor DarkGray }
			if ($needsBom.Count -gt 15) { Write-Host ('      ... and {0} more' -f ($needsBom.Count - 15)) -ForegroundColor DarkGray }
			Write-Host '      re-run with -Fix to convert' -ForegroundColor DarkGray
		}
	}

	if ($doubledBom.Count -gt 0)
	{
		$verb = if ($Fix) { 'FIXED (was doubled)' } else { 'DOUBLED BOM' }
		$col  = if ($Fix) { 'Green' } else { 'Red' }
		Write-Host ('  {0,-22} : {1}' -f $verb, $doubledBom.Count) -ForegroundColor $col
		if (-not $Fix)
		{
			$doubledBom | ForEach-Object { Write-Host ('      {0}' -f $_.Replace($repoRoot, '.')) -ForegroundColor Red }
			Write-Host '      A repeated BOM parses fine but fails at RUNTIME when dot-sourced (the first token' -ForegroundColor DarkGray
			Write-Host '      gets a literal U+FEFF glued to it) - re-run with -Fix to strip the extra BOM(s).' -ForegroundColor DarkGray
		}
	}

	if ($needsCheck.Count -gt 0)
	{
		Write-Host ('  NEEDS REVIEW (not valid UTF-8, unreadable or not found; LEFT UNTOUCHED) : {0}' -f $needsCheck.Count) -ForegroundColor Red
		$needsCheck | ForEach-Object { Write-Host ('      {0}' -f $_.Replace($repoRoot, '.')) -ForegroundColor Red }
		Write-Host '      Files that are not valid UTF-8 are probably ANSI/Windows-1252. Converting them blindly would corrupt the' -ForegroundColor DarkGray
		Write-Host '      characters - open each one, confirm what it should say, and re-save as UTF-8.' -ForegroundColor DarkGray
	}

	Write-Host ''
	if ($needsCheck.Count -gt 0) { $Global:LASTEXITCODE = 2; return }
	if ($Fix) { Write-Host ('Converted {0} file(s) to UTF-8 with BOM.' -f $converted) -ForegroundColor Green; if ($converted -or $pendingFix) { $Global:LASTEXITCODE = 1; return }; $Global:LASTEXITCODE = 0; return }
	if ($doubledBom.Count -gt 0) { $Global:LASTEXITCODE = 1; return }
	if ($needsBom.Count -gt 0) { $Global:LASTEXITCODE = 1; return }
	Write-Host 'All files comply with the UTF-8-with-BOM standard.' -ForegroundColor Green
	$Global:LASTEXITCODE = 0; return
}
