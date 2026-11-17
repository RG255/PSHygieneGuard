<#
	Correct resolution: rename to a plain (non-Private:) variable, which .GetNewClosure()
	correctly captures.

	Compare against ..\Bad\ClosurePrivateScopeCapture.ps1
#>
Function New-ClickHandler
{
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
		Justification = 'Illustrative fixture for .GetNewClosure() variable-capture scope, not real production code - "New" here means constructs a scriptblock value, not a system-state change.')]
	Param ([String]$Label)

	$Message = 'Clicked: {0}' -f $Label

	return { Write-Host $Message }.GetNewClosure()
}
