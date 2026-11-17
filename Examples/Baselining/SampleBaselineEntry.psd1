<#
	One fully-worked, realistic baseline entry, annotated - this is what a REAL entry in
	PSHygieneGuardBaseline\RepoLint-Baseline.psd1 looks like after step 4 of README.md in this
	folder (replacing the -UpdateBaseline-generated TODO placeholder with a real reason).

	This file is NOT itself a real baseline - it's a reference sample, never loaded by any
	checker. Compare it against the placeholder your own -UpdateBaseline run generates.
#>
@{
	Accepted = @(
		# Key shape: RuleName|RelativePath|FunctionName
		#
		# A GOOD reason states: what the finding actually is, why it's safe (or that it was
		# fixed and this entry is now stale and should be removed), and how that was verified -
		# not just "reviewed, fine".
		'PSUseShouldProcessForStateChangingFunctions|Src\Remove-CacheEntry.ps1|Remove-CacheEntry'
	)

	# What the VALUE for that key should look like (a real baseline maps key -> reason string;
	# this sample keeps it separate purely so the annotation above stays readable):
	#
	# 'PSUseShouldProcessForStateChangingFunctions|Src\Remove-CacheEntry.ps1|Remove-CacheEntry' =
	#     'BY DESIGN, verified 2026-09-02. Remove-CacheEntry only ever clears an IN-MEMORY
	#     hashtable entry (a process-local cache), never anything durable - there is no real
	#     "undo" a -WhatIf/-Confirm gate would meaningfully protect, and every call site already
	#     checks Test-Path against the cache key before calling this. Confirmed by reading every
	#     one of its 3 call sites directly.'
}
