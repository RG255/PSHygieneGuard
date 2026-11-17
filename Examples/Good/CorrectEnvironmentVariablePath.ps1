<#
	Correct resolution: build the path from the environment variable, which resolves
	correctly regardless of system drive, redirection, or process bitness.

	Compare against ..\Bad\HardcodedWindowsPath.ps1
#>
Function Get-AppConfigPath
{
	return (Join-Path $env:ProgramData 'MyApp\config.json')
}
