Function PSHG-TestGetNewClosureScope
{
	<#
		.SYNOPSIS
		Finds a PLAIN variable or a bare NESTED-FUNCTION call inside a `.GetNewClosure()`'d
		scriptblock that is not genuinely local to the closure's own immediately-enclosing
		scope - the broader, sibling checker to PSHG-TestGetNewClosurePrivateScope (which only
		catches `$Private:`-prefixed variables). Deliberately kept as its OWN function so it
		can be run independently if it turns out too noisy in practice.

		.DESCRIPTION
		`{ ... }.GetNewClosure()` snapshots ONLY the variables present in the IMMEDIATE local
		scope at the moment `.GetNewClosure()` is called. It does NOT walk further up the
		lexical/dynamic scope chain the way an ordinary variable reference does, and nested
		`function Foo { ... }` definitions are likewise invisible by bare name inside the
		closure - both fail SILENTLY (no error, no warning, the value just reads as unset / the
		command as unrecognized only at the point of actual use, often much later when the
		closure finally runs).

		The fix discipline this checker looks for the absence of: copy every needed reference
		into a plain local variable immediately before `.GetNewClosure()` is called, and invoke
		any needed nested function via a captured scriptblock reference
		(`$FooSB = ${function:Foo}`, then `& $FooSB` inside) instead of a bare name.

		Two independent checks per `.GetNewClosure()` site:
		  1. VARIABLE: any plain (non-`Private:`/`Script:`/`Global:`/`Using:`, non-automatic)
		     variable referenced inside the closure that is not itself assigned within the
		     closure AND is not found among the variable assignments/parameters of the
		     closure's own IMMEDIATE enclosing scriptblock (the scope `.GetNewClosure()` is
		     actually called from - not the whole ancestor chain, matching the confirmed
		     "immediate scope only" capture behaviour).
		  2. NESTED FUNCTION: any bare command call inside the closure whose name matches a
		     `function Name { ... }` defined elsewhere in the SAME FILE - nested functions are
		     invisible inside a closure regardless of nesting depth, the same as `$Private:`
		     variables, so this needs no "immediate scope only" nuance the way plain variables
		     do.

		`$Script:`/`$Global:` variables are NEVER flagged - those are not scope-relative to the
		closure at all, they resolve the same way regardless of where/how the scriptblock runs.
		`$Private:` variables are deliberately EXCLUDED here too (PSHG-TestGetNewClosurePrivateScope
		already covers them) to avoid duplicate reporting between the two checkers.

		Uses the PowerShell language parser's AST directly ([Parser]::ParseFile), not
		PSScriptAnalyzer - no PSSA dependency, so this also runs on machines where PSSA is not
		installed.

		NOISE WARNING: unlike the sibling `$Private:` checker (where every reference inside a
		closure is unconditionally wrong, zero exceptions), this broader check has more surface
		for a legitimate miss - e.g. a variable this checker cannot prove is automatic/well-known,
		or a same-named nested function that is genuinely unrelated to the one being called. No
		baseline mechanism either way - review findings directly each time, without an
		"always trust every finding" guarantee.

		.PARAMETER Path
		File or directory to scan (recurses). Defaults to the current directory.

		.PARAMETER KnownSafePrefixPattern
		Optional regex (case-sensitive, `-cmatch`). Any variable base name matching it is never
		flagged - use this if your codebase has its own convention for variables that are
		exported into persistent module/script scope under a distinctive name prefix and so
		correctly survive `.GetNewClosure()` despite looking "plain." Not set by default.

		.EXAMPLE
		PSHG-TestGetNewClosureScope

		.EXAMPLE
		PSHG-TestGetNewClosureScope -Path 'C:\MyProject\SomeFile.ps1'

		.NOTES
		Returns 0 = clean, 1 = at least one finding, 2 = no findings but at least one file could not be read
		or parsed (listed; NOT a clean result). Scans .ps1 and .psm1. Wrap the call in
		`PSHG-TestGetNewClosureScope ...; exit $LASTEXITCODE` for a process exit code.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console report is the entire purpose of this function (matches this toolkit''s convention)')]
	[CmdletBinding()]
	Param (
		[String]$Path = $PWD.ProviderPath,
		[String]$KnownSafePrefixPattern
	)

	# Well-known automatic/preference variables - never flagged even when not "locally assigned",
	# since these are always available regardless of scope/closure mechanics.
	$Script:AutoVars = [System.Collections.Generic.HashSet[String]]::new([StringComparer]::OrdinalIgnoreCase)
	@(
		'_', 'PSItem', 'args', 'input', 'true', 'false', 'null',
		'Error', 'MyInvocation', 'PSCmdlet', 'PSBoundParameters', 'PSScriptRoot', 'PSCommandPath',
		'ExecutionContext', 'Host', 'PID', 'HOME', 'PWD', 'this',
		'ErrorActionPreference', 'VerbosePreference', 'DebugPreference', 'WarningPreference',
		'ConfirmPreference', 'WhatIfPreference', 'ProgressPreference', 'InformationPreference',
		'Matches', 'LASTEXITCODE', 'StackTrace'
	) | ForEach-Object { $null = $Script:AutoVars.Add($_) }

	If (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: [{0}]' -f $Path) }
	$Private:Root = (Resolve-Path -LiteralPath $Path).ProviderPath

	$ExcludePattern = '\\Original(s)?\\|\\_RetiredModules\\|\\\.git\\'

	$Skipped = [System.Collections.Generic.List[String]]::new()
	$Files = @(Get-PSHGScanFile -Path $Private:Root -ExcludePattern $ExcludePattern -Problem $Skipped)

	Write-Host ('Scanning {0} file(s) for GetNewClosure() scope-capture risks (plain variables + bare nested-function calls)...' -f $Files.Count) -ForegroundColor Cyan

	# Names a variable's own VariablePath resolves to when locally assigned in a scope - includes
	# Param-block parameter names and every LHS-of-assignment name found DIRECTLY in that scope (not
	# descending into further-nested scriptblocks, matching GetNewClosure's own "immediate scope only"
	# capture behaviour).
	Function Get-PSHGDirectScopeVariableSet
	{
		Param ([System.Management.Automation.Language.Ast]$ScopeNode)

		$Names = [System.Collections.Generic.HashSet[String]]::new([StringComparer]::OrdinalIgnoreCase)

		$Private:_paramBlock = $null
		If ($ScopeNode -is [System.Management.Automation.Language.ScriptBlockAst]) { $Private:_paramBlock = $ScopeNode.ParamBlock }
		ElseIf ($ScopeNode -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $Private:_paramBlock = $ScopeNode.Body.ParamBlock }
		If ($Private:_paramBlock)
		{
			ForEach ($Private:_p in $Private:_paramBlock.Parameters)
			{ $null = $Names.Add($Private:_p.Name.VariablePath.UserPath) }
		}

		$Private:_assigns = $ScopeNode.FindAll(
			{
				Param($N)
				$N -is [System.Management.Automation.Language.AssignmentStatementAst] -and
				$N.Left -is [System.Management.Automation.Language.VariableExpressionAst]
			}, $false)   # searchNestedScriptBlocks=$false - stay within THIS scope only
		ForEach ($Private:_a in $Private:_assigns)
		{ $null = $Names.Add($Private:_a.Left.VariablePath.UserPath) }

		# ForEach loop variables (`ForEach ($C in $Collection) { ... }`) are genuinely local to the loop
		# - PowerShell does not represent the loop variable declaration as an AssignmentStatementAst, so
		# the pass above misses it entirely.
		$Private:_forEaches = $ScopeNode.FindAll(
			{ Param($N) $N -is [System.Management.Automation.Language.ForEachStatementAst] }, $false)
		ForEach ($Private:_fe in $Private:_forEaches)
		{ $null = $Names.Add($Private:_fe.Variable.VariablePath.UserPath) }

		# Unary comma REQUIRED - HashSet[String] implements IEnumerable, so a bare `return $Names`
		# auto-unrolls it into its individual string elements (PowerShell's standard pipeline-unrolling
		# behaviour for any IEnumerable), silently turning the caller's single-HashSet assignment into
		# an Object[] (or a bare String, for a one-element set) instead.
		return ,$Names
	}

	$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()
	$Private:Escaped = [Regex]::Escape($Private:Root)

	ForEach ($File in $Files)
	{
		$Private:_parsed = Read-PSHGAst -File $File
		If (-not $Private:_parsed.Ok)
		{ $Skipped.Add(('{0} ({1})' -f $File, $Private:_parsed.Reason)); If (-not $Private:_parsed.Ast) { Continue } }   # a partial tree is still scanned
		$Private:_ast = $Private:_parsed.Ast

		# Every `function Name { ... }` defined anywhere in this file - used for the nested-function check.
		$Private:_fnDefs = $Private:_ast.FindAll(
			{ Param($N) $N -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
		$Private:_fnNames = [System.Collections.Generic.HashSet[String]]::new([StringComparer]::OrdinalIgnoreCase)
		ForEach ($Private:_fd in $Private:_fnDefs) { $null = $Private:_fnNames.Add($Private:_fd.Name) }

		# Every base name assigned via $Script:Name/$Global:Name ANYWHERE in the file - a PLAIN
		# reference to a $Script:-scoped variable correctly survives .GetNewClosure() capture even
		# nested several levels deep, because it resolves through the persistent script scope, not a
		# transient per-invocation local one - unlike an ordinary function-local variable.
		$Private:_scriptScopedAssigns = $Private:_ast.FindAll(
			{
				Param($N)
				$N -is [System.Management.Automation.Language.AssignmentStatementAst] -and
				$N.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
				($N.Left.VariablePath.IsScript -or $N.Left.VariablePath.IsGlobal)
			}, $true)
		$Private:_scriptScopedNames = [System.Collections.Generic.HashSet[String]]::new([StringComparer]::OrdinalIgnoreCase)
		ForEach ($Private:_ssa in $Private:_scriptScopedAssigns) { $null = $Private:_scriptScopedNames.Add(($Private:_ssa.Left.VariablePath.UserPath -replace '^(?i:Script|Global):', '')) }   # parser leaves DriveName empty for scope modifiers; strip the 'Script:' prefix from UserPath

		$Private:_invokes = $Private:_ast.FindAll(
			{
				Param($N)
				$N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
				$N.Member.Value -ieq 'GetNewClosure' -and
				$N.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
			}, $true)

		ForEach ($Private:_invoke in $Private:_invokes)
		{
			$Private:_sb = $Private:_invoke.Expression.ScriptBlock

			# Immediate enclosing scope - the first ScriptBlockAst ancestor STRICTLY ABOVE the invoke
			# node (i.e. the scope .GetNewClosure() is actually called FROM, not the closure's own body).
			$Private:_container = $Private:_invoke.Parent
			While ($Private:_container -and -not ($Private:_container -is [System.Management.Automation.Language.ScriptBlockAst]))
			{ $Private:_container = $Private:_container.Parent }
			If (-not $Private:_container) { Continue }   # could not resolve - skip rather than guess

			$Private:_containerLocal = Get-PSHGDirectScopeVariableSet -ScopeNode $Private:_container
			$Private:_closureLocal   = Get-PSHGDirectScopeVariableSet -ScopeNode $Private:_sb

			# --- Check 1: plain variables not locally available ---
			# searchNestedScriptBlocks=$false - a FURTHER-nested .GetNewClosure() site inside this one
			# gets its own, separate analysis via this same outer ForEach loop.
			$Private:_varRefs = $Private:_sb.FindAll(
				{ Param($N) $N -is [System.Management.Automation.Language.VariableExpressionAst] }, $false)
			ForEach ($Private:_v in $Private:_varRefs)
			{
				$Private:_name = $Private:_v.VariablePath.UserPath
				# $Script:/$Global: carry IsScript/IsGlobal (DriveName is empty for them); $using:X has UserPath 'X' (no scope info) and is wrapped in a UsingExpressionAst only when it stands alone ($using:X.Prop / $using:X[0] are not), so the written form is tested too.
				If ($Private:_v.VariablePath.IsScript -or $Private:_v.VariablePath.IsGlobal -or $Private:_v.Parent -is [System.Management.Automation.Language.UsingExpressionAst] -or $Private:_v.Extent.Text -imatch '^\$\{?using:') { Continue }
				If ($Private:_name -imatch '^Private:') { Continue }   # covered by the sibling checker
				If ($Script:AutoVars.Contains($Private:_name)) { Continue }
				If ($KnownSafePrefixPattern -and $Private:_name -cmatch $KnownSafePrefixPattern) { Continue }
				If ($Private:_scriptScopedNames.Contains($Private:_name)) { Continue }
				If ($Private:_closureLocal.Contains($Private:_name)) { Continue }
				If ($Private:_containerLocal.Contains($Private:_name)) { Continue }

				$Rel = $File -replace ('^{0}\\' -f $Private:Escaped), ''
				$Findings.Add([PSCustomObject]@{
						File = $Rel
						Line = $Private:_v.Extent.StartLineNumber
						Kind = 'Variable'
						Text = $Private:_v.Extent.Text
					})
			}

			# --- Check 2: bare calls to a nested function defined elsewhere in this file ---
			If ($Private:_fnNames.Count -gt 0)
			{
				$Private:_cmds = $Private:_sb.FindAll(
					{ Param($N) $N -is [System.Management.Automation.Language.CommandAst] }, $false)
				ForEach ($Private:_c in $Private:_cmds)
				{
					$Private:_cmdName = $Private:_c.GetCommandName()
					If ($Private:_cmdName -and $Private:_fnNames.Contains($Private:_cmdName))
					{
						$Rel = $File -replace ('^{0}\\' -f $Private:Escaped), ''
						$Findings.Add([PSCustomObject]@{
								File = $Rel
								Line = $Private:_c.Extent.StartLineNumber
								Kind = 'NestedFunction'
								Text = $Private:_c.Extent.Text
							})
					}
				}
			}
		}
	}

	$Findings = @($Findings | Sort-Object File, Line, Kind, Text -Unique)

	Write-PSHGSkipReport -Skipped $Skipped

	If ($Findings.Count -eq 0)
	{
		If ($Skipped.Count -gt 0)
		{ Write-Host ('NOT CLEAN - no findings, but {0} file(s) were not checked.' -f $Skipped.Count) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
		Write-Host 'PASS - no GetNewClosure() scope-capture risks found.' -ForegroundColor Green
		$Global:LASTEXITCODE = 0; return
	}

	Write-Host ''
	ForEach ($F in $Findings)
	{
		Write-Host ('  {0}:{1} [{2}]' -f $F.File, $F.Line, $F.Kind) -ForegroundColor Red
		Write-Host ('    {0}' -f $F.Text) -ForegroundColor DarkGray
		If ($F.Kind -eq 'Variable')
		{ Write-Host '    Fix: copy into a plain local variable immediately before .GetNewClosure() and reference that instead.' -ForegroundColor Yellow }
		Else
		{ Write-Host '    Fix: capture as $FooSB = ${function:Name} before .GetNewClosure(), invoke via & $FooSB inside.' -ForegroundColor Yellow }
	}
	Write-Host ''
	Write-Host ('FAIL - {0} finding(s). Review each - see this function''s own NOISE WARNING before treating every hit as certain.' -f $Findings.Count) -ForegroundColor Red
	$Global:LASTEXITCODE = 1; return
}
