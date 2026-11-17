<#
	Resolution 1 of 3 for the empty-catch anti-pattern: SUPPRESSED WITH JUSTIFICATION.
	Use this when the empty catch is genuinely fine - a narrow, specific exception type that
	really is safe to ignore, with a real reason recorded right where a reviewer will see it.
	This is the pattern PSHG-InvokeSilentFailureSweep's own baseline entries use for a real
	"BY DESIGN" acceptance - see Examples\Baselining\SampleBaselineEntry.psd1.

	Compare against ..\Bad\SilentEmptyCatch.ps1 and the other two resolutions:
	  CorrectEmptyCatch-InlineComment.ps1
	  CorrectEmptyCatch-ActuallyHandled.ps1
#>
Function Remove-TempFile
{
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '',
		Justification = 'IOException here means only "already deleted" - genuinely nothing to do. A locked file or permissions problem throws a DIFFERENT exception type and is not caught here, so it still propagates.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Illustrative fixture for the empty-catch anti-pattern, not real production code - deletion is the explicit purpose, not a side effect.')]
	Param ([String]$Path)

	Try
	{
		Remove-Item -Path $Path -Force -ErrorAction Stop
	}
	Catch [System.IO.FileNotFoundException]
	{
		# Already gone - the caller's goal ("this file should not exist") is already satisfied.
	}
}
