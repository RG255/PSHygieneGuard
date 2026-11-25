Function PSHG-TestScriptErrorHandling
{
	<#
	    .SYNOPSIS
	    Audits a .ps1 for the silent-failure anti-patterns - code that makes a FAILED
	    operation report SUCCESS.

	    .DESCRIPTION
	    Two passes.

	    STATIC SCAN (always) - flags the silent-failure patterns listed below (reported as AP1, AP2, ...;
	    AP6w is the advisory variant). Each was verified by test, not reasoned about:

	      1. A scriptblock-invoking wrapper with try/catch but no $ErrorActionPreference='Stop'.
	         Cmdlets fail NON-TERMINATING by default, so the catch never fires and
	         $LASTEXITCODE stays 0. The failure is completely invisible.
	      2. Native tools (secedit/auditpol/wevtutil/gpupdate/reg/dism/robocopy) fail by EXIT
	         CODE and never throw - needs an explicit $LASTEXITCODE check.
	      3. '2>$null' on a native command. Under EAP=Stop this makes a SUCCESSFUL command
	         throw; under EAP=Continue it hides the real error message. Wrong either way.
	      4. 'if ($obj.Prop -eq ...) {} else { <reassuring message> }' where $obj may be null -
	         asserts a state that was never actually checked.
	      5. 'return' in a guard clause of a -File script - exits the PROCESS with code 0, so a
	         scheduled task reads a refusal as success. SUPPRESSED for library files (nothing but
	         function definitions) and for any 'return' inside a function, where it is correct.
	      6. A catch that prints, signals failure by NO means, and lets execution CONTINUE to a
	         normal return - so the caller cannot tell success from failure. (Re-scoped:
	         this used to be "prints but never records", which assumed a -File script with a
	         failure collector and wrongly flagged library code that correctly throws. Use
	         -IncludeWeak to also see catches that signal nothing but have nothing following them.)
	      7. Empty catch blocks.
	      8. Error text emitted to the OUTPUT stream ('ERROR: ...' as a bare statement) inside a
	         function - a caller assigning the result receives the error text AS the result.
	      9. (AP12) A catch that signals the IMMEDIATE caller via Write-Error only, with no
	         durable record behind it (no throw, no recognized collector/-KnownSignalFunction
	         call, no readback value/property). Genuinely reaches a caller that is checking right
	         then, but leaves nothing to find afterward if this runs headlessly/on a schedule and
	         nobody was watching. Write-Error already satisfies the general "does this signal at
	         all" test (see Test-CatchHasDurableSignal / Test-CatchHasStreamOnlySignal below), so
	         these were never caught by AP6/AP7/AP9; AP12 targets exactly that gap.

	    DYNAMIC TEST (-TestWrapper) - AST-extracts the named wrapper function plus its failure
	    collector from the target script and actually EXERCISES them, asserting both directions:
	    things that MUST be detected, and things that must NOT be flagged. The false-positive
	    half is what catches anti-pattern 3, which is created by fixing anti-pattern 1.

	    Testing the extracted real function beats eyeballing: it is the shipped code, not a copy.

	    !! SECURITY: -TestWrapper EXECUTES code taken from the file being scanned. The wrapper and
	    collector function bodies are copied out of the target and run in the current session, so
	    use it only on files you trust. The static scan never runs the target.

	    .PARAMETER Path
	    The .ps1 to audit. Accepts pipeline input, so a Get-ChildItem sweep works.

	    .PARAMETER TestWrapper
	    Also run the dynamic pass. Requires -WrapperName to exist in the file. Runs code from the
	    scanned file (see the SECURITY note in the description): trusted files only.

	    .PARAMETER WrapperName
	    Name of the scriptblock-invoking wrapper. Default 'Invoke-Native'.

	    .PARAMETER CollectorName
	    Name of the failure-recording function the wrapper calls. Default 'Add-Failure'. Used ONLY
	    by -TestWrapper's dynamic exercise - not related to -KnownSignalFunction below.

	    .PARAMETER KnownSignalFunction
	    One or more function names that, if called inside a catch body, count as genuinely
	    SIGNALING the failure - same as a real throw/Write-Error - even though this checker cannot
	    otherwise see what they do. Point this at YOUR OWN codebase's audit-trail/logging
	    function(s). Not set by default - nothing is silently trusted.

	    .PARAMETER Quiet
	    Only report findings; suppress the per-check PASS lines.

	    .PARAMETER Csv
	    Also write every finding to this path as CSV.

	    .PARAMETER IncludeWeak
	    Also report 'AP6w' - catches that print and signal nothing, but where nothing follows in
	    scope. Advisory; off by default.

	    .PARAMETER RepoRoot
	    Root the baseline's relative paths are computed from. Defaults to the current directory (so
	    a fresh clone works with zero configuration when run from the repo root), but any caller
	    that cannot guarantee its own working directory - an orchestrator, a scheduled task, a
	    wrapper invoked from an unpredictable CWD - should pass this explicitly. Same reasoning, and
	    the exact same fix, as PSHG-TestRepoLint's own -RepoRoot (see its own doc): without an
	    explicit root, a caller whose shell happens to
	    be sitting somewhere else silently mismatches every baseline entry.
	    Baseline keys use a path relative to this root, so a baseline stays valid when the repo is cloned or
	    moved elsewhere.

	    .EXAMPLE
	    PSHG-TestScriptErrorHandling -Path .\Deploy.ps1 -TestWrapper

	    .EXAMPLE
	    Get-ChildItem .\Modules -Recurse -Filter *.ps1 | PSHG-TestScriptErrorHandling
	    Static sweep of every module script.

	    .NOTES
	    Exit codes: 0 = no findings and every file checked, 1 = findings, 2 = no findings but at least one file
	    was NOT checked (missing, unreadable, or a parse error), or the baseline could not be read, or
	    -UpdateBaseline was given without -Baseline. Skipped files are listed and each raises a warning
	    (so they survive 6>$null); a run that skipped files is never reported as clean.

	    -UpdateBaseline requires -Baseline <file>: the baseline shipped inside the module is an empty template and is
	    never written. WrapperName and CollectorName must be plain function names.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Quiet',
		Justification = 'Read by the nested Write-Pass helper via script scope - PSSA cannot see through the nested function. Runtime-verified.')]
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'KnownSignalFunction',
		Justification = 'Read by the nested Test-CatchSignal helper via script scope - same PSSA limitation as Quiet above. Runtime-verified.')]
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[Alias('FullName')]
		[String[]]$Path,

		[Switch]$TestWrapper,
		[ValidatePattern('^[A-Za-z_][A-Za-z0-9_-]*$')]
		[String]$WrapperName   = 'Invoke-Native',
		[ValidatePattern('^[A-Za-z_][A-Za-z0-9_-]*$')]
		[String]$CollectorName = 'Add-Failure',
		# SEPARATE from CollectorName on purpose - CollectorName names the ONE specific failure
		# collector -TestWrapper extracts and dynamically exercises; this is an unrelated, general
		# STATIC-detection list. One or more function names that, if called inside a catch body,
		# count as genuinely SIGNALING the failure - same as a real throw/Write-Error - even though
		# this checker cannot otherwise see what they do. Point this at YOUR OWN codebase's
		# audit-trail/logging function(s); nothing is recognized by default, and nothing
		# repo-specific is hardcoded here.
		[String[]]$KnownSignalFunction = @(),
		[Switch]$Quiet,

		# Write every finding to a CSV. The interactive view uses Write-Host,
		# which goes to the INFORMATION stream - a sweep capturing with '2>&1' collects NOTHING
		# and cheerfully reports zero findings for every module. Findings are now
		# also emitted as OBJECTS to the success stream so the tool composes; -Csv is the
		# no-thinking-required version.
		[String]$Csv,

		# Report the weak AP6 candidates too (catch prints, no error signal, but nothing
		# demonstrably follows it). Off by default - they are advisory, not defects.
		[Switch]$IncludeWeak,

		# Accepted-findings file (Rule|Path|Function|Hash = 'why it is accepted'). Findings whose
		# key matches are suppressed. Defaults to Tools\ErrorHandling-Baseline.psd1 when present.
		[String]$Baseline,

		# Rewrite the baseline from the CURRENT findings, preserving existing reasons. Mirrors
		# PSHG-TestRepoLint -UpdateBaseline.
		[Switch]$UpdateBaseline,

		# With -UpdateBaseline, also DELETE entries that matched nothing this run (what -ShowAccepted
		# lists as 'unmatched'). Without it, -UpdateBaseline only ever grows the file, so entries whose
		# code was fixed or reformatted accumulate for ever.
		#
		# Pruning is scoped to the files actually SCANNED, and that is the whole point of the switch
		# rather than a hand-rolled loop. A stale key is one the scan COULD have matched and did not;
		# an entry for a file outside this run is simply out of scope and is always kept. Getting this
		# wrong is easy and expensive: an ad-hoc prune loop can treat the checker's output
		# as 'everything that exists', when with a baseline active it is only what remained UNSUPPRESSED
		# - so it deletes every correctly-judged entry and the baseline size swings from run to run.
		# AcceptedSeen (populated for suppressed findings too) is what makes the
		# distinction the ad-hoc loop could not.
		[Switch]$PruneStale,

		# Also list what the baseline suppressed, and any entries that no longer match anything.
		[Switch]$ShowAccepted,

		[String]$RepoRoot
	)

	Begin
	{
		If (-not $RepoRoot) { $RepoRoot = $PWD.ProviderPath }
		$RepoRoot = $RepoRoot.TrimEnd('\', '/')

		# !! Work happens in End, NOT Process. Under 'powershell.exe -File' the PROCESS BLOCK
		# NEVER RUNS - verified, and true whether or not the parameter declares
		# ValueFromPipeline. Only -Command / & invocation drives Process. CLAUDE.md mandates
		# -File, so Process only QUEUES; End seeds from the bound -Path and does the work.
		$Script:ScanQueue         = New-Object System.Collections.Generic.List[String]
		$Script:TotalFindings = 0
		$Script:Findings      = New-Object System.Collections.Generic.List[Object]
		$Script:CurrentFile   = ''
		$Script:SourceLines   = $null

		$Script:SuppressedInline   = 0
		$Script:SuppressedBaseline = 0
		$Script:Accepted     = @{}
		$Script:AcceptedSeen = New-Object System.Collections.Generic.HashSet[String]

		# Files this run actually parsed. -PruneStale needs it to distinguish a baseline entry the scan
		# looked for and did not find (stale) from one for a file it never opened (out of scope).
		$Script:ScannedFiles = New-Object System.Collections.Generic.List[String]

		# Files this run could not check (missing, unreadable, parse error). Any entry makes the run NOT clean (exit 2).
		$Script:Skipped      = New-Object System.Collections.Generic.List[String]
		$Script:RootWarned   = $false

		# ABORT FLAG - checked at the top of End. This function's original (pre-module) form was a
		# standalone .ps1 that used `exit 2` here to refuse to run on an unreadable baseline. In a
		# FUNCTION, `return` inside Begin does NOT abort the function - it only ends the Begin block,
		# and Process/End still run. Every helper function below is defined LATER in this same Begin
		# block, so an early `return` here left them undefined and End then failed with a cascade of
		# "The term 'Get-EnclosingFunction' is not recognized" (a DIFFERENT helper each run, depending
		# where execution reached first), and it cost a long
		# hunt because the real cause (the baseline read failing) is reported via Write-Host, which
		# callers routinely suppress with 6>$null. A flag that End checks is what actually aborts.
		$Script:AbortRun = $false

		$Script:BaselinePath = if ($Baseline) { $Baseline }
		else { Join-Path (Split-Path $PSScriptRoot -Parent) 'PSHygieneGuardBaseline\ErrorHandling-Baseline.psd1' }

		# The shipped baseline is an empty template shared by every project on the machine: never write to it.
		if ($UpdateBaseline -and -not $Baseline)
		{
			Write-Host 'REFUSED: -UpdateBaseline needs an explicit -Baseline <your project baseline file>; the baseline shipped inside the module is a read-only template.' -ForegroundColor Red
			Write-Warning 'PSHG-TestScriptErrorHandling: -UpdateBaseline requires -Baseline (the module''s own template is never written).'
			$Script:AbortRun = $true
			return
		}
		if (Test-Path -LiteralPath $Script:BaselinePath)
		{
			try
			{
				# AST-based load, NOT Import-PowerShellDataFile. That cmdlet evaluates the file via
				# ScriptBlockAst.SafeGetValue(), which has a HARD 500-ENTRY CAP on a hashtable -
				# measured exactly: 500 entries load fine, 501 throws "Cannot generate a
				# PowerShell object for a ScriptBlock evaluating dynamic expressions" (a thoroughly
				# misleading message - the data is 100% static string constants and parses cleanly).
				# A baseline is an APPEND-MOSTLY file, so it WILL cross 500 eventually and then stop
				# loading, silently, for ever. Reading the AST directly has no such ceiling.
				$Private:_bErrs = $null
				$Private:_bAst = [System.Management.Automation.Language.Parser]::ParseFile(
					$Script:BaselinePath, [ref]$null, [ref]$Private:_bErrs)
				if ($Private:_bErrs.Count -gt 0)
				{ throw ('baseline has {0} parse error(s), first: {1}' -f $Private:_bErrs.Count, $Private:_bErrs[0].Message) }

				$Private:_bHash = @($Private:_bAst.FindAll(
						{ Param($N) $N -is [System.Management.Automation.Language.HashtableAst] }, $true))[0]
				if (-not $Private:_bHash) { throw 'baseline contains no hashtable' }

				foreach ($Private:_kv in $Private:_bHash.KeyValuePairs)
				{
					$Private:_k = $Private:_kv.Item1
					if ($Private:_k -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
					# The value side is a statement (PipelineAst) wrapping the real expression.
					$Private:_v = $Private:_kv.Item2
					if ($Private:_v -is [System.Management.Automation.Language.PipelineAst] -and
						$Private:_v.PipelineElements.Count -gt 0)
					{ $Private:_v = $Private:_v.PipelineElements[0].Expression }
					if ($Private:_v -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
					$Script:Accepted[$Private:_k.Value] = [String]$Private:_v.Value
				}
			}
			catch
			{
				# Refuse to run blind: a corrupt baseline silently accepting nothing would look like
				# a pile of new findings, and one silently accepting everything is worse.
				# Write-Error (not just Write-Host) so this survives a caller's 6>$null - the whole
				# reason this failure was invisible for so long is that the ONLY report of it went to
				# the information stream, which the sweep suppresses.
				Write-Host ('ERROR reading baseline {0}: {1}' -f $Script:BaselinePath, $_.Exception.Message) -ForegroundColor Red
				Write-Error ('PSHG-TestScriptErrorHandling: cannot read baseline [{0}]: {1}' -f $Script:BaselinePath, $_.Exception.Message)
				$Script:AbortRun = $true
				return
			}
		}

		# Baseline key: Rule | version-agnostic relative path | function | content hash.
		#
		#  - NO line number: editing above a finding must not resurrect it (the RepoLint lesson).
		#  - Version-agnostic path: '\0.5\' -> '\<ver>\'. Without this, a version bump re-keys every
		#    verdict (every accepted entry for that module would lapse).
		#  - CONTENT HASH: this is what a plain suppression list cannot do. These verdicts are about
		#    INTENT ("this catch swallows deliberately"), which is only valid for the code as judged.
		#    Hashing the construct means an edit LAPSES the acceptance and the finding returns for
		#    re-triage, instead of silently covering code nobody has looked at.
		function Get-FindingKey
		{
			Param ([String]$Rule, [String]$File, [String]$Function, [String]$Context)

			# $RepoRoot (outer function parameter, defaulted above) - NOT a hardcoded repo name.
			# Do not strip a literal repo folder name here: that only works for a repo that happens to have
			# that exact name, and anyone else's baseline keys would get the FULL ABSOLUTE PATH baked in.
			$Rel = $File -replace ('^{0}\\' -f [Regex]::Escape($RepoRoot)), ''
			# A file outside RepoRoot gets an absolute-path key that no portable baseline entry can match.
			if ($Rel -eq $File -and -not $Script:RootWarned)
			{
				$Script:RootWarned = $true
				Write-Warning ('PSHG-TestScriptErrorHandling: [{0}] is outside -RepoRoot [{1}], so its baseline key holds an absolute path and will not match a baseline written elsewhere. Pass -RepoRoot.' -f $File, $RepoRoot)
			}
			$Rel = $Rel -replace '[\\/]\d+\.\d+[\\/]', '\<ver>\'

			$Norm = ($Context -replace '\s+', ' ').Trim()
			$Hash = if ($Norm)
			{
				$Sha = [System.Security.Cryptography.SHA256]::Create()
				try
				{
					$Bytes = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Norm))
					(($Bytes | Select-Object -First 4 | ForEach-Object { $_.ToString('X2') }) -join '')
				}
				finally { $Sha.Dispose() }
			}
			else { '--------' }

			'{0}|{1}|{2}|{3}' -f $Rule, $Rel, $(if ($Function) { $Function } else { '<file>' }), $Hash
		}

		function Write-Finding
		{
			Param ([Int]$Line, [String]$Rule, [String]$Text, [String]$Context = '', [String]$Function = '')

			# Inline opt-out, mirroring the SuppressMessageAttribute convention already used widely
			# elsewhere. Preferred over a baseline entry when the reason belongs WITH the code:
			#     # SILENT-OK: best-effort diagnostic write; must not fail the operation it logs.
			# Looked for on the finding line or the 3 lines above it.
			if ($Script:SourceLines -and $Line -gt 0)
			{
				$From = [Math]::Max(0, $Line - 4)
				$To   = [Math]::Min($Script:SourceLines.Count - 1, $Line - 1)
				if ($To -ge $From)
				{
					$Near = ($Script:SourceLines[$From..$To] -join "`n")
					if ($Near -match 'SILENT-OK')
					{
						$Script:SuppressedInline++
						return
					}
				}
			}

			$Key = Get-FindingKey -Rule $Rule -File $Script:CurrentFile -Function $Function -Context $Context
			if ($Script:Accepted.ContainsKey($Key))
			{
				[void]$Script:AcceptedSeen.Add($Key)

				# An entry whose reason is still TODO has NOT been judged by anyone, so it must keep
				# being REPORTED. Only a real, written reason suppresses.
				#
				# This matters because -UpdateBaseline seeds the file from EVERY current finding.
				# Seeding it once accepted all 157 while only 13 had been investigated - the sweep
				# then read "0 findings" while 144 unjudged items sat silently hidden, which is the
				# exact opposite of the point. The baseline exists so a SETTLED verdict is not
				# re-argued, not so an unread finding disappears.
				# ONLY a verdict that says the code is OK may hide it. Three kinds must stay visible:
				#   TODO         - nobody has judged it yet
				#   GENUINE LEAD - judged, and judged to be a REAL problem
				#   DEBATABLE    - judged, and not defensible without a decision
				# Writing "this is a genuine defect" into the reason and having that SILENCE the
				# finding is the same mistake as letting TODO silence it, one level up: a module could
				# report "0 findings" while still carrying unresolved genuine leads. A count is only useful
				# if everything still needing action is in it.
				$Verdict = $Script:Accepted[$Key]
				if ($Verdict -notlike 'TODO*' -and $Verdict -notmatch 'GENUINE LEAD|DEBATABLE')
				{
					$Script:SuppressedBaseline++
					return
				}
				$Tag  = if ($Verdict -like 'TODO*') { '[unjudged] ' } else { '[LEAD] ' }
				$Text = $Tag + $Text
			}

			$Script:TotalFindings++
			[void]$Script:Findings.Add([PSCustomObject]@{
					File = $Script:CurrentFile
					Line = $Line
					Rule = $Rule
					Text = $Text
					Key  = $Key
				})
			Write-Host ('  [{0}] line {1}: {2}' -f $Rule, $Line, $Text) -ForegroundColor Yellow
		}

		function Write-Pass
		{
			Param ([String]$Text)
			if (-not $Quiet) { Write-Host ('  [ok] {0}' -f $Text) -ForegroundColor DarkGray }
		}

		# ---------------------------------------------------------------------------
		# AST helpers
		# ---------------------------------------------------------------------------

		# The nearest enclosing function of any AST node, or $null at file scope.
		function Get-EnclosingFunction
		{
			Param ($Node)
			$p = $Node.Parent
			while ($p)
			{
				if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p }
				$p = $p.Parent
			}
			return $null
		}

		# AP7's own inline opt-out. The generic SILENT-OK lookback in Write-Finding only checks the
		# finding line and the 3 lines ABOVE it, which works for AP1-AP6/AP9 (whose finding line sits
		# near the reasoning), but a SILENT-OK comment inside a catch BODY naturally sits on the line
		# AFTER the 'catch' keyword the finding is reported on - so the generic window never sees it.
		# Checked directly against the catch's own body text instead, which has no such blind spot.
		function Test-CatchHasSilentOkComment
		{
			Param ([String]$Text)
			return $Text -match 'SILENT-OK'
		}

		# AP7's second recognized opt-out: a function-level SuppressMessageAttribute targeting
		# PSAvoidUsingEmptyCatchBlock with a real (non-blank) Justification - the exact convention
		# that is already common for other rules (e.g. PSUseShouldProcessForStateChangingFunctions),
		# just not previously recognized here. Attribute lives on the function's Param block, which is
		# where PowerShell attaches a bare attribute written directly above 'Param (...)'.
		function Test-FunctionSuppressesEmptyCatch
		{
			Param ($Function)
			if (-not $Function -or -not $Function.Body.ParamBlock) { return $false }
			foreach ($Attr in $Function.Body.ParamBlock.Attributes)
			{
				if ($Attr.TypeName.Name -notmatch 'SuppressMessageAttribute') { continue }
				$RuleArg = $Attr.PositionalArguments | Select-Object -First 1
				if (-not $RuleArg -or $RuleArg.Value -ne 'PSAvoidUsingEmptyCatchBlock') { continue }
				$JustArg = $Attr.NamedArguments | Where-Object { $_.ArgumentName -eq 'Justification' } | Select-Object -First 1
				if ($JustArg -and $JustArg.Argument.Value) { return $true }
			}
			return $false
		}

		# Unwraps a StatementAst down to the single CommandAst it represents, or $null if it is
		# not a single bare/assigned command call. Used by AP11 - a bare command-call
		# STATEMENT is itself a PipelineAst (even for one command), while `$x = Cmd` needs unwrapping
		# via .Right instead. Getting this wrong (checking for CommandAst directly) silently made
		# AP11 match nothing on its very first real test - verified against the AST, not assumed.
		function Get-SoleCommandAst
		{
			Param ($Statement)
			if ($Statement -is [System.Management.Automation.Language.CommandAst]) { return $Statement }
			if ($Statement -is [System.Management.Automation.Language.PipelineAst] -and
				$Statement.PipelineElements.Count -eq 1 -and
				$Statement.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst])
			{ return $Statement.PipelineElements[0] }
			if ($Statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
				$Statement.Right -is [System.Management.Automation.Language.PipelineAst] -and
				$Statement.Right.PipelineElements.Count -eq 1 -and
				$Statement.Right.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst])
			{ return $Statement.Right.PipelineElements[0] }
			return $null
		}

		# Does this catch body durably signal failure - i.e. by a means that does not depend on
		# someone watching a console at the moment of failure? Propagating the exception further
		# (throw/ThrowTerminatingError/exit/$PSCmdlet.), recording via a caller-recognized
		# collector/audit function, or writing into a value/property the caller reads back all
		# qualify; a bare Write-Error to the output stream does not (see Test-CatchHasStreamOnlySignal).
		function Test-CatchHasDurableSignal
		{
			Param ([String]$Text)
			# One alternation per configured collector/signal name, so more than one real "this
			# records the failure" function can be recognized in the same scan (see the
			# CollectorName / KnownSignalFunction param notes - two separate, unrelated params).
			$Private:CollectorPattern = @(@($CollectorName) + @($KnownSignalFunction) |
					Where-Object { $_ } | ForEach-Object { [Regex]::Escape($_) }) -join '|'
			return ($Text -match 'throw|ThrowTerminatingError|\bexit\b|\$PSCmdlet\.') -or
			($Text -match ('{0}|\.Add\(|\+=' -f $Private:CollectorPattern)) -or
			# Assignment to something that reads like a failure/success flag - BOTH a bare
			# variable ($Result = ...) AND a property-path assignment ($Result.State = ...). The
			# property-path form is a real, confirmed gap: a catch that sets $Result.SomeState =
			# 'Mismatch' genuinely IS a failure signal the caller reads back, but the bare-variable
			# pattern alone misses it because of the ".SomeState" between the variable and the "=".
			($Text -match '(?i)\$(\w+:)?\w*(fail|error|success|ok|result|status)\w*(\.\w+)?\s*=')
		}

		# Does this catch body signal failure via Write-Error - reaches the IMMEDIATE caller (the
		# error stream), but leaves no durable record for anyone not watching at that moment. See
		# AP12: this is the exact gap between "signals fine" and "signals durably".
		function Test-CatchHasStreamOnlySignal
		{
			Param ([String]$Text)
			return $Text -match 'Write-Error'
		}

		# Does this catch body SIGNAL failure to the caller by any means?
		# Deliberately generous: a false 'yes' costs a missed finding, a false 'no' costs
		# trust in the tool. Anything that could plausibly reach the caller counts.
		function Test-CatchSignal
		{
			Param ([String]$Text)
			return (Test-CatchHasDurableSignal -Text $Text) -or (Test-CatchHasStreamOnlySignal -Text $Text)
		}

		# Does the catch LEAVE the enclosing flow rather than falling through into it?
		# A catch that warns and then 'return $null' short-circuits: the caller gets $null
		# instead of the success-shaped object, so it CAN tell the call failed.
		# Counting the statements that merely FOLLOW the try/catch would flag such a catch as a
		# defect even though the catch never reaches them.
		function Test-CatchExitsFlow
		{
			Param ($Catch)
			$stmts = $Catch.Body.Statements
			foreach ($s in $stmts)
			{
				if ($s -is [System.Management.Automation.Language.ReturnStatementAst]) { return $true }
				if ($s -is [System.Management.Automation.Language.BreakStatementAst])  { return $true }
				if ($s -is [System.Management.Automation.Language.ContinueStatementAst]) { return $true }
			}
			return $false
		}

		# Is there any statement AFTER the try/catch inside the same enclosing function?
		# If so, execution demonstrably continues past the swallowed error toward a normal
		# return - which is what makes the caller unable to tell success from failure.
		function Test-ContinuesAfter
		{
			Param ($TryStatement)
			# A FUNCTION BODY's statements live in a NamedBlockAst (the implicit 'end' block),
			# NOT a StatementBlockAst - checking only for StatementBlockAst silently returned
			# $false for every catch directly inside a function, which is the common case and
			# made this whole check dead. Verified against the AST, not assumed.
			#
			# It does not stop at the Try's OWN IMMEDIATE parent block: a Try/Catch that is the LAST
			# statement inside an "If (...) { ... }" guard (a common shape) would otherwise be judged as
			# "does not continue" even though the function obviously continues once that If block ends,
			# and a silently swallowing catch there (e.g. "Catch { $null = $_ }") would be invisible to AP9.
			# So it walks UP through enclosing blocks (If/ElseIf/Else,
			# loop bodies, Try/Finally, etc.): if nothing follows in the immediate block, climb to the
			# statement that OWNS that block and check ITS siblings instead, repeating until either a
			# following statement is found (continues) or the top of the function/script body is
			# reached with nothing left to climb.
			#
			# "Reached the top with nothing left to climb" must not unconditionally return $true
			# ("falling off the end IS a silent continuation"): that would make a catch that is the very
			# LAST statement of its enclosing function indistinguishable from AP9's real target (silent
			# swallow with unrelated code continuing AFTER it), and would flag a best-effort cleanup catch
			# at a function's tail (which should not be flagged as AP6). This is symmetric with the
			# existing Test-InFinallyBlock exemption for the same "best-effort, nothing meaningfully
			# follows" shape, just without a Finally wrapper.
			#
			# Two DIFFERENT ways the loop can run out of places to climb, deliberately NOT collapsed
			# into one check: reaching a genuine FUNCTION/SCRIPT BOUNDARY (a FunctionDefinitionAst, or
			# a $null parent at the true top of a standalone script) confidently means nothing more
			# exists - "does not continue". An intermediate node that merely LACKS a .Statements
			# property for some OTHER, unanticipated AST shape is a different, uncertain case - stays
			# conservative ($true, flag it) rather than being silently folded into the same "safe"
			# bucket, since assuming "no more code" there could hide a real continuation this walk
			# simply failed to recognize. Verified this narrower fix does NOT affect any other
			# fixture: every other AP6/AP9-asserting fixture has an explicit statement after its
			# catch, so they all return via the $after check below, never either fallback.
			$node = $TryStatement
			while ($true)
			{
				$block = $node.Parent
				if ($null -eq $block -or $block -is [System.Management.Automation.Language.FunctionDefinitionAst])
				{ return $false }
				if ($null -eq $block.Statements) { return $true }
				$after = $block.Statements | Where-Object { $_.Extent.StartOffset -gt $node.Extent.EndOffset }
				if ($after | Select-Object -First 1) { return $true }
				$owner = $block.Parent
				if ($null -eq $owner) { return $false }
				$node = $owner
			}
		}

		# A file whose executable content is ONLY function definitions is a LIBRARY - it is
		# dot-sourced or imported, never run as an entry point. AP5 ('return' exits the process
		# with 0) is meaningless there, because 'return' is just a function return.
		function Test-IsLibraryFile
		{
			Param ($Ast)
			$top = $Ast.EndBlock.Statements | Where-Object {
				-not ($_ -is [System.Management.Automation.Language.FunctionDefinitionAst])
			}
			# Ignore bare attribute/using/param noise - anything else means it DOES run.
			$real = $top | Where-Object { $_.Extent.Text.Trim() -ne '' }
			return ($null -eq ($real | Select-Object -First 1))
		}

		# Is this function a genuine scriptblock-invoking WRAPPER - i.e. does it declare a
		# parameter actually TYPED [ScriptBlock]?
		#
		# The original test was a text match: body contains '[ScriptBlock]' AND matches '& $var'.
		# In a large file both appear somewhere by coincidence ([ScriptBlock]::Create, a cast, a
		# local variable, any '& $handler'), so the whole top-level function got flagged.
		# In practice many hits were functions that declare NO ScriptBlock parameter at all. Reading the AST for a
		# typed parameter is both cheaper and correct.
		function Test-IsScriptBlockWrapper
		{
			Param ($Function)
			$Params = $Function.Body.ParamBlock.Parameters
			if (-not $Params) { return $false }

			$Names = New-Object System.Collections.Generic.List[String]
			foreach ($P in $Params)
			{
				# The type can sit on the parameter itself or in its attribute list.
				if ($P.StaticType -and $P.StaticType.Name -eq 'ScriptBlock') { return $true }
				foreach ($A in $P.Attributes)
				{
					if ($A -is [System.Management.Automation.Language.TypeConstraintAst] -and
						$A.TypeName.Name -in 'ScriptBlock', 'System.Management.Automation.ScriptBlock')
					{ return $true }
				}
				[void]$Names.Add($P.Name.VariablePath.UserPath)
			}

			# UNTYPED parameter that is INVOKED with '&' is still a wrapper. Requiring a typed
			# parameter fixed 6 false positives but introduced this false negative (measured: 2 in
			# the live tree). Behaviour, not declaration, is what makes something a wrapper.
			foreach ($N in $Names)
			{
				if ($Function.Extent.Text -match ('&\s*\${0}\b' -f [Regex]::Escape($N))) { return $true }
			}
			return $false
		}

		# Is this catch inside a FINALLY block? Cleanup there is legitimately best-effort - a
		# teardown helper must never throw or prompt (a suppressed ShouldProcess/empty-catch is
		# the usual answer there). Typical shape: consecutive Dispose/catch pairs in a Finally.
		function Test-InFinallyBlock
		{
			Param ($Node)
			$Child = $Node
			$P = $Node.Parent
			while ($P)
			{
				if ($P -is [System.Management.Automation.Language.TryStatementAst] -and
					$P.Finally -and $Child -eq $P.Finally)
				{ return $true }
				$Child = $P
				$P = $P.Parent
			}
			return $false
		}

		# Does the catch write the failure into a variable the caller actually SEES - i.e. one
		# referenced again after the try/catch? Verified against InstalledInventory Get-HashMap.ps1:31,
		# 'Catch { $Hash = $Null }' followed by emitting @{ Path = $_; Hash = $Hash } - the $null IS
		# the reported failure. The named-flag regex in Test-CatchSignal missed it because the
		# variable is called 'Hash', not fail/error/status.
		function Test-CatchRecordsIntoResult
		{
			Param ($Catch, $TryStatement)
			$Assigned = $Catch.Body.FindAll({
					Param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]
				}, $true)
			if (-not $Assigned) { return $false }

			$Owner = Get-EnclosingFunction -Node $Catch
			$Scope = if ($Owner) { $Owner } else { $Catch.Parent }
			$EndOfTry = $TryStatement.Extent.EndOffset

			# The variable must ALSO be assigned inside the TRY - that is what makes it the value
			# the operation was computing, rather than incidental bookkeeping. Without this the
			# exclusion was far too permissive: 'catch { $Count = 0 }' suppressed the finding purely
			# because $Count happened to be used later.
			$TryAssigned = @($TryStatement.Body.FindAll({
						Param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]
					}, $true) | ForEach-Object { $_.Left.Extent.Text.TrimStart('$') })

			foreach ($A in $Assigned)
			{
				$Var = $A.Left.Extent.Text.TrimStart('$')
				if (-not $Var) { continue }
				if ($Var -notin $TryAssigned) { continue }
				$Used = $Scope.FindAll({
						Param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst]
					}, $true) | Where-Object {
					$_.VariablePath.UserPath -eq $Var -and $_.Extent.StartOffset -gt $EndOfTry
				}
				if ($Used) { return $true }
			}
			return $false
		}

		# Native tools that report failure ONLY via exit code.
		$Script:NativeTools = 'secedit', 'auditpol', 'wevtutil', 'gpupdate', 'reg', 'reg.exe',
		'dism', 'dism.exe', 'robocopy', 'icacls', 'netsh', 'schtasks',
		'bcdedit', 'manage-bde', 'takeown', 'sc.exe', 'certutil'
	}

	Process
	{
		foreach ($item in $Path) { [void]$Script:ScanQueue.Add($item) }
	}

	End
	{
		# Begin refused to run (unreadable baseline). MUST bail here: a `return` inside Begin only
		# ends Begin, so without this guard End would run with every helper function below still
		# undefined - see the ABORT FLAG note in Begin.
		if ($Script:AbortRun) { $Global:LASTEXITCODE = 2; return }

		# Pipeline input arrived via Process; an argument-bound -Path did not (see Begin).
		if ($Script:ScanQueue.Count -eq 0 -and $Path)
		{
			foreach ($item in $Path) { [void]$Script:ScanQueue.Add($item) }
		}

		foreach ($file in $Script:ScanQueue)
		{
			if (-not (Test-Path -LiteralPath $file -PathType Leaf))
			{
				$Script:Skipped.Add(('{0} (not a file)' -f $file))
				Write-Warning ('SKIPPED {0}: not a file' -f $file)
				continue
			}
			# Absolute path, so baseline keys are relative to RepoRoot however the file was named.
			$file = (Resolve-Path -LiteralPath $file).ProviderPath

			$src = $null
			try { $src = [System.IO.File]::ReadAllText($file) }
			catch
			{
				$Script:Skipped.Add(('{0} (cannot read: {1})' -f $file, $_.Exception.Message))
				Write-Warning ('SKIPPED {0}: cannot read: {1}' -f $file, $_.Exception.Message)
				continue
			}

			$parseErrors = $null
			$ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$parseErrors)
			# TypeNotFound alone is a class that names a sibling type from another file: the tree is complete, so scan it.
			$blockingErrors = @($parseErrors | Where-Object { $_.ErrorId -ne 'TypeNotFound' })
			if ($blockingErrors.Count -gt 0)
			{
				$Script:Skipped.Add(('{0} (parse error at line {1}: {2})' -f $file, $blockingErrors[0].Extent.StartLineNumber, $blockingErrors[0].Message))
				Write-Warning ('SKIPPED {0}: parse error at line {1}: {2}' -f $file, $blockingErrors[0].Extent.StartLineNumber, $blockingErrors[0].Message)
				continue
			}

			$before = $Script:TotalFindings
			$Script:CurrentFile = $file
			[void]$Script:ScannedFiles.Add($file)
			$Script:SourceLines = $src -split "`r?`n"
			Write-Host ''
			Write-Host ('=== {0} ===' -f (Split-Path $file -Leaf)) -ForegroundColor Cyan

			###########################################################################
			# 1 + 6 + 7 - catch blocks and scriptblock-invoking wrappers
			###########################################################################
			$funcs = $ast.FindAll({ Param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

			foreach ($fn in $funcs)
			{
				$body = $fn.Extent.Text

				# A wrapper DECLARES a [ScriptBlock] parameter (AST-checked, not text-matched)
				# and invokes it with '&'. See Test-IsScriptBlockWrapper for why the old text
				# match produced 6 false positives out of 11.
				$takesSb   = Test-IsScriptBlockWrapper -Function $fn
				$invokesSb = $body -match '&\s*\$\w+'
				if ($takesSb -and $invokesSb)
				{
					if ($body -notmatch '\$ErrorActionPreference\s*=\s*[''"]Stop[''"]')
					{
						Write-Finding $fn.Extent.StartLineNumber 'AP1' -Function $fn.Name -Context $fn.Body.ParamBlock.Extent.Text -Text `
						("wrapper '{0}' invokes a scriptblock but never sets `$ErrorActionPreference='Stop' - non-terminating cmdlet errors inside it are INVISIBLE" -f $fn.Name)
					}
					else { Write-Pass ("wrapper '{0}' sets EAP=Stop" -f $fn.Name) }

					if ($body -notmatch 'LASTEXITCODE')
					{
						Write-Finding $fn.Extent.StartLineNumber 'AP2' -Function $fn.Name -Context $fn.Body.ParamBlock.Extent.Text -Text `
						("wrapper '{0}' never checks `$LASTEXITCODE - native tool failures are invisible" -f $fn.Name)
					}
					else { Write-Pass ("wrapper '{0}' checks `$LASTEXITCODE" -f $fn.Name) }
				}
			}

			$catches = $ast.FindAll({ Param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true)
			foreach ($c in $catches)
			{
				$ctext = $c.Body.Extent.Text
				# Strip comments BEFORE testing for empty. The old test removed only whitespace and
				# braces, so 'catch { <# best effort #> }' read as NON-empty and escaped AP7 - while
				# also having no print, so it escaped AP6 too. Measured: 4 in the live tree.
				$inner = ($ctext -replace '(?s)<#.*?#>', '' -replace '(?m)#.*$', '' -replace '[\s{}]', '')
				if ($inner -eq '')
				{
					if (Test-CatchHasSilentOkComment -Text $ctext)
					{
						$Script:SuppressedInline++
						continue
					}
					if (Test-FunctionSuppressesEmptyCatch -Function (Get-EnclosingFunction -Node $c))
					{
						$Script:SuppressedInline++
						continue
					}
					Write-Finding $c.Extent.StartLineNumber 'AP7' -Function (Get-EnclosingFunction -Node $c).Name -Context $c.Parent.Extent.Text -Text 'empty catch block (or comment only) - the error is discarded entirely'
					continue
				}
				# AP6 scope: a simpler test was "prints but does not record", which
				# assumed the target was a -File script with a $Script:Failures collector and a
				# summary. In a MODULE FUNCTION there is no summary to record into - the correct
				# behaviour is to throw or Write-Error and let the CALLER decide. So that test
				# flagged many hits, most of them library code behaving reasonably.
				#
				# The question that actually matters: does this catch leave the caller unable to
				# tell success from failure? That needs BOTH
				#   (a) no failure signal of any kind, AND
				#   (b) execution demonstrably continuing on toward a normal return.
				# Write-Verbose/Write-Debug count as prints: both are genuinely opt-in-visibility
				# output (like Write-Information/Write-Host), not a report of "nothing happened" -
				# a Verbose-only catch was previously misclassified as AP9 ("SILENTLY swallows...no
				# output"), which is inaccurate. This does not eliminate the finding (still AP6 if nothing signals
				# the caller) - it only reclassifies it to the accurate rule.
				$prints = $ctext -match 'Write-Host|Write-Warning|Write-Output|Write-Information|Write-Verbose|Write-Debug'
				if (Test-CatchSignal -Text $ctext)
				{
					# AP12: signals the immediate caller via Write-Error only, with nothing durable
					# behind it - no throw, no recognized collector/audit call, no readback value.
					# Nobody watching the console at the moment of failure means nobody ever knows.
					if ((Test-CatchHasStreamOnlySignal -Text $ctext) -and -not (Test-CatchHasDurableSignal -Text $ctext))
					{
						$fnNameAp12 = (Get-EnclosingFunction -Node $c).Name
						Write-Finding $c.Extent.StartLineNumber 'AP12' -Function $fnNameAp12 -Context $c.Parent.Extent.Text -Text `
						("catch in '{0}' signals the immediate caller via Write-Error only - no durable record survives if nobody is watching when this runs headlessly/on a schedule" -f $fnNameAp12)
					}
					continue
				}
				if (Test-CatchExitsFlow -Catch $c) { continue }

				$tryStmt = $c.Parent
				$continues = Test-ContinuesAfter -TryStatement $tryStmt
				$fnName = (Get-EnclosingFunction -Node $c).Name
				$where  = if ($fnName) { "'$fnName'" } else { 'file scope' }

				if ($continues)
				{
					# Finally/records-into-result are UNIVERSAL exemptions - a legitimate teardown or
					# a result-recording catch is fine whether or not it also happens to print. These
					# must be checked BEFORE $prints, not after: checking $prints first (as this used
					# to) meant ANY printing catch skipped both exemptions unconditionally - a bug that
					# stayed invisible until Write-Verbose/Write-Debug were added to the prints regex; after that,
					# Finally-block cleanup catches (which very commonly log via Write-Verbose) were wrongly
					# flagged as AP6 findings.
					if (Test-InFinallyBlock -Node $c)
					{
						# Best-effort cleanup in a Finally - legitimate, never flag.
					}
					elseif (Test-CatchRecordsIntoResult -Catch $c -TryStatement $tryStmt)
					{
						# The failure IS written into a value the caller goes on to see.
					}
					elseif ($prints)
					{
						Write-Finding $c.Extent.StartLineNumber 'AP6' -Function $fnName -Context $c.Parent.Extent.Text -Text `
						("catch in {0} prints, signals nothing, and execution CONTINUES past it - the caller cannot tell this failed" -f $where)
					}
					else
					{
						# AP9, found by a FALSE-NEGATIVE audit. AP6 required a print and
						# AP7 required an empty body, so a catch that swallows SILENTLY but non-emptily
						# (e.g. 'catch { $null = $_ }') fell between the two and was invisible - despite
						# being the worse pattern, since not even the console shows anything.
						# Found only by asking what the tool MISSES rather than what it wrongly flags.
						Write-Finding $c.Extent.StartLineNumber 'AP9' -Function $fnName -Context $c.Parent.Extent.Text -Text `
						("catch in {0} SILENTLY swallows the error (no output, no signal) and execution CONTINUES - nothing anywhere records this failure" -f $where)
					}
				}
				elseif ($IncludeWeak)
				{
					Write-Finding $c.Extent.StartLineNumber 'AP6w' -Function $fnName -Context $c.Parent.Extent.Text -Text `
						'catch signals nothing, but nothing follows it in scope - advisory only'
				}
			}

			###########################################################################
			# 10 - native command invoked with NO $LASTEXITCODE check anywhere in scope
			###########################################################################
			# AP2 only ever fired INSIDE a scriptblock wrapper, so a native tool called anywhere
			# else was invisible - even though "native tools fail by exit code and never throw" is
			# anti-pattern 2 itself. Scoped to the enclosing function: if it calls a native tool and
			# NOWHERE references $LASTEXITCODE, no failure of that tool can be detected.
			# Robocopy is the classic - it needs an allow-list (0-7 are success), so a bare call
			# cannot be correct either way.
			$CommandAsts = $ast.FindAll({ Param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
			$ReportedFns = New-Object System.Collections.Generic.List[String]
			foreach ($Cmd in $CommandAsts)
			{
				$Name = $null
				try { $Name = $Cmd.GetCommandName() } catch { $Name = $null }
				if (-not $Name) { continue }
				$Bare = ($Name -replace '\.exe$', '').ToLower()
				if ($Bare -notin ($Script:NativeTools -replace '\.exe$', '').ToLower()) { continue }

				$Owner = Get-EnclosingFunction -Node $Cmd
				$Scope = if ($Owner) { $Owner.Extent.Text } else { $src }
				if ($Scope -match 'LASTEXITCODE') { continue }

				$Key = '{0}|{1}' -f $(if ($Owner) { $Owner.Name } else { '<file>' }), $Bare
				if ($ReportedFns -contains $Key) { continue }
				[void]$ReportedFns.Add($Key)

				$In = if ($Owner) { "'$($Owner.Name)'" } else { 'file scope' }
				Write-Finding $Cmd.Extent.StartLineNumber 'AP10' -Function $(if ($Owner) { $Owner.Name } else { '' }) -Context $Cmd.Extent.Text -Text `
				("native '{0}' called in {1} which never checks `$LASTEXITCODE - it fails by EXIT CODE and never throws, so the failure is invisible" -f $Name, $In)
			}

			###########################################################################
			# 11 - a risky cmdlet inside try/catch with NO way to reach 'Stop', followed
			# by an unconditional success message in the SAME try block
			###########################################################################
			# AP1 only ever fired for scriptblock-invoking WRAPPER functions (a function that
			# declares a [ScriptBlock] param and invokes it via '& $var'). A plain cmdlet call
			# sitting directly in a try - the far more common shape - fell outside AP1's net
			# even though it is the exact same underlying defect: without $ErrorActionPreference
			# = 'Stop' (locally or ambient), a non-terminating cmdlet failure never enters the
			# catch at all, so code that FOLLOWS in the same try - like a hardcoded success
			# message - runs regardless of whether the call actually succeeded.
			# Real-world shape: Register-ScheduledTask failed (invalid trigger duration), wrote nothing a
			# script-level $Error trap would have caught, and 'Scheduled task ... created' printed anyway -
			# the exact shape this rule targets. It was exposed by testing the change end-to-end, not by
			# this checker, so this rule gets the same must/must-not fixture rigor as every other one here.
			$Tries = $ast.FindAll({ Param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)
			foreach ($Try in $Tries)
			{
				$Owner = Get-EnclosingFunction -Node $Try
				$Scope = if ($Owner) { $Owner.Extent.Text } else { $src }
				if ($Scope -match '\$ErrorActionPreference\s*=\s*[''"]Stop[''"]') { continue }

				$Stmts = $Try.Body.Statements
				for ($i = 0; $i -lt $Stmts.Count - 1; $i++)
				{
					# A bare command-call statement is wrapped in a PipelineAst even for a single
					# command (only `$x = Cmd` needs unwrapping via .Right - a plain `Cmd` statement
					# is ITSELF a PipelineAst, not a CommandAst directly). Both shapes need unwrapping.
					$CmdAst = Get-SoleCommandAst -Statement $Stmts[$i]
					if (-not $CmdAst) { continue }

					$CmdName = $null
					try { $CmdName = $CmdAst.GetCommandName() } catch { $CmdName = $null }
					if (-not $CmdName) { continue }
					# Read-only verbs cannot manufacture a false SUCCESS story the way a mutating call can.
					# Write-* excluded too (it produced false positives on a first full-tree
					# run): it is pure console/stream output, not a state-changing call that can silently fail
					# non-terminating and let a bogus success message through - the hits were two
					# consecutive Write-Host/Write-Output lines where the FIRST was mistaken for the risky call.
					if ($CmdName -match '^(Get|Test|Read|Find|Search|Select|Compare|Measure|ConvertTo|ConvertFrom|Format|Show|Out|Write)-') { continue }
					if ($CmdAst.Extent.Text -match '-ErrorAction\s+(Stop|''Stop''|"Stop"|\[System\.Management\.Automation\.ActionPreference\]::Stop)') { continue }

					$NextCmdAst = Get-SoleCommandAst -Statement $Stmts[$i + 1]
					if (-not $NextCmdAst) { continue }
					$NextName = $null
					try { $NextName = $NextCmdAst.GetCommandName() } catch { $NextName = $null }
					if ($NextName -notmatch '^Write-(Host|Output|Information)$') { continue }
					if ($NextCmdAst.Extent.Text -notmatch '(?i)success|complete|created|installed|registered|done\b') { continue }

					$fnName = if ($Owner) { $Owner.Name } else { $null }
					$where  = if ($fnName) { "'$fnName'" } else { 'file scope' }
					Write-Finding $CmdAst.Extent.StartLineNumber 'AP11' -Function $fnName -Context $Try.Extent.Text -Text `
					("'{0}' in {1} has no -ErrorAction Stop and no ambient EAP=Stop, so a non-terminating failure skips the catch entirely - the success message on the next line prints regardless of whether it actually succeeded" -f $CmdName, $where)
				}
			}

			###########################################################################
			# 8 - error text emitted to the OUTPUT stream
			###########################################################################
			# Typical shape (surfaced by a misfiring AP5 hit):
			#
			#     'ERROR: Size, DaysOld, ... must be greater than zero'
			#     return
			#
			# A bare string statement goes to the SUCCESS stream, so a caller writing
			# '$Result = Invoke-Thing ...' receives the error TEXT as the result -
			# truthy, non-empty and indistinguishable from a real answer. Worse than the
			# pattern that led here.
			$pipelines = $ast.FindAll({
					Param($n) $n -is [System.Management.Automation.Language.PipelineAst]
				}, $true)
			foreach ($pl in $pipelines)
			{
				if ($pl.PipelineElements.Count -ne 1) { continue }
				$el = $pl.PipelineElements[0]
				if (-not ($el -is [System.Management.Automation.Language.CommandExpressionAst])) { continue }
				$expr = $el.Expression
				if (-not ($expr -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
						$expr -is [System.Management.Automation.Language.ExpandableStringExpressionAst])) { continue }
				# Must be a STATEMENT, not an argument or an assignment's right-hand side.
				# Accept NamedBlockAst too - a statement sitting directly in a function body
				# lives there, not in a StatementBlockAst (see Test-ContinuesAfter).
				if (-not ($pl.Parent -is [System.Management.Automation.Language.StatementBlockAst] -or
						$pl.Parent -is [System.Management.Automation.Language.NamedBlockAst])) { continue }
				# Require MESSAGE-shaped text: the keyword followed by punctuation, e.g.
				# 'ERROR: Size must be ...'. A bare word is not an error emission - the first
				# version of this check flagged  4 {'Failed'}  inside a switch that maps update
				# ResultCodes to status strings (InstalledInventory\Get-InstalledUpdate.ps1:47),
				# which is a perfectly correct value. Verified against that real file.
				if ($expr.Value -notmatch '^\s*(ERROR|FAILED|FATAL|WARNING)\s*[:!-]') { continue }

				$fn = Get-EnclosingFunction -Node $pl
				if (-not $fn) { continue }   # at file scope this is just console output
				Write-Finding $pl.Extent.StartLineNumber 'AP8' -Function $fn.Name -Context $pl.Extent.Text -Text `
				("error text emitted to the OUTPUT stream in '{0}' - a caller assigning the result gets this string AS the result; use throw or Write-Error" -f $fn.Name)
			}

			###########################################################################
			# 3 - stderr redirection near native commands
			###########################################################################
			$lines = $src -split "`r?`n"
			for ($i = 0; $i -lt $lines.Count; $i++)
			{
				$ln = $lines[$i]
				if ($ln -match '^\s*#') { continue }
				if ($ln -match '2>\s*\$null|2>&1')
				{
					foreach ($tool in $Script:NativeTools)
					{
						if ($ln -match ('(?i)\b{0}\b' -f [Regex]::Escape($tool)))
						{
							Write-Finding ($i + 1) 'AP3' -Context $ln -Text `
							("stderr redirected around native '{0}' - under EAP=Stop this makes a SUCCESSFUL command throw; otherwise it hides the real message" -f $tool)
							break
						}
					}
				}
			}

			###########################################################################
			# 4 - null-property comparison with a reassuring else
			###########################################################################
			$ifs = $ast.FindAll({ Param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true)
			foreach ($if in $ifs)
			{
				if (-not $if.ElseClause) { continue }
				$cond = $if.Clauses[0].Item1.Extent.Text
				# condition dereferences a property of a variable and compares it
				if ($cond -notmatch '\$\w+\.\w+\s*-(eq|ne|match|like)') { continue }
				$elseText = $if.ElseClause.Extent.Text
				if ($elseText -notmatch '(?i)already|no\s|not\s|none|disabled|clean|ok\b|safe') { continue }

				# Not a finding if the variable is explicitly null-guarded just above. Look back
				# a few lines for a '$null -eq $thatVar' (or a .Count/-not guard) on the SAME
				# variable - otherwise a correctly-defended block gets flagged forever and the
				# tool trains people to ignore it.
				$varName = ([Regex]::Match($cond, '\$(\w+)\.')).Groups[1].Value
				$guarded = $false
				if ($varName)
				{
					$from  = [Math]::Max(0, $if.Extent.StartLineNumber - 12)
					$ahead = ($lines[$from..([Math]::Max($from, $if.Extent.StartLineNumber - 1))] -join "`n")
					$guarded = $ahead -match ('(?i)\$null\s*-eq\s*\${0}\b|-not\s*\${0}\b|\${0}\s*-eq\s*\$null' -f [Regex]::Escape($varName))
				}
				if ($guarded)
				{
					Write-Pass ('null-guarded property comparison at line {0}' -f $if.Extent.StartLineNumber)
					continue
				}

				Write-Finding $if.Extent.StartLineNumber 'AP4' -Function (Get-EnclosingFunction -Node $if).Name -Context $cond -Text `
				('property comparison with a reassuring else-branch: if the object is null the else fires and ASSERTS a state never checked -> {0}' -f $cond.Trim())
			}

			###########################################################################
			# 5 - return in a guard clause (only meaningful for -File entry-point scripts)
			###########################################################################
			# SUPPRESSED for library files. AP5 is about a -File script exiting the
			# PROCESS with code 0. Inside a module function 'return' is an ordinary function
			# return and is correct - the hits seen were function-scope false positives.
			# A file containing nothing but function definitions is never an entry point.
			if (Test-IsLibraryFile -Ast $ast)
			{
				Write-Pass 'library file (functions only) - AP5 not applicable'
			}
			else
			{
				for ($i = 1; $i -lt $lines.Count; $i++)
				{
					if ($lines[$i] -notmatch '^\s*return\s*$') { continue }
					$ctx = ($lines[[Math]::Max(0, $i - 4)..($i)] -join ' ')
					if ($ctx -match '(?i)ERROR:|Aborted|must be run as Administrator|REFUSING')
					{
						# Still not a finding if this 'return' is inside a function - only
						# top-level guard clauses exit the process.
						$atLine = $i + 1
						$inFunc = $funcs | Where-Object {
							$_.Extent.StartLineNumber -le $atLine -and $_.Extent.EndLineNumber -ge $atLine
						} | Select-Object -First 1
						if ($inFunc) { continue }

						Write-Finding $atLine 'AP5' -Context $lines[$i] -Text `
							'guard clause uses "return" - a -File run exits with code 0, so a caller reads the refusal as SUCCESS (use a distinct exit code)'
					}
				}
			}

			###########################################################################
			# Dynamic pass
			###########################################################################
			if ($TestWrapper)
			{
				$wrapDef = $funcs | Where-Object { $_.Name -eq $WrapperName } | Select-Object -First 1
				$collDef = $funcs | Where-Object { $_.Name -eq $CollectorName } | Select-Object -First 1
				if (-not $wrapDef)
				{
					Write-Host ("  (no function '{0}' in this file - dynamic pass skipped)" -f $WrapperName) -ForegroundColor DarkGray
				}
				else
				{
					Write-Host ('  --- dynamic: exercising the real {0} ---' -f $WrapperName) -ForegroundColor Cyan
					$dyn = [ScriptBlock]::Create(@"
                    `$Script:Failures = [System.Collections.Generic.List[String]]::new()
                    `$DryRun = `$false
                    $(if ($collDef) { $collDef.Extent.Text } else { "function $CollectorName { Param([String]`$Message) `$Script:Failures.Add(`$Message) }" })
                    $($wrapDef.Extent.Text)

                    # A List, not '+=' on an array: inside this dynamic scriptblock the
                    # '`$script:' scope is not the same scope as a bare '`$results = @()',
                    # so '+=' hit a PSObject and threw op_Addition for every probe.
                    `$script:results = New-Object System.Collections.Generic.List[Object]
                    function Probe {
                        Param([String]`$Label, [ScriptBlock]`$Action, [Int]`$Expect)
                        `$Script:Failures.Clear()
                        try { $WrapperName -Description `$Label -Action `$Action 6>`$null } catch { }
                        [void]`$script:results.Add([PSCustomObject]@{
                            Label = `$Label; Got = `$Script:Failures.Count; Expect = `$Expect
                            Pass  = (`$Script:Failures.Count -eq `$Expect)
                        })
                    }
                    Probe 'MUST detect: non-terminating cmdlet failure' { Set-ItemProperty -Path 'HKLM:\SOFTWARE\_NoSuchKeyAtAll' -Name x -Value 1 } 1
                    Probe 'MUST detect: native non-zero exit'          { & cmd.exe /c "exit 7" } 1
                    Probe 'MUST detect: thrown exception'              { throw 'boom' } 1
                    Probe 'must NOT flag: native stderr + exit 0'      { & cmd.exe /c "echo chatty 1>&2 & exit 0" } 0
                    Probe 'must NOT flag: clean native command'        { & cmd.exe /c "exit 0" } 0
                    Probe 'must NOT flag: cmdlet-only success'         { `$null = Get-Date } 0
                    Probe 'must NOT flag: explicit -EA SilentlyContinue' { Get-ItemProperty -Path 'HKLM:\SOFTWARE\_NoSuchKeyAtAll' -Name x -ErrorAction SilentlyContinue | Out-Null } 0
                    `$script:results
"@)
					foreach ($r in (& $dyn))
					{
						$col = if ($r.Pass) { 'Green' } else { 'Red' }
						$tag = if ($r.Pass) { 'PASS' } else { 'FAIL' }
						Write-Host ('    [{0}] {1,-52} got={2} expect={3}' -f $tag, $r.Label, $r.Got, $r.Expect) -ForegroundColor $col
						if (-not $r.Pass) { $Script:TotalFindings++ }
					}
				}
			}

			if ($Script:TotalFindings -eq $before)
			{
				Write-Host '  no findings' -ForegroundColor Green
			}
		}

		if ($Csv)
		{
			$Script:Findings | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
			Write-Host ('CSV: {0} row(s) -> {1}' -f $Script:Findings.Count, $Csv) -ForegroundColor DarkGray
		}

		if ($Script:SuppressedInline -or $Script:SuppressedBaseline)
		{
			Write-Host ('Suppressed: {0} by baseline, {1} by inline opt-out (SILENT-OK marker or SuppressMessageAttribute)' -f
				$Script:SuppressedBaseline, $Script:SuppressedInline) -ForegroundColor DarkGray
		}

		# Entries that matched nothing this run. Either the code was fixed/removed (delete them) or
		# it CHANGED and the acceptance correctly lapsed - in which case the finding is back in the
		# list above, awaiting re-triage. Only meaningful on a FULL sweep; a single-file run will
		# naturally not match the rest.
		if ($ShowAccepted)
		{
			$Stale = @($Script:Accepted.Keys | Where-Object { -not $Script:AcceptedSeen.Contains($_) })
			Write-Host ''
			Write-Host ('Baseline: {0} entr(ies), {1} matched, {2} unmatched this run' -f
				$Script:Accepted.Count, $Script:AcceptedSeen.Count, $Stale.Count) -ForegroundColor Cyan
			foreach ($S in $Stale) { Write-Host ('  unmatched: {0}' -f $S) -ForegroundColor DarkYellow }
		}

		if ($UpdateBaseline)
		{
			# Preserve the REASON for anything already accepted - that text is the expensive part,
			# and is the whole reason this file exists rather than a bare list of keys.
			$Out = New-Object System.Collections.Generic.List[String]
			[void]$Out.Add('# Accepted silent-failure findings - triaged and judged NOT to be defects.')
			[void]$Out.Add('#')
			[void]$Out.Add('# Key: Rule|VersionAgnosticPath|Function|ContentHash    Value: WHY it is accepted.')
			[void]$Out.Add('#')
			[void]$Out.Add('# The hash covers the JUDGED CONSTRUCT (catch body, param block, if-condition),')
			[void]$Out.Add('# whitespace-normalised. Reformatting does not lapse an entry; CHANGING the construct')
			[void]$Out.Add('# does - the finding then returns for re-triage rather than staying silently accepted.')
			[void]$Out.Add('# Prefer an inline "# SILENT-OK: <reason>" comment when the reason belongs with the code.')
			[void]$Out.Add(('# Regenerate: PSHG-InvokeSilentFailureSweep -UpdateBaseline   ({0})' -f (Get-Date -Format 'yyyy-MM-dd')))
			[void]$Out.Add('@{')

			# Build the set of version-agnostic paths this run actually covered, so -PruneStale can tell
			# 'the scan looked here and found nothing' from 'the scan never looked here'. Only the
			# former is stale; the latter belongs to another module's sweep and must survive.
			$ScannedRel = New-Object System.Collections.Generic.HashSet[String]
			foreach ($SF in $Script:ScannedFiles)
			{
				# Same $RepoRoot-based stripping as Get-FindingKey above - must match it exactly, or
				# -PruneStale's "did this run scan this path" comparison silently never matches.
				$R = $SF -replace ('^{0}\\' -f [Regex]::Escape($RepoRoot)), ''
				$R = $R -replace '[\\/]\d+\.\d+[\\/]', '\<ver>\'
				[void]$ScannedRel.Add($R)
			}

			$Pruned = 0
			$Merged = [ordered]@{}
			foreach ($K in ($Script:Accepted.Keys | Sort-Object))
			{
				if ($PruneStale -and -not $Script:AcceptedSeen.Contains($K))
				{
					# Second condition is the safety rail: drop it only if this run actually scanned the
					# file the key names. An entry the scan never visited is out of scope, not stale.
					$KeyRel = ($K -split '\|')[1]
					if ($ScannedRel.Contains($KeyRel))
					{
						$Pruned++
						Write-Host ('  pruned (matched nothing): {0}' -f $K) -ForegroundColor DarkYellow
						continue
					}
				}
				$Merged[$K] = $Script:Accepted[$K]
			}
			foreach ($F in $Script:Findings)
			{
				if (-not $Merged.Contains($F.Key))
				{ $Merged[$F.Key] = 'TODO: triaged {0} - state WHY this is not a defect.' -f (Get-Date -Format 'yyyy-MM-dd') }
			}
			foreach ($K in ($Merged.Keys | Sort-Object))
			{ [void]$Out.Add(("    '{0}' = '{1}'" -f [regex]::Replace($K, "['\u2018-\u201B]", '$0$0'), [regex]::Replace([string]$Merged[$K], "['\u2018-\u201B]", '$0$0'))) }
			[void]$Out.Add('}')

			# SELF-VALIDATE before committing - this baseline is safety-relevant (it gates what a
			# sweep reports), so it must never be trusted un-checked. Refuse to write, loudly,
			# rather than leave a broken file in place of a working one.
			$Private:_newText = ($Out -join "`r`n")
			$Private:_valErrs = $null
			$null = [System.Management.Automation.Language.Parser]::ParseInput($Private:_newText, [ref]$null, [ref]$Private:_valErrs)
			if ($Private:_valErrs.Count -gt 0)
			{
				Write-Host ('REFUSED to write {0}: the newly-constructed content does not parse ({1} error(s), first: {2}). The EXISTING file was left untouched.' -f
					$Script:BaselinePath, $Private:_valErrs.Count, $Private:_valErrs[0].Message) -ForegroundColor Red
				Write-Error ('PSHG-TestScriptErrorHandling: refused to write a non-parsing baseline to [{0}] - existing file left untouched.' -f $Script:BaselinePath)
				$Global:LASTEXITCODE = 2
				return
			}

			$Private:_enc = New-Object System.Text.UTF8Encoding($true)
			Write-PSHGFileAtomic -Path $Script:BaselinePath -Bytes ([Byte[]]($Private:_enc.GetPreamble() + $Private:_enc.GetBytes((($Out -join "`r`n") + "`r`n"))))
			Write-Host ''
			Write-Host ('Baseline written: {0}' -f $Script:BaselinePath) -ForegroundColor Green
			Write-Host ('  {0} entr(ies) total, {1} newly added (marked TODO - give each a real reason), {2} pruned' -f
				$Merged.Count, ($Merged.Count - ($Script:Accepted.Count - $Pruned)), $Pruned) -ForegroundColor Green
			if (-not $PruneStale)
			{
				$Unmatched = @($Script:Accepted.Keys | Where-Object { -not $Script:AcceptedSeen.Contains($_) }).Count
				if ($Unmatched)
				{ Write-Host ('  {0} entr(ies) matched nothing this run and were KEPT - add -PruneStale to remove them.' -f $Unmatched) -ForegroundColor DarkYellow }
			}
			# ALSO via Write-Warning (stream 3, not 6) - a write confirmation must survive a
			# caller's 6>$null, which PSHG-InvokeSilentFailureSweep uses unconditionally.
			Write-Warning ('Baseline WRITTEN: {0} ({1} total entries, {2} newly added, {3} pruned)' -f
				$Script:BaselinePath, $Merged.Count, ($Merged.Count - ($Script:Accepted.Count - $Pruned)), $Pruned)
		}

		# Findings also go to the SUCCESS stream as objects, so a sweep can group/filter them
		# without scraping Write-Host text (which needs '6>&1' and silently yields nothing
		# otherwise - see the -Csv parameter comment).
		$Script:Findings

		Write-PSHGSkipReport -Skipped $Script:Skipped

		Write-Host ''
		if ($Script:TotalFindings -gt 0)
		{
			Write-Host ('=== {0} finding(s) ===' -f $Script:TotalFindings) -ForegroundColor Yellow
			Write-Host 'See the module README (Get-Help PSHG-TestScriptErrorHandling -Full) for the AP1-AP12 patterns' -ForegroundColor DarkGray
			$Global:LASTEXITCODE = 1; return
		}
		if ($Script:Skipped.Count -gt 0)
		{
			Write-Host ('=== NOT clean: {0} file(s) not checked ===' -f $Script:Skipped.Count) -ForegroundColor Red
			$Global:LASTEXITCODE = 2; return
		}
		Write-Host '=== clean ===' -ForegroundColor Green
		$Global:LASTEXITCODE = 0; return
	}
}