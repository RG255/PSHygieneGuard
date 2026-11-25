Function PSHG-FindHardcodedWindowsPath
{
	<#
		.SYNOPSIS
		Finds - and, with -Fix, rewrites - a hardcoded Windows special-folder path (e.g.
		`C:\Program Files\`, `C:\ProgramData\`, `C:\Windows\`, `C:\Users\Public\`) that should
		use the matching environment variable instead. Scans both real code and comments.

		.DESCRIPTION
		A literal `C:\Program Files\` breaks the moment the script runs on a machine where
		Windows is installed elsewhere (a different system drive, a redirected ProgramData,
		a non-default install), or under a 32-bit process on 64-bit Windows where
		`C:\Program Files` and `C:\Program Files (x86)` are genuinely different folders and
		`$env:ProgramFiles` resolves correctly for the CURRENT process while a hardcoded path
		does not. It also silently breaks portability between machines and users - a literal
		`C:\Users\Alice\...` only ever works for Alice, on that one machine.

		Six targets, each mapped to the environment variable that should replace it:

		  Program Files       -> $env:ProgramFiles
		  Program Files (x86) -> ${env:ProgramFiles(x86)}
		  ProgramData         -> $env:ProgramData
		  Windows             -> $env:windir  (or $env:SystemRoot)
		  Users\<name>        -> $env:USERPROFILE (that user) or $HOME (current user)
		  Users\Public        -> $env:PUBLIC

		DESIGN, second iteration: rather than matching raw source TEXT against a regex (the
		first version's approach), this extracts every actual STRING LITERAL from the file's
		AST, then normalizes each candidate with [System.IO.Path]::GetFullPath() and compares
		its PATH SEGMENTS against each target - not its raw text. This fixes two real gaps
		in the earlier regex approach: (1) a hardcoded path used as a COMPLETE path with
		nothing after it (`Test-Path 'C:\ProgramData'`, no trailing separator) was missed
		entirely by a regex that required a literal trailing `\`; (2) any future variant
		(extra slashes, `..` segments, a mix of `/` and `\`) would have needed its own bespoke
		regex fix - segment comparison after normalization handles all of these for free,
		because GetFullPath does the normalizing, not this checker's own pattern.

		Only genuine literal strings are considered in CODE (AST `StringConstantExpressionAst`
		nodes) - an interpolated string (`"$Base\ProgramData"`) is not itself hardcoded and is
		never flagged, since GetFullPath would need to resolve the SAME environment context
		this checker exists to protect against assuming. COMMENTS (both line comments and
		block comments) are scanned separately via the token stream, since a comment carries no AST expression
		structure - a drive-rooted path-looking substring is extracted with a regex and run
		through the SAME normalize-and-segment-match logic as a code literal.

		-Fix uses two different rewrite strategies, matched to
		what a comment vs. real code actually needs:
		  - CODE:    the whole string-literal token is replaced with
		             `[System.IO.Path]::GetFullPath(('<suffix>' -f <EnvVarExpr>))` - the `-f`
		             operator populates the `{0}` placeholder from the live environment
		             variable, and wrapping the result in GetFullPath normalizes it the same
		             way this checker's own detection does (so a suffix with mixed separators,
		             `..`, or doubled slashes comes out canonical rather than literally
		             reproducing whatever the original hardcoded text happened to contain).
		             The <suffix> is built from the NORMALIZED path's own segments (not the
		             original raw text) for exactly that reason.
		  - COMMENT: a straight TEXT substitution of the matched substring for the human-
		             readable suggestion (e.g. "C:\ProgramData" -> "$env:ProgramData") -
		             comments are not evaluated, so there is nothing to normalize or format;
		             the reader just needs the corrected reference.
		Users\<name> is NEVER auto-fixed, in code or comments, and stays report-only even
		under -Fix - see the .NOTES on why this one target is a genuine judgment call a
		pattern cannot safely resolve. Under -Fix, CODE fixes are additionally restricted to
		"decision" sites (the same test -DecisionsOnly uses for reporting: an assignment
		target, or the argument to a path-like-named parameter) regardless of whether
		-DecisionsOnly was itself passed - an incidental mention inside a display string
		(e.g. `Write-Host "Installs to C:\Program Files\MyApp by default"`) is not something
		-Fix should ever rewrite into a live expression, since that changes what the string
		displays, not just how a path resolves.

		A fix is applied per FILE by splicing the exact character span of each match (from its
		own AST/token Extent) into the file's raw text, working in DESCENDING offset order so
		earlier splices never invalidate not-yet-applied offsets, then re-parsing the result
		before writing - a fix that would introduce a NEW parse error is refused, and the file
		is left untouched, the same "verify before you trust a rewrite" discipline established
		by an earlier formatter bug that corrupted files. The file's original BOM state
		(present or absent) is read and preserved exactly, never forced either way - that is
		Test-FileEncoding's job, not this tool's, and a fix here should not silently change an
		unrelated thing about the file.

		Report-only for everything this function is NOT confident enough to touch (Users\<name>
		always; anything not passing the -Fix "decision" test in code) - the same posture as
		PSHG-FindDriveLetterAssumption for those cases. A hardcoded path in a comment that is
		itself only an EXAMPLE (like this checker's own Examples\ fixtures, if scanned) is
		still a textually genuine hit - -Fix has no special knowledge of "this folder holds
		deliberately-bad demonstration content" and will rewrite it like any other match, so
		scope -Path deliberately when running -Fix against a tree that contains such fixtures.

		KNOWN LIMITATION: still requires the drive-letter-colon to be immediately followed by
		a backslash (`C:\ProgramData`) to be considered a candidate at all - `[System.IO.Path]
		::GetFullPath('C:ProgramData')` (no separator) resolves relative to that drive's own
		last working directory rather than the drive root, which is a different, much rarer
		defect shape this checker does not attempt to judge.

		.PARAMETER Path
		File or directory to scan (recurses). Defaults to the current directory.

		.PARAMETER DecisionsOnly
		Reporting only. Show only hits where the literal is used as a real path argument
		(assignment target, or the argument to a command whose name suggests path use, e.g.
		`Join-Path`, `Test-Path`, `Get-ChildItem`) - drops incidental mentions elsewhere. Has
		no effect on comment-sourced rows (always shown - there is no "decision" concept for
		free text) and no effect on -Fix (which applies its own, unconditional version of this
		same test to code hits regardless of whether -DecisionsOnly was passed).

		.PARAMETER Fix
		Rewrite what can be safely, unambiguously rewritten: code hits at a genuine decision
		site, and comment hits, for every target EXCEPT Users\<name> (always left report-only
		- see .DESCRIPTION and .NOTES). Prints a summary of files changed, replacements made,
		and anything left for manual judgment.

		.PARAMETER Csv
		Optional path to write the full candidate list to.

		.PARAMETER WhatIf
		With -Fix, shows what would be rewritten without writing anything.

		.EXAMPLE
		PSHG-FindHardcodedWindowsPath

		.EXAMPLE
		PSHG-FindHardcodedWindowsPath -Path 'C:\MyProject' -DecisionsOnly

		.EXAMPLE
		PSHG-FindHardcodedWindowsPath -Path 'C:\MyProject' -Fix
		Rewrites every safely-fixable hit in place; Users\<name> hits are still printed for
		you to judge and fix by hand.

		.NOTES
		Returns the candidate rows. $LASTEXITCODE: 1 = candidate sites found, 2 = none found but at least one file
		could not be read or parsed (listed; NOT a clean result), 0 = clean. Scans .ps1, .psm1 and .psd1.

		-Fix limits (a hit is reported but never rewritten): Users\<name>; a literal that is not at a decision site
		(an assignment, or an argument of a path-taking command / path-named parameter, not inside a nested script
		block); anything in a .psd1 data file; a regex-escaped literal (doubled backslashes) or the operand of
		-match/-replace/-split; and any file that is not valid UTF-8 (refused, left untouched). Rewrites go through
		a temp file in the same folder; -WhatIf is supported.

		Why Users\<name> can never be auto-fixed: the two candidate replacements
		($env:USERPROFILE / $HOME for the CURRENT user) are only correct if the hardcoded name
		actually IS the current user. A hardcoded `C:\Users\ServiceAcct\...` in an admin or
		scheduled-task script may deliberately mean a SPECIFIC, DIFFERENT user's profile - a
		pattern-based checker cannot tell "this was lazily hardcoded for whoever's logged in"
		from "this intentionally reaches into someone else's profile", and guessing wrong
		silently breaks the script for every user except the one hardcoded. That is why it stays
		report-only.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	[OutputType([PSCustomObject[]])]
	Param (
		[String]$Path = $PWD.ProviderPath,
		[Switch]$DecisionsOnly,
		[Switch]$Fix,
		[String]$Csv
	)

	# Each target's segments AFTER the drive letter, matched as a PREFIX of the normalized
	# path's own segments (so both "C:\ProgramData" alone and "C:\ProgramData\MyApp\x.json"
	# match the same way - segment comparison needs no separate "used as a complete path"
	# special case the way the text-regex version did).
	# NOTE: no leading unary comma on these values - that trick prevents PowerShell's
	# single-element-array-unwrap on RETURN/pipeline output, but a plain hashtable-value
	# assignment never unwraps anything on its own. Adding it here was a real bug:
	# it silently DOUBLE-wrapped every entry (Count=1, element[0]=the real array), which a
	# lucky scalar-vs-1-element-array comparison quirk masked for every single-segment target
	# but broke outright for UsersPublic (2 segments) - "Users" -ieq @("Users","Public") is
	# $false, so the real 2-segment comparison never even ran.
	$Targets = [ordered]@{
		'ProgramFilesX86' = @('Program Files (x86)')
		'ProgramFiles'    = @('Program Files')
		'ProgramData'     = @('ProgramData')
		'Windows'         = @('Windows')
		'UsersPublic'     = @('Users', 'Public')
		'UsersNamed'      = @('Users')   # special-cased below: matches Users\<anything but Public>
	}
	$Suggestion = @{
		'ProgramFilesX86' = '${env:ProgramFiles(x86)}'
		'ProgramFiles'    = '$env:ProgramFiles'
		'ProgramData'     = '$env:ProgramData'
		'Windows'         = '$env:windir (or $env:SystemRoot)'
		'UsersPublic'     = '$env:PUBLIC'
		'UsersNamed'      = '$env:USERPROFILE (that user) or $HOME (current user)'
	}
	# The single, DETERMINISTIC expression -Fix substitutes for each target - deliberately a
	# separate map from $Suggestion above (whose text is for a human to read, and for Windows/
	# UsersNamed lists more than one option). UsersNamed has NO entry here on purpose - its
	# absence is what makes it un-fixable further down, not a separate flag to check.
	$FixExpression = @{
		'ProgramFilesX86' = '${env:ProgramFiles(x86)}'
		'ProgramFiles'    = '$env:ProgramFiles'
		'ProgramData'     = '$env:ProgramData'
		'Windows'         = '$env:windir'
		'UsersPublic'     = '$env:PUBLIC'
	}
	$Skip = '\\_RetiredModules\\|\\\.archive\\|\\Original\\|\\Originals\\|\\\.git\\'
	$PathLikeCommandName   = '(?i)Path$'
	$PathLikeCmdlets       = 'Get-ChildItem', 'Get-Item', 'Get-ItemProperty', 'Get-Content', 'Set-Content', 'Add-Content', 'Out-File',
	'Copy-Item', 'Move-Item', 'Remove-Item', 'New-Item', 'Set-Location', 'Push-Location', 'Start-Process', 'Invoke-Item',
	'Import-Csv', 'Export-Csv', 'Expand-Archive', 'Compress-Archive'
	$PathLikeParameterName = '(?i)Path$|^(Destination|WorkingDirectory)$'
	$RegexOperatorPattern  = '(?i)^[ic]?(not)?match$|^[ic]?replace$|^[ic]?split$'
	# Drive-rooted path-looking runs inside comment text - stops at whitespace or a quote,
	# since comment path mentions are essentially always unquoted or single-quoted-in-prose.
	$CommentPathPattern = '[A-Za-z]:\\[^\s''"<>|]+'

	If (-not (Test-Path -LiteralPath $Path)) { throw ('Path not found: [{0}]' -f $Path) }
	$Private:Root = (Resolve-Path -LiteralPath $Path).ProviderPath

	# A literal is a "decision" site when it is assigned, or is an argument of a command that takes a path
	# (by cmdlet name, or by the name of the parameter it is bound to). The walk stops at the first command or
	# nested scope, so an incidental string inside a script block or a display command is never a decision.
	Function Test-PathLikeCommand
	{
		Param ($Command, $Literal, [String]$NamePattern, [String[]]$Cmdlet, [String]$ParameterPattern)
		$Private:_cmdName = $Command.GetCommandName()
		If ($Private:_cmdName -and ($Private:_cmdName -match $NamePattern -or $Private:_cmdName -in $Cmdlet)) { return $true }
		$Private:_els = $Command.CommandElements
		For ($Private:_i = 1; $Private:_i -lt $Private:_els.Count; $Private:_i++)
		{
			$Private:_e = $Private:_els[$Private:_i]
			If ($Private:_e -isnot [System.Management.Automation.Language.CommandParameterAst]) { Continue }
			If ($Private:_e.ParameterName -notmatch $ParameterPattern) { Continue }
			$Private:_arg = If ($Private:_e.Argument) { $Private:_e.Argument } ElseIf ($Private:_i + 1 -lt $Private:_els.Count) { $Private:_els[$Private:_i + 1] } Else { $null }
			If ($Private:_arg -and $Private:_arg.Extent.StartOffset -le $Literal.Extent.StartOffset -and $Private:_arg.Extent.EndOffset -ge $Literal.Extent.EndOffset) { return $true }
		}
		return $false
	}

	# Shared by both the AST-literal loop and the comment loop, so the two can never judge the
	# same normalized path differently.
	Function Test-PathTargetMatch
	{
		Param ([String[]]$AfterDriveSegments)
		foreach ($Private:_name in $Targets.Keys)
		{
			$Private:_want = $Targets[$Private:_name]
			if ($AfterDriveSegments.Count -lt $Private:_want.Count) { continue }
			$Private:_isMatch = $true
			for ($Private:_i = 0; $Private:_i -lt $Private:_want.Count; $Private:_i++)
			{
				if ($AfterDriveSegments[$Private:_i] -ine $Private:_want[$Private:_i]) { $Private:_isMatch = $false; break }
			}
			if (-not $Private:_isMatch) { continue }
			if ($Private:_name -eq 'UsersNamed')
			{
				if ($AfterDriveSegments.Count -lt 2 -or $AfterDriveSegments[1] -ieq 'Public') { continue }
			}
			return $Private:_name
		}
		return $null
	}

	$Skipped = [System.Collections.Generic.List[String]]::new()
	$FileEnumErrors = $null
	$Files = @(Get-ChildItem -LiteralPath $Private:Root -Recurse -Include *.ps1, *.psm1, *.psd1 -File -ErrorAction SilentlyContinue -ErrorVariable FileEnumErrors |
			Where-Object { $_.FullName -notmatch $Skip })
	ForEach ($Private:_enumErr in $FileEnumErrors)
	{ $Skipped.Add(('{0} (cannot enumerate: {1})' -f $Private:_enumErr.TargetObject, $Private:_enumErr.Exception.Message)) }

	$Rows        = @()
	$FilesFixed  = 0
	$FixCount    = 0
	$FixSkipped  = 0
	$FixRefused  = @()
	$StrictUtf8  = New-Object System.Text.UTF8Encoding($false, $true)

	ForEach ($File in $Files)
	{
		$Private:_bytes = $null
		Try { $Private:_bytes = [System.IO.File]::ReadAllBytes($File.FullName) }
		Catch
		{ $Skipped.Add(('{0} (cannot read: {1})' -f $File.FullName, $_.Exception.Message)); Continue }
		$Private:_hadBom = ($Private:_bytes.Count -ge 3 -and $Private:_bytes[0] -eq 0xEF -and $Private:_bytes[1] -eq 0xBB -and $Private:_bytes[2] -eq 0xBF)
		$Private:_bodyStart = If ($Private:_hadBom) { 3 } Else { 0 }
		# Lenient decode is enough to LOOK for paths; a rewrite additionally requires strict UTF-8 (checked below).
		$Private:_rawText = [System.Text.Encoding]::UTF8.GetString($Private:_bytes, $Private:_bodyStart, $Private:_bytes.Count - $Private:_bodyStart)
		$Private:_strictOk = $true
		Try { $null = $StrictUtf8.GetString($Private:_bytes, $Private:_bodyStart, $Private:_bytes.Count - $Private:_bodyStart) }
		Catch { $Private:_strictOk = $false }

		$Private:_tokens = $null
		$Private:_errs   = $null
		$Private:_ast = [System.Management.Automation.Language.Parser]::ParseInput($Private:_rawText, [ref]$Private:_tokens, [ref]$Private:_errs)
		$Private:_blocking = @($Private:_errs | Where-Object { $_.ErrorId -ne 'TypeNotFound' })
		If ($Private:_blocking.Count -gt 0)
		{ $Skipped.Add(('{0} (parse error at line {1}: {2})' -f $File.FullName, $Private:_blocking[0].Extent.StartLineNumber, $Private:_blocking[0].Message)); Continue }

		$Private:_fileRows = @()

		# --- Code literals (AST) ---
		$Private:_literals = $Private:_ast.FindAll(
			{ Param($N) $N -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)

		ForEach ($Private:_lit in $Private:_literals)
		{
			$Private:_value = $Private:_lit.Value
			If ($Private:_value -notmatch '^[A-Za-z]:\\') { Continue }

			$Private:_full = $null
			Try { $Private:_full = [System.IO.Path]::GetFullPath($Private:_value) }
			Catch { Continue }

			$Private:_segments = @($Private:_full -split '\\' | Where-Object { $_ -ne '' })
			If ($Private:_segments.Count -lt 2) { Continue }
			$Private:_afterDrive = $Private:_segments[1..($Private:_segments.Count - 1)]

			$Private:_matchName = Test-PathTargetMatch -AfterDriveSegments $Private:_afterDrive
			If (-not $Private:_matchName) { Continue }

			$Private:_isDecision = $false
			$Private:_parent = $Private:_lit.Parent
			While ($Private:_parent)
			{
				If ($Private:_parent -is [System.Management.Automation.Language.AssignmentStatementAst]) { $Private:_isDecision = $true; Break }
				If ($Private:_parent -is [System.Management.Automation.Language.CommandAst])
				{ $Private:_isDecision = Test-PathLikeCommand -Command $Private:_parent -Literal $Private:_lit -NamePattern $PathLikeCommandName -Cmdlet $PathLikeCmdlets -ParameterPattern $PathLikeParameterName; Break }
				# Nested scopes, parameter defaults and attribute arguments are not rewritable value sites.
				If ($Private:_parent -is [System.Management.Automation.Language.ScriptBlockAst] -or
					$Private:_parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
					$Private:_parent -is [System.Management.Automation.Language.ParameterAst] -or
					$Private:_parent -is [System.Management.Automation.Language.AttributeBaseAst] -or
					$Private:_parent -is [System.Management.Automation.Language.TypeDefinitionAst]) { Break }
				$Private:_parent = $Private:_parent.Parent
			}

			# Never auto-rewrite where the replacement is not a plain path value: a data file, a regex (doubled
			# backslashes, or the operand of -match/-replace/-split) or a [regex] call.
			$Private:_noFix = ''
			If ($File.Extension -ieq '.psd1') { $Private:_noFix = 'data file (.psd1)' }
			ElseIf ($Private:_value.Substring(2) -match '\\\\') { $Private:_noFix = 'regex-escaped literal' }
			ElseIf ($Private:_lit.Parent -is [System.Management.Automation.Language.BinaryExpressionAst] -and
				$Private:_lit.Parent.Operator.ToString() -match $RegexOperatorPattern) { $Private:_noFix = 'regex operator operand' }
			ElseIf ($Private:_lit.Parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
				$Private:_lit.Parent.Expression.Extent.Text -match '(?i)^\[(System\.Text\.RegularExpressions\.)?regex\]$') { $Private:_noFix = 'regex call argument' }

			If ($DecisionsOnly -and -not $Private:_isDecision) { Continue }

			$Private:_afterTargetSegments = $Private:_afterDrive[$Targets[$Private:_matchName].Count..($Private:_afterDrive.Count - 1)]
			If ($Private:_afterDrive.Count -eq $Targets[$Private:_matchName].Count) { $Private:_afterTargetSegments = @() }
			$Private:_suffix = [regex]::Replace(($Private:_afterTargetSegments -join '\'), "['\u2018-\u201B]", '$0$0')

			$Private:_fileRows += [PSCustomObject]@{
				Pattern     = $Private:_matchName
				File        = $File.FullName
				Line        = $Private:_lit.Extent.StartLineNumber
				Text        = $Private:_lit.Extent.Text
				Normalized  = $Private:_full
				Suggestion  = $Suggestion[$Private:_matchName]
				InComment   = $false
				IsDecision  = $Private:_isDecision
				NoFixReason = $Private:_noFix
				StartOffset = $Private:_lit.Extent.StartOffset
				EndOffset   = $Private:_lit.Extent.EndOffset
				FixSuffix   = $Private:_suffix
			}
		}

		# --- Comments (token stream - comments carry no AST expression structure) ---
		ForEach ($Private:_tok in $Private:_tokens)
		{
			If ($Private:_tok.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { Continue }
			$Private:_commentMatches = [Regex]::Matches($Private:_tok.Text, $CommentPathPattern)
			ForEach ($Private:_cm in $Private:_commentMatches)
			{
				$Private:_full = $null
				Try { $Private:_full = [System.IO.Path]::GetFullPath($Private:_cm.Value) }
				Catch { Continue }

				$Private:_segments = @($Private:_full -split '\\' | Where-Object { $_ -ne '' })
				If ($Private:_segments.Count -lt 2) { Continue }
				$Private:_afterDrive = $Private:_segments[1..($Private:_segments.Count - 1)]

				$Private:_matchName = Test-PathTargetMatch -AfterDriveSegments $Private:_afterDrive
				If (-not $Private:_matchName) { Continue }

				# Same "prefix replaced, suffix preserved" split used for code hits - a match
				# text of "C:\ProgramData\MyApp\config.json" must fix to "$env:ProgramData\MyApp\
				# config.json", not silently drop everything after the matched target segment(s).
				$Private:_afterTargetSegments = $Private:_afterDrive[$Targets[$Private:_matchName].Count..($Private:_afterDrive.Count - 1)]
				If ($Private:_afterDrive.Count -eq $Targets[$Private:_matchName].Count) { $Private:_afterTargetSegments = @() }
				$Private:_commentSuffix = ($Private:_afterTargetSegments -join '\')

				$Private:_fileRows += [PSCustomObject]@{
					Pattern     = $Private:_matchName
					File        = $File.FullName
					Line        = $Private:_tok.Extent.StartLineNumber
					Text        = $Private:_cm.Value
					Normalized  = $Private:_full
					Suggestion  = $Suggestion[$Private:_matchName]
					InComment   = $true
					IsDecision  = $true   # comments have no decision concept - always fixable if the target is
					NoFixReason = ''
					StartOffset = $Private:_tok.Extent.StartOffset + $Private:_cm.Index
					EndOffset   = $Private:_tok.Extent.StartOffset + $Private:_cm.Index + $Private:_cm.Length
					FixSuffix   = $Private:_commentSuffix
				}
			}
		}

		$Private:_fileRows = @($Private:_fileRows | Sort-Object Line, StartOffset -Unique)
		$Rows += $Private:_fileRows

		# --- Fix pass for this file ---
		If ($Fix -and $Private:_fileRows.Count -gt 0)
		{
			$Private:_fixable = @($Private:_fileRows | Where-Object {
					$_.Pattern -ne 'UsersNamed' -and $_.IsDecision -and $FixExpression.ContainsKey($_.Pattern) -and -not $_.NoFixReason
				})
			$FixSkipped += ($Private:_fileRows.Count - $Private:_fixable.Count)

			If ($Private:_fixable.Count -gt 0 -and -not $Private:_strictOk)
			{
				# A rewrite re-encodes the whole file as UTF-8; on a file that is not valid UTF-8 that corrupts it.
				$FixRefused += $File.FullName
				Write-Host ('REFUSED {0}: not valid UTF-8 (genuinely ANSI?) - left untouched' -f $File.FullName) -ForegroundColor Red
			}
			ElseIf ($Private:_fixable.Count -gt 0)
			{
				$Private:_working = $Private:_rawText
				# Descending StartOffset so an earlier splice never shifts an offset not yet applied.
				ForEach ($Private:_r in ($Private:_fixable | Sort-Object StartOffset -Descending))
				{
					$Private:_replacement = If ($Private:_r.InComment)
					{
						# Straight text substitution, prefix only - a match of "C:\ProgramData\MyApp\
						# config.json" must become "$env:ProgramData\MyApp\config.json", not just
						# "$env:ProgramData" with the rest of the path silently dropped (a real bug,
						# found by this tool's own Pester suite). Uses $FixExpression (the single
						# deterministic choice), not $Suggestion (human-readable text that, for
						# Windows, literally reads "$env:windir (or $env:SystemRoot)" - not a string
						# a path suffix could be appended to).
						If ($Private:_r.FixSuffix) { '{0}\{1}' -f $FixExpression[$Private:_r.Pattern], $Private:_r.FixSuffix }
						Else { $FixExpression[$Private:_r.Pattern] }
					}
					Else
					{
						# Building CODE that itself uses -f (`'{0}\MyApp' -f $env:ProgramData`) with
						# -f is a genuine trap: a straight `"...{0}..." -f $Suffix` consumes the very
						# `{0}` that needs to survive INTO the output for the generated code's own
						# -f to use later - it silently produced `'MyApp' -f $env:X`
						# (no placeholder at all, so -f had nothing to substitute and the env var was
						# dropped). Fixed by passing the brace characters themselves as -f ARGUMENTS
						# (positions {0}/{1}) rather than writing literal `{`/`}` into the template -
						# `-f` never treats a SUBSTITUTED value as a placeholder, only the template
						# text is scanned for `{n}`, so this reliably emits a literal `{0}` no matter
						# what. The outer (...) around the whole expression is required too - this
						# replaces a bare string-literal TOKEN, which may sit in COMMAND ARGUMENT
						# position (e.g. `Join-Path 'C:\...' 'x'`), where an unparenthesized multi-
						# token expression parses as several separate bare arguments instead of one
						# value - seen in exactly that Join-Path shape.
						$Private:_suffixText = If ($Private:_r.FixSuffix) { '\' + $Private:_r.FixSuffix } Else { '' }
						'([System.IO.Path]::GetFullPath((''{0}{2}{1}{3}'' -f {4})))' -f '{', '}', '0', $Private:_suffixText, $FixExpression[$Private:_r.Pattern]
					}

					$Private:_working = $Private:_working.Substring(0, $Private:_r.StartOffset) + $Private:_replacement + $Private:_working.Substring($Private:_r.EndOffset)
				}

				# Never trust a rewrite without checking it still parses - the exact lesson from
				# an earlier formatter bug that corrupted files, applied here to a different kind
				# of write.
				$Private:_checkErrs = $null
				$null = [System.Management.Automation.Language.Parser]::ParseInput($Private:_working, [ref]$null, [ref]$Private:_checkErrs)
				If ($Private:_checkErrs.Count -gt $Private:_errs.Count)
				{
					$FixRefused += $File.FullName
					Write-Host ('REFUSED {0}: fix would introduce a parse error - left untouched' -f $File.FullName) -ForegroundColor Red
				}
				ElseIf ($PSCmdlet.ShouldProcess($File.FullName, ('Replace {0} hardcoded path(s)' -f $Private:_fixable.Count)))
				{
					$Private:_outBytes = [System.Text.Encoding]::UTF8.GetBytes($Private:_working)
					If ($Private:_hadBom) { $Private:_outBytes = [Byte[]](@(0xEF, 0xBB, 0xBF) + $Private:_outBytes) }
					Write-PSHGFileAtomic -Path $File.FullName -Bytes $Private:_outBytes
					$FilesFixed++
					$FixCount += $Private:_fixable.Count
					Write-Host ('FIXED   {0}: {1} replacement(s)' -f $File.FullName, $Private:_fixable.Count) -ForegroundColor Green
				}
			}
		}
	}

	If ($DecisionsOnly) { $Rows = @($Rows | Where-Object { $_.InComment -or $_.IsDecision }) }
	$Rows = @($Rows | Sort-Object File, Line, Pattern -Unique)

	Write-Host ('Candidate sites: {0}{1}' -f $Rows.Count, $(if ($DecisionsOnly) { ' (decisions only)' } else { '' })) -ForegroundColor Cyan
	Write-Host ''
	foreach ($Group in ($Rows | Group-Object Pattern | Sort-Object Count -Descending))
	{ Write-Host ('  {0,-16} {1,3}' -f $Group.Name, $Group.Count) }
	Write-Host ''
	foreach ($Row in ($Rows | Sort-Object File, Line))
	{
		$Private:_tag = if ($Row.InComment) { '[comment]' } else { '' }
		Write-Host ('  [{0}] {1}:{2} {3}' -f $Row.Pattern, $Row.File, $Row.Line, $Private:_tag) -ForegroundColor DarkGray
		Write-Host ('      {0}' -f $Row.Text.Substring(0, [Math]::Min(110, $Row.Text.Length)))
		Write-Host ('      Suggest: {0}' -f $Row.Suggestion) -ForegroundColor Yellow
	}

	If ($Fix)
	{
		Write-Host ''
		Write-Host ('Fix summary: {0} file(s) changed, {1} replacement(s) made, {2} left for manual judgment (Users\<name> or not a decision site)' -f $FilesFixed, $FixCount, $FixSkipped) -ForegroundColor Cyan
		If ($FixRefused.Count -gt 0)
		{ Write-Host ('{0} file(s) REFUSED - fix would have introduced a parse error, left untouched: {1}' -f $FixRefused.Count, ($FixRefused -join ', ')) -ForegroundColor Red }
	}

	if ($Csv)
	{
		$Rows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
		Write-Host ''
		Write-Host ('CSV: {0}' -f $Csv) -ForegroundColor DarkGray
	}

	Write-PSHGSkipReport -Skipped $Skipped

	# 1 = candidate sites found, 2 = none found but some files were NOT checked, 0 = clean.
	if ($Rows.Count -gt 0) { $Global:LASTEXITCODE = 1 }
	elseif ($Skipped.Count -gt 0) { $Global:LASTEXITCODE = 2 }
	else { $Global:LASTEXITCODE = 0 }

	# Unary comma REQUIRED - see PSHG-FindDriveLetterAssumption's own note on this exact gotcha:
	# without it, a single-element (or zero-element) $Rows silently unwraps on return.
	return ,$Rows
}
