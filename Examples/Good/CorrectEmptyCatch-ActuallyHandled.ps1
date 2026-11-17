<#
	Resolution 3 of 3 for the empty-catch anti-pattern: ACTUALLY FIXED.
	Sometimes an empty catch isn't a legitimate "safe to ignore" case at all - it's a genuine
	defect, and the correct outcome isn't to justify the silence, it's to stop being silent.

	Compare against ..\Bad\SilentEmptyCatch.ps1 and the other two resolutions:
	  CorrectEmptyCatch-Suppressed.ps1
	  CorrectEmptyCatch-InlineComment.ps1
#>
Function Remove-TempFile
{
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Illustrative fixture for the empty-catch anti-pattern, not real production code - deletion is the explicit purpose, not a side effect.')]
	Param ([String]$Path)

	Try
	{
		Remove-Item -Path $Path -Force -ErrorAction Stop
	}
	Catch
	{
		# A locked file or a permissions problem is a REAL failure the caller needs to know
		# about - report it and let it propagate, don't swallow it.
		Write-Error ('Could not remove [{0}]: {1}' -f $Path, $_.Exception.Message)
	}
}
