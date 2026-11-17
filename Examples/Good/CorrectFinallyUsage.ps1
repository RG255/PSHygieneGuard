<#
	Correct resolution: a genuine "re-raise the original exception" belongs in the Catch
	block, where it only fires when there actually was one - never in Finally, which fires
	on every exit path regardless.

	Compare against ..\Bad\ThrowInsideFinally.ps1
#>
Function Invoke-Cleanup
{
	Param ([String]$ResourceId)

	Try
	{
		Disconnect-Resource -Id $ResourceId
	}
	Catch
	{
		Write-Error ('Disconnect failed for [{0}]: {1}' -f $ResourceId, $_.Exception.Message)
		throw
	}
	Finally
	{
		Write-Verbose ('Cleanup attempted for [{0}]' -f $ResourceId)
	}
}
