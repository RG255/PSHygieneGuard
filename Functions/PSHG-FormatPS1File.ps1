Function PSHG-FormatPS1File
{
	<#
		.SYNOPSIS
		Reformats a .ps1/.psm1 to a consistent tab-indentation style, PRESERVING its existing
		encoding - one of two functions in this toolkit that actually FIXES the file, not just
		reports it.

		.DESCRIPTION
		Indentation is normalised to tabs (IndentationSize 1) via PSScriptAnalyzer's
		Invoke-Formatter. Trailing whitespace is also stripped (PSAvoidTrailingWhitespace enabled in
		the formatter settings, Invoke-Formatter genuinely fixes this rather
		than just reporting it) - a permanent part of every format pass from here on, not a one-off
		cleanup.

		!! ENCODING - detects the file's current BOM state and writes it back the same way,
		rather than always adding a BOM (PSScriptAnalyzer's own formatter output otherwise
		gets written BOM-ful regardless of the source file's original state, which silently
		changes a no-BOM file's encoding and makes it look modified to source control for no
		reason).

		SAFETY GUARD - a formatter hiccup on certain inputs (a multi-line C# string embedded via
		Add-Type, seen in the wild) can make Invoke-Formatter silently return an EMPTY string
		instead of throwing. Writing that straight to disk with zero validation would destroy the
		file. This function refuses to overwrite a non-trivial file with drastically less content
		than it started with - REFUSED, not silently corrupted.

		.PARAMETER Path
		One or more .ps1/.psm1 files. Accepts pipeline input, so a Get-ChildItem sweep works.

		.PARAMETER Check
		Report whether the file WOULD change, without writing. Returns 1 if any file is not
		already formatted.

		.EXAMPLE
		PSHG-FormatPS1File -Path .\MyScript.ps1

		.EXAMPLE
		Get-ChildItem .\MyProject -Filter *.ps1 -Recurse | PSHG-FormatPS1File -Check

		.NOTES
		Returns 0 = done (or already formatted), 1 = -Check found unformatted files (or a file
		failed/was refused - including a file that is not valid UTF-8, which is left unchanged), 2 = PSScriptAnalyzer missing (wrap the call in
		`PSHG-FormatPS1File ...; exit $LASTEXITCODE` for a process exit code).
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
		Justification = 'Console reporter, consistent with the other functions in this toolkit.')]
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[Alias('FullName')]
		[String[]]$Path,

		[Switch]$Check
	)

	Begin
	{
		$Script:FormatQueue   = New-Object System.Collections.Generic.List[String]
		$Script:Changed = 0
		$Script:Failed  = 0
		$Script:BadPSSA = $false

		if (-not (Get-Command Invoke-Formatter -ErrorAction SilentlyContinue))
		{
			try { Import-Module PSScriptAnalyzer -ErrorAction Stop }
			catch
			{
				Write-Host 'ERROR: PSScriptAnalyzer is not available - cannot format.' -ForegroundColor Red
				$Script:BadPSSA = $true
			}
		}

		$Script:Settings = @{
			Rules = @{
				PSUseConsistentIndentation = @{
					Enable          = $true
					Kind            = 'tab'
					IndentationSize = 1
				}
				# Invoke-Formatter genuinely strips trailing whitespace when this
				# is enabled (verified in-memory, no files involved) - not just a reporting-only rule.
				PSAvoidTrailingWhitespace  = @{
					Enable = $true
				}
			}
		}

		function Test-PSHGHasBom
		{
			Param ([Parameter(Mandatory)][String]$File)
			$bytes = [Byte[]]::new(3)
			$stream = [System.IO.File]::OpenRead($File)
			try { $null = $stream.Read($bytes, 0, 3) } finally { $stream.Close() }
			return ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
		}
	}

	Process
	{
		foreach ($item in $Path) { [void]$Script:FormatQueue.Add($item) }
	}

	End
	{
		if ($Script:BadPSSA) { $Global:LASTEXITCODE = 2; return }

		foreach ($file in $Script:FormatQueue)
		{
			if (-not (Test-Path -LiteralPath $file -PathType Leaf))
			{
				Write-Host ('SKIP (not found): {0}' -f $file) -ForegroundColor DarkGray
				continue
			}

			# Strict UTF-8 decode: a genuinely-ANSI file would otherwise be read with U+FFFD replacement
			# characters and permanently corrupted on write-back. Refuse it instead (NEEDS-REVIEW territory).
			try
			{
				$strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
				$original = $strictUtf8.GetString([System.IO.File]::ReadAllBytes($file))
				if ($original.Length -gt 0 -and $original[0] -eq [char]0xFEFF) { $original = $original.Substring(1) }
			}
			catch
			{
				$Script:Failed++
				Write-Host ('REFUSED {0}: not valid UTF-8 (genuinely ANSI?) - file left UNCHANGED, needs manual review' -f (Split-Path $file -Leaf)) -ForegroundColor Red
				continue
			}
			try { $formatted = Invoke-Formatter -ScriptDefinition $original -Settings $Script:Settings }
			catch
			{
				$Script:Failed++
				Write-Host ('FAILED  {0}: {1}' -f (Split-Path $file -Leaf), $_.Exception.Message) -ForegroundColor Red
				continue
			}

			if ($formatted -ceq $original)
			{
				Write-Host ('ok      {0}' -f (Split-Path $file -Leaf)) -ForegroundColor DarkGray
				continue
			}

			# SAFETY GUARD - see the DESCRIPTION above. Refuse to overwrite a non-trivial file with
			# drastically less content than it started with.
			if ([String]::IsNullOrEmpty($formatted) -or ($original.Length -gt 50 -and $formatted.Length -lt ($original.Length * 0.5)))
			{
				$Script:Failed++
				Write-Host ('REFUSED {0}: formatter output looks wrong (input {1} char(s), output {2} char(s)) - file left UNCHANGED' -f (Split-Path $file -Leaf), $original.Length, $formatted.Length) -ForegroundColor Red
				continue
			}

			$Script:Changed++
			if ($Check)
			{
				Write-Host ('WOULD   {0}' -f (Split-Path $file -Leaf)) -ForegroundColor Yellow
				continue
			}

			# Preserve the file's existing BOM state - see the ENCODING note in the DESCRIPTION.
			$encoding = New-Object System.Text.UTF8Encoding((Test-PSHGHasBom -File $file))
			Write-PSHGFileAtomic -Path $file -Bytes ([Byte[]]($encoding.GetPreamble() + $encoding.GetBytes($formatted)))
			Write-Host ('FORMAT  {0}' -f (Split-Path $file -Leaf)) -ForegroundColor Green
		}

		Write-Host ''
		Write-Host ('=== {0} file(s), {1} {2}, {3} failed ===' -f $Script:FormatQueue.Count, $Script:Changed,
			$(if ($Check) { 'would change' } else { 'formatted' }), $Script:Failed) -ForegroundColor Magenta

		if ($Script:Failed -gt 0) { $Global:LASTEXITCODE = 1; return }
		if ($Check -and $Script:Changed -gt 0) { $Global:LASTEXITCODE = 1; return }
		$Global:LASTEXITCODE = 0; return
	}
}
