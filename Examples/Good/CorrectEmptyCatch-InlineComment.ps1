<#
	Resolution 2 of 3 for the empty-catch anti-pattern: INLINE REASON COMMENT.
	A different mechanism from the SuppressMessageAttribute resolution, not a stylistic variant
	of it - use this when the reason belongs right next to the code rather than in an attribute
	above the whole function (e.g. only ONE of several catch blocks in a function is empty, so a
	function-level attribute would be too broad).

	Compare against ..\Bad\SilentEmptyCatch.ps1 and the other two resolutions:
	  CorrectEmptyCatch-Suppressed.ps1
	  CorrectEmptyCatch-ActuallyHandled.ps1
#>
Function Stop-BackgroundJob
{
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Illustrative fixture for the empty-catch anti-pattern, not real production code - stopping the job is the explicit purpose, not a side effect.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
		Justification = 'Deliberately empty - this fixture specifically demonstrates the "# SILENT-OK:" inline-comment resolution pattern (a race with the job self-stopping), not the SuppressMessageAttribute resolution shown in the sibling fixture. PSSA''s own rule does not recognize the inline-comment convention, only PSHygieneGuard''s own checker does; suppressing here just documents that PSSA''s finding is expected, without changing what the fixture teaches.')]
	Param ([System.Management.Automation.Job]$Job)

	Try
	{
		$Job.StopJob()
	}
	Catch
	{
		# SILENT-OK: StopJob() throws if the job already finished on its own between our
		# earlier state check and this call - a race, not a defect. Nothing to do; the job is
		# already stopped either way.
	}
}
