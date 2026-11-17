<#
	Correct resolution: build the path from $env:windir (or $env:SystemRoot, equivalent),
	which resolves correctly regardless of which drive Windows is installed on.

	Compare against ..\Bad\HardcodedWindowsFolder.ps1
#>
Function Get-System32Path
{
	return (Join-Path $env:windir 'System32')
}
