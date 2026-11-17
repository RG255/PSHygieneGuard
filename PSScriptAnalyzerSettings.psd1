# PSScriptAnalyzer settings for this module. PSScriptAnalyzer auto-discovers this file when scanning
# from (or below) this folder, so a plain `Invoke-ScriptAnalyzer -Recurse` run picks these up
# automatically - unlike a repo-level accepted-findings baseline (see PSHG-TestRepoLint),
# which is per-project and never ships alongside the module.
#
# Three kinds of exclusion below, for three different reasons - see each comment.
@{
	ExcludeRules = @(
		# --- Parser noise, not real findings -------------------------------------------------
		# PSScriptAnalyzer parses each file in isolation, so a type introduced by a `using
		# namespace`/`using module` statement elsewhere is not visible yet at parse time. This
		# fires the rule below on every reference to such a type, even though the code is
		# correct and works at runtime (PSHG-TestRepoLint filters the identical set for the same reason).
		'TypeNotFound',
		'MemberAlreadyDefined',
		'AmbiguousTypeReference',

		# --- Also parser noise: a plain DATA .psd1 mistaken for a module manifest ------------
		# PSHygieneGuardBaseline\ErrorHandling-Baseline.psd1 (and similar) is a plain hashtable
		# data file, not a module manifest - it has no RootModule, no exports, nothing a real
		# manifest needs. PSScriptAnalyzer's manifest-field check fires on ANY .psd1 regardless,
		# demanding a ModuleVersion field that has no meaning here.
		'PSMissingModuleManifestField',

		# --- Deliberate style choice, not accepted debt --------------------------------------
		# Write-Host is used throughout this module's interactive console output by design
		# (colored status text a human is meant to read directly) - not an oversight.
		'PSAvoidUsingWriteHost'
	)
}
