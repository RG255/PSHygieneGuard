<#
	Correct resolution: build the path from $env:PUBLIC, which resolves correctly regardless
	of which drive Windows and the user profiles are installed on.

	Compare against ..\Bad\HardcodedUsersPublicPath.ps1
#>
Function Get-SharedDesktopPath
{
	return (Join-Path $env:PUBLIC 'Desktop')
}
