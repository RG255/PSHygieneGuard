<#
	Correct resolution: wrap in $(...), the subexpression operator, so the If/Else is
	evaluated as a STATEMENT producing a value, not misparsed as a command invocation.

	Compare against ..\Bad\BareKeywordMisparse.ps1 - only the parens changed.
#>
Function Get-StatusLabel
{
	Param ([Bool]$IsHealthy)

	$Label = $(If ($IsHealthy) { 'OK' } Else { 'FAILED' })
	return $Label
}
