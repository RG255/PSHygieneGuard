<#
	Correct resolution: build the path from $env:APPDATA (or $HOME/$env:USERPROFILE for the
	profile root), which resolves correctly for whichever user actually runs the script.

	Compare against ..\Bad\HardcodedUserProfilePath.ps1
#>
Function Get-UserConfigPath
{
	return (Join-Path $env:APPDATA 'MyApp\config.json')
}
