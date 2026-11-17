#
# Internal helpers shared by the PSHG-* functions. Dot-sourced with the rest of Functions\ but not
# listed in FunctionsToExport, so they are not part of the public surface.
#

# Source files under Path (one file, or a folder searched recursively), minus ExcludePattern.
# Enumeration problems (an unreadable folder) are added to -Problem so the caller can report them.
Function Get-PSHGScanFile
{
	[CmdletBinding()]
	[OutputType([String[]])]
	Param (
		[Parameter(Mandatory)][String]$Path,
		[String]$ExcludePattern = '',
		[String[]]$Extension = @('.ps1', '.psm1'),
		[System.Collections.Generic.List[String]]$Problem
	)

	If (Test-Path -LiteralPath $Path -PathType Leaf)
	{ $Private:All = @((Resolve-Path -LiteralPath $Path).ProviderPath) }
	Else
	{
		$EnumErrors = $null
		$Private:All = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue -ErrorVariable EnumErrors |
				Where-Object { $_.Extension -in $Extension } | Select-Object -ExpandProperty FullName)
		If ($Problem)
		{
			ForEach ($Private:_e in $EnumErrors)
			{ $Problem.Add(('{0} (cannot enumerate: {1})' -f $Private:_e.TargetObject, $Private:_e.Exception.Message)) }
		}
	}
	If ($ExcludePattern) { $Private:All = @($Private:All | Where-Object { $_ -notmatch $ExcludePattern }) }
	return @($Private:All | Sort-Object -Unique)
}

# Parses one file. Ok is false when the file cannot be read or has a real parse error, so the caller can count it
# as NOT CHECKED. A type-resolution error alone (a class that names a sibling type from another file) is not an
# error here: the tree is complete and the file is checked. TypeNotFound is matched by ErrorId, not by message text.
Function Read-PSHGAst
{
	[CmdletBinding()]
	Param ([Parameter(Mandatory)][String]$File)

	$Private:Tokens = $null
	$Private:Errs   = $null
	Try
	{ $Private:Ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$Private:Tokens, [ref]$Private:Errs) }
	Catch
	{ return [PSCustomObject]@{ File = $File; Ok = $false; Ast = $null; Tokens = $null; Reason = ('cannot read: {0}' -f $_.Exception.Message) } }

	$Private:Blocking = @($Private:Errs | Where-Object { $_.ErrorId -ne 'TypeNotFound' })
	If ($Private:Blocking.Count -gt 0)
	{
		return [PSCustomObject]@{
			File = $File; Ok = $false; Ast = $Private:Ast; Tokens = $Private:Tokens
			Reason = ('parse error at line {0}: {1}' -f $Private:Blocking[0].Extent.StartLineNumber, $Private:Blocking[0].Message)
		}
	}
	return [PSCustomObject]@{ File = $File; Ok = $true; Ast = $Private:Ast; Tokens = $Private:Tokens; Reason = '' }
}

# Prints the NOT CHECKED list. A run with entries here is not a clean result.
Function Write-PSHGSkipReport
{
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console reporter, consistent with the other functions in this toolkit.')]
	[CmdletBinding()]
	Param ([System.Collections.Generic.List[String]]$Skipped)

	If (-not $Skipped -or $Skipped.Count -eq 0) { return }
	Write-Host ''
	Write-Host ('NOT CHECKED - {0} file(s) could not be read or parsed, so this run is NOT a clean result:' -f $Skipped.Count) -ForegroundColor Red
	ForEach ($Private:_s in $Skipped) { Write-Host ('  {0}' -f $Private:_s) -ForegroundColor Red }
}

# Replaces a file's bytes through a temp file in the same folder, so an interrupted write never leaves a half-written file.
Function Write-PSHGFileAtomic
{
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory)][String]$Path,
		[Parameter(Mandatory)][Byte[]]$Bytes
	)

	$Private:Full = [System.IO.Path]::GetFullPath($Path)
	$Private:Temp = '{0}.pshg-{1}.tmp' -f $Private:Full, [guid]::NewGuid().ToString('N')
	Try
	{
		[System.IO.File]::WriteAllBytes($Private:Temp, $Bytes)
		If (Test-Path -LiteralPath $Private:Full)
		{ [System.IO.File]::Replace($Private:Temp, $Private:Full, [NullString]::Value) }
		Else
		{ [System.IO.File]::Move($Private:Temp, $Private:Full) }
	}
	Finally
	{
		If (Test-Path -LiteralPath $Private:Temp) { Remove-Item -LiteralPath $Private:Temp -Force -ErrorAction SilentlyContinue }
	}
}
