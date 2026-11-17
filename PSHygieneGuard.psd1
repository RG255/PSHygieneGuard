@{
	RootModule        = 'PSHygieneGuard.psm1'
	ModuleVersion     = '0.1'
	GUID              = '5255e3d1-88bb-46af-a0aa-e727f1cee16f'
	Author            = 'RG255, with Claude (Anthropic)'
	Copyright         = '(c) 2026 RG255. MIT License.'
	Description       = 'PowerShell hygiene toolkit: baseline-gated lint, encoding enforcement, silent-failure detection, and AST-based checkers for defect classes that parse cleanly and pass PSScriptAnalyzer but fail silently at runtime.'
	PowerShellVersion = '5.0'

	FunctionsToExport = @(
		'PSHG-TestScriptSyntax'
		'PSHG-TestFileEncoding'
		'PSHG-TestBareKeywordCommand'
		'PSHG-TestFinallyThrow'
		'PSHG-TestGetNewClosureScope'
		'PSHG-TestGetNewClosurePrivateScope'
		'PSHG-FormatPS1File'
		'PSHG-FindDriveLetterAssumption'
		'PSHG-TestModuleVersionSelfReference'
		'PSHG-InvokeSilentFailureSweep'
		'PSHG-TestRepoLint'
		'PSHG-TestScriptErrorHandling'
		'PSHG-FindHardcodedWindowsPath'
		'PSHG-TestJoinPathDriveRoot'
		'PSHG-TestTypographicQuoteEscape'
		'PSHG-TestUnescapedLiteral'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags       = @('PowerShell', 'Lint', 'CodeQuality', 'PSScriptAnalyzer', 'Pester')
			LicenseUri = 'https://github.com/RG255/PSHygieneGuard/blob/master/LICENSE'
			ProjectUri = 'https://github.com/RG255/PSHygieneGuard'

			# Declared but NOT in RequiredModules: PSScriptAnalyzer is a deliberate SOFT
			# dependency - every checker that uses it degrades gracefully (a distinct return
			# code, not a crash) when it is absent, rather than blocking Import-Module outright.
			# Pester is a TEST-ONLY dependency, never imported by the module's own code, so it
			# does not belong in RequiredModules either. Both are pinned here for discoverability
			# and by PowerShellGet's dependency reporting; see README.md's Requirements section
			# for exact install commands.
			ExternalModuleDependencies = @('PSScriptAnalyzer', 'Pester')
		}
	}

	RequiredModules = @()
}
