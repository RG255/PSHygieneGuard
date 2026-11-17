<#
	Correct resolution: gate on the mount TYPE rather than pattern-matching the path text at
	all - this is the "usually fine" shape PSHG-FindDriveLetterAssumption's own docs call out
	(a lettered lookup that falls back to a letter-less one), and it triggers none of the
	checker's literal drive-letter-regex patterns because there is no regex here to find.

	Compare against ..\Bad\DriveLetterUnanchored.ps1
#>
Function Test-IsDriveLetterMount
{
	Param ([String]$MountType)

	return $MountType -ieq 'D'
}
