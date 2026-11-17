<#
	Correct resolution: build the path from ${env:ProgramFiles(x86)} - the curly-brace form
	is REQUIRED because the variable name itself contains parentheses, which $env:Name syntax
	cannot parse directly.

	Compare against ..\Bad\HardcodedProgramFilesX86.ps1
#>
Function Get-LegacyToolExePath
{
	return (Join-Path ${env:ProgramFiles(x86)} 'LegacyTool\tool.exe')
}
