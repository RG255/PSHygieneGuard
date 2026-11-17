<#
	Correct resolution: build the path from $env:ProgramFiles, which resolves correctly for
	the CURRENT process (32-bit vs 64-bit) and system drive.

	Compare against ..\Bad\HardcodedProgramFiles.ps1
#>
Function Get-ToolExePath
{
	return (Join-Path $env:ProgramFiles 'MyTool\tool.exe')
}
