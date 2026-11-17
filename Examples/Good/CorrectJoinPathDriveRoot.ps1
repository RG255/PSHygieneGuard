<#
	Correct: build the path for a drive that may not be mounted yet with the .NET path API, which only
	concatenates strings. Join-Path resolves the drive through PowerShell's provider system first and throws
	"Cannot find drive. A drive with the name 'X' does not exist." when it is not a live PSDrive - for example a
	USB drive plugged in after the session started, or an unmounted VHD.

	A Join-Path on a variable-built drive root is only acceptable when the drive is known to exist; say so on
	the same line with the marker comment shown in the last function, and PSHG-TestJoinPathDriveRoot skips it.
#>
Function Get-BackupFolderPath
{
	Param ([String]$Letter, [String]$RelativePath)

	[System.IO.Path]::Combine(('{0}:\' -f $Letter), $RelativePath)
}

Function Get-SubFolder
{
	Param ([String]$Base, [String]$Name)

	# A path that merely arrives in a variable is not judged by the checker.
	Join-Path -Path $Base -ChildPath $Name
}

Function Get-FolderOnKnownDrive
{
	Param ([String]$RelativePath)

	Join-Path -Path ('{0}:\' -f $env:SystemDrive.TrimEnd(':')) -ChildPath $RelativePath # PSHG-OK: JoinPathDriveRoot - the system drive always exists
}
