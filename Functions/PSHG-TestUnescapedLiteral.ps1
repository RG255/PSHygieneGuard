Function PSHG-TestUnescapedLiteral
{
	<#
		.SYNOPSIS
		Finds values placed inside a single-quoted literal of a -f format string with no escaping at all - even an
		ASCII apostrophe in the value ends the literal early. A lead finder, not a verdict.

		.DESCRIPTION
		Code that generates command text or a data file often puts a value between single quotes in a format string:

		    ("Set-Thing -Path '{0}'" -f $Path)               # reported: nothing escapes $Path
		    ("@{{ Path = '{0}' }}" -f $Path)                 # reported: same, in a generated data file
		    ("Set-Thing -Path '{0}'" -f (Format-EscapedLiteral $Path))   # not reported

		A value containing an apostrophe (a folder called "Ray's disks") then ends the literal early: the generated
		command breaks, and with a crafted value it runs text from the value. This is a different defect from
		PSHG-TestTypographicQuoteEscape, which checks that a hand-rolled escape also covers typographic quotes.

		A site is reported when the -f operator (or [string]::Format) has a format string with a placeholder directly
		between two single quotes ('{n}', also inside a here-string or beside doubled braces as in "@{{ ... }}") and
		the n-th argument is NOT one of these:

		  * a call to Format-EscapedLiteral (any spelling, also through a pipeline, parentheses or $(...)), the .NET
		    EscapeSingleQuotedStringContent method, or a [Regex]::Replace / -replace / .Replace expression that names
		    a typographic quote;
		  * a constant or literal;
		  * a variable whose every assignment before the site, in the same function, is one of these safe forms;
		  * a value that cannot contain a quote: an [int] / [guid] / [datetime] / [bool] / enum typed value (cast,
		    typed parameter or typed assignment), a [ValidateSet] parameter whose values contain no quote, a
		    .ToString('N') / .ToString('yyyy-MM-dd') style format, Get-Date, New-Guid, .Count, .Length.

		A variable named like an escaped one (*Esc, *Escaped, *ForCb) is trusted only when its assignment really is an
		escape call; otherwise the site is reported with Kind 'name-only'.

		Every site is a question, not a defect: is this value ever user or disk controlled, and is the result parsed as
		PowerShell or as a data file? Display text (a value shown in a message) is harmless; a command string, a
		-Command argument or a generated .psd1 is not. Sites that are only displayed or thrown (the whole -f result is
		an argument of Write-Host, Write-Verbose, Write-Warning, Write-Debug, Write-Information, Write-Error or
		Write-Progress, or of throw) are skipped unless -IncludeDisplay is given; -DisplayCommand adds more names.

		Known limits: the format string must be a constant (or a variable with one constant assignment); arguments that
		are property reads (`$State.Path`) or method results are reported because they cannot be proven escaped; a
		placeholder that is inside a literal but not directly between the quotes ('{0}\sub') is not seen; values
		interpolated into a double-quoted string ("Set-Thing '$Path'") instead of -f are not seen; a double-quoted
		placeholder ("{0}") is not seen; a variable changed through [ref], -OutVariable or a loop is judged by its plain
		assignments only.

		There is NO baseline and no marker comment: every site is listed on every run. Exit code 1 on any site.

		Uses the PowerShell language parser's AST directly - no PSScriptAnalyzer dependency.

		.PARAMETER Path
		File or directory to scan (recurses; .ps1 and .psm1). Accepts pipeline input (strings or objects with a
		FullName property). Defaults to the current directory.

		.PARAMETER IncludeTests
		Also scan files under a Tests folder and files named *.Tests.ps1 (skipped by default when a directory is
		scanned, because test fixtures build such strings on purpose). A file passed by name is always scanned.

		.PARAMETER IncludeDisplay
		Also report sites whose -f result is only displayed or thrown.

		.PARAMETER DisplayCommand
		Command names whose arguments count as display-only. Defaults to Write-Host, Write-Verbose, Write-Warning,
		Write-Debug, Write-Information, Write-Error and Write-Progress.

		.PARAMETER Quiet
		Print only the findings and the final verdict line (no banner, no per-finding review line).

		.PARAMETER Csv
		Write every finding (File, Line, Arg, Kind, Value, Text) to this CSV file.

		.PARAMETER PassThru
		Also emit each finding as an object to the success stream.

		.EXAMPLE
		PSHG-TestUnescapedLiteral -Path 'C:\MyProject'

		.EXAMPLE
		Get-ChildItem C:\MyProject -Recurse -Filter *.ps1 | PSHG-TestUnescapedLiteral -Csv .\literals.csv

		.NOTES
		Returns 0 = clean, 1 = at least one site to review, 2 = no sites but at least one file could not be read or parsed
		(listed; NOT a clean result). Follow the call with `exit $LASTEXITCODE` for a process exit code; `exit (call)` yields 0.
		Folders named Original, Originals, _RetiredModules, .archive, _PlanningDocs and .git are skipped.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Console report is the entire purpose of this tool (matches module convention)')]
	[CmdletBinding()]
	Param (
		[Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
		[Alias('FullName')]
		[String[]]$Path = @($PWD.ProviderPath),

		[Switch]$IncludeTests,
		[Switch]$IncludeDisplay,
		[String[]]$DisplayCommand = @('Write-Host', 'Write-Verbose', 'Write-Warning', 'Write-Debug', 'Write-Information', 'Write-Error', 'Write-Progress'),
		[Switch]$Quiet,
		[String]$Csv,
		[Switch]$PassThru
	)

	Begin
	{
		$Script:UelFindings = [System.Collections.Generic.List[PSCustomObject]]::new()
		$Script:UelSkipped  = [System.Collections.Generic.List[String]]::new()
		$Script:UelFileCount = 0
		$Script:UelDisplaySkipped = 0
		$Script:UelExclude = '\\Original(s)?\\|\\_RetiredModules\\|\\\.archive\\|\\_PlanningDocs\\|\\\.git\\'
		$Script:UelCache = New-Object 'System.Collections.Generic.Dictionary[object,object]'

		# Evidence that an expression deals with typographic single quotes (built from char codes so this file stays ASCII).
		$Script:UelCover = '[{0}-{1}]|0x201[89AB]|u201[89AB]|\b821[6-9]\b' -f [char]0x2018, [char]0x201B
		$Script:UelPlaceholder = [regex]'\{\{|\}\}|\{(\d+)(?:,\s*-?\d+)?(?::[^{}]*)?\}'

		# Strips a wrapping ( ), $( ) or single-element pipeline so the expression underneath is examined.
		Function Get-UelInner
		{
			Param ($N)
			While ($N)
			{
				$Private:T = $N.GetType().Name
				If ($Private:T -eq 'ParenExpressionAst') { $N = $N.Pipeline; Continue }
				If ($Private:T -eq 'SubExpressionAst') { If ($N.SubExpression.Statements.Count -eq 1) { $N = $N.SubExpression.Statements[0]; Continue }; break }
				If ($Private:T -eq 'PipelineAst') { If ($N.PipelineElements.Count -eq 1) { $N = $N.PipelineElements[0]; Continue }; break }
				If ($Private:T -eq 'CommandExpressionAst') { $N = $N.Expression; Continue }
				break
			}
			return $N
		}

		# Constant text of a string node (also a + b of constants and a parenthesised one), or $null.
		Function Get-UelConstText
		{
			Param ($N)
			$N = Get-UelInner $N
			If ($null -eq $N) { return $null }
			Switch ($N.GetType().Name)
			{
				'StringConstantExpressionAst' { return $N.Value }
				'ExpandableStringExpressionAst' { return $N.Value }
				'BinaryExpressionAst'
				{
					If ($N.Operator -ne 'Plus') { return $null }
					$Private:L = Get-UelConstText $N.Left
					$Private:R = Get-UelConstText $N.Right
					If ($null -ne $Private:L -and $null -ne $Private:R) { return ($Private:L + $Private:R) }
					return $null
				}
			}
			return $null
		}

		# The scopes to look in for a variable, innermost first: enclosing functions, then the file root.
		Function Get-UelScopeChain
		{
			Param ($Node)
			$Private:Chain = [System.Collections.Generic.List[object]]::new()
			$Private:Cur = $Node
			While ($Private:Cur)
			{
				If ($Private:Cur -is [System.Management.Automation.Language.FunctionDefinitionAst] -or ($Private:Cur -is [System.Management.Automation.Language.ScriptBlockAst] -and -not $Private:Cur.Parent))
				{ $Private:Chain.Add($Private:Cur) }
				$Private:Cur = $Private:Cur.Parent
			}
			return , $Private:Chain.ToArray()
		}

		Function Get-UelVarKey
		{
			Param ([String]$Name)
			return (($Name -replace '^(?i:private|local|script|global):', '')).ToLowerInvariant()
		}

		Function Add-UelEntry
		{
			Param ($Index, [String]$Name, $Entry)
			$Private:K = Get-UelVarKey $Name
			If (-not $Index.ContainsKey($Private:K)) { $Index[$Private:K] = [System.Collections.Generic.List[object]]::new() }
			$Index[$Private:K].Add($Entry)
		}

		# Assignments and parameters of one scope, indexed by variable name (computed once per scope).
		Function Get-UelScopeIndex
		{
			Param ($Scope)
			$Private:Hit = $null
			If ($Script:UelCache.TryGetValue($Scope, [ref]$Private:Hit)) { return $Private:Hit }
			$Private:Index = @{}
			$Private:Nodes = $Scope.FindAll({ Param($X) $X -is [System.Management.Automation.Language.AssignmentStatementAst] -or $X -is [System.Management.Automation.Language.ParameterAst] }, $true)
			ForEach ($Private:X in $Private:Nodes)
			{
				# Only nodes whose nearest enclosing function is this scope: a nested function's own variables are not visible here.
				$Private:Owner = $Private:X.Parent
				While ($Private:Owner -and $Private:Owner -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $Private:Owner = $Private:Owner.Parent }
				If ($Private:Owner -and -not [object]::ReferenceEquals($Private:Owner, $Scope)) { Continue }
				If (-not $Private:Owner -and $Scope -is [System.Management.Automation.Language.FunctionDefinitionAst]) { Continue }
				If ($Private:X -is [System.Management.Automation.Language.ParameterAst])
				{ Add-UelEntry $Private:Index $Private:X.Name.VariablePath.UserPath ([PSCustomObject]@{ Kind = 'param'; Node = $Private:X; Offset = $Private:X.Extent.StartOffset }); Continue }

				$Private:Left = $Private:X.Left
				$Private:Type = $null
				If ($Private:Left -is [System.Management.Automation.Language.ConvertExpressionAst]) { $Private:Type = $Private:Left.StaticType; $Private:Left = $Private:Left.Child }
				If ($Private:Left -is [System.Management.Automation.Language.VariableExpressionAst])
				{ Add-UelEntry $Private:Index $Private:Left.VariablePath.UserPath ([PSCustomObject]@{ Kind = 'assign'; Node = $Private:X; Type = $Private:Type; Offset = $Private:X.Extent.StartOffset }) }
				ElseIf ($Private:Left -is [System.Management.Automation.Language.ArrayLiteralAst])
				{
					ForEach ($Private:El in $Private:Left.Elements)
					{ If ($Private:El -is [System.Management.Automation.Language.VariableExpressionAst]) { Add-UelEntry $Private:Index $Private:El.VariablePath.UserPath ([PSCustomObject]@{ Kind = 'assign'; Node = $null; Type = $null; Offset = $Private:X.Extent.StartOffset }) } }
				}
			}
			$Script:UelCache[$Scope] = $Private:Index
			return $Private:Index
		}

		# True for a type whose text can never contain a quote.
		Function Test-UelSafeType
		{
			Param ($Type)
			If ($null -eq $Type) { return $false }
			While ($Type.IsArray) { $Type = $Type.GetElementType() }
			If ($Type.IsEnum) { return $true }
			If ($Type.IsPrimitive) { return ($Type -ne [char] -and $Type -ne [IntPtr] -and $Type -ne [UIntPtr]) }
			return ($Type -in @([decimal], [guid], [datetime], [timespan], [datetimeoffset], [System.Management.Automation.SwitchParameter], [version]))
		}

		# True when the expression is an escape of the whole single-quote class (the shared helper or an equivalent).
		Function Test-UelEscape
		{
			Param ($N, [int]$Depth = 0)
			If ($null -eq $N -or $Depth -gt 8) { return $false }
			$N = Get-UelInner $N
			If ($null -eq $N) { return $false }
			Switch ($N.GetType().Name)
			{
				'PipelineAst'
				{
					$Private:Last = $N.PipelineElements[$N.PipelineElements.Count - 1]
					return (Test-UelEscape $Private:Last ($Depth + 1))
				}
				'CommandAst'
				{
					$Private:Name = $N.GetCommandName()
					return [bool]($Private:Name -and $Private:Name -match '(^|\\)Format-EscapedLiteral$')
				}
				'ConvertExpressionAst'
				{
					If ($N.StaticType -eq [string]) { return (Test-UelEscape $N.Child ($Depth + 1)) }
					return $false
				}
				'InvokeMemberExpressionAst'
				{
					If ($N.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $false }
					If ($N.Static -and $N.Member.Value -ieq 'EscapeSingleQuotedStringContent') { return $true }
					If ($N.Member.Value -ieq 'Replace') { return ($N.Extent.Text -match $Script:UelCover) }
					return $false
				}
				'BinaryExpressionAst'
				{
					If ($N.Operator -in 'Replace', 'Ireplace', 'Creplace') { return ($N.Extent.Text -match $Script:UelCover) }
					return $false
				}
			}
			return $false
		}

		# Reason string when a variable is provably safe at the use site, else $null.
		Function Test-UelVariable
		{
			Param ($Use, [String]$Name, [int]$Depth, [System.Collections.Generic.HashSet[String]]$Visited)
			$Private:Key = Get-UelVarKey $Name
			ForEach ($Private:Scope in (Get-UelScopeChain $Use))
			{
				$Private:Index = Get-UelScopeIndex $Private:Scope
				If (-not $Private:Index.ContainsKey($Private:Key)) { Continue }
				$Private:Entries = @($Private:Index[$Private:Key])

				ForEach ($Private:E in $Private:Entries)
				{
					If ($Private:E.Kind -eq 'param')
					{
						If (Test-UelSafeType $Private:E.Node.StaticType) { return 'typed' }
						ForEach ($Private:Attr in $Private:E.Node.Attributes)
						{
							If ($Private:Attr -is [System.Management.Automation.Language.AttributeAst] -and $Private:Attr.TypeName.Name -ieq 'ValidateSet')
							{
								$Private:Vals = @($Private:Attr.PositionalArguments | ForEach-Object { Get-UelConstText $_ })
								If ($Private:Vals.Count -gt 0 -and @($Private:Vals | Where-Object { $null -eq $_ -or $_ -match "[\u0027\u2018-\u201B]" }).Count -eq 0) { return 'validateset' }
							}
						}
					}
					ElseIf ($Private:E.Type -and (Test-UelSafeType $Private:E.Type)) { return 'typed' }
				}

				$Private:Assigns = @($Private:Entries | Where-Object { $_.Kind -eq 'assign' -and $_.Offset -lt $Use.Extent.StartOffset })
				If ($Private:Assigns.Count -eq 0) { return $null }
				$VisitKey = '{0}:{1}' -f [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Private:Scope), $Private:Key
				If (-not $Visited.Add($VisitKey)) { return $null }
				$Private:AllEscape = $true
				ForEach ($Private:A in $Private:Assigns)
				{
					If ($null -eq $Private:A.Node -or $Private:A.Node.Operator -ne 'Equals') { return $null }
					$Private:Why = Test-UelSafeArg $Private:A.Node.Right ($Depth + 1) $Visited
					If (-not $Private:Why) { return $null }
					If ($Private:Why -ne 'escape-call') { $Private:AllEscape = $false }
				}
				If ($Private:AllEscape) { return 'escape-call' }
				return 'safe-variable'
			}
			return $null
		}

		# Reason string when the argument cannot carry an unescaped quote into the literal, else $null.
		Function Test-UelSafeArg
		{
			Param ($N, [int]$Depth = 0, [System.Collections.Generic.HashSet[String]]$Visited)
			If ($null -eq $N -or $Depth -gt 6) { return $null }
			If ($null -eq $Visited) { $Visited = [System.Collections.Generic.HashSet[String]]::new() }
			If (Test-UelEscape $N) { return 'escape-call' }
			$N = Get-UelInner $N
			If ($null -eq $N) { return $null }
			Switch ($N.GetType().Name)
			{
				'StringConstantExpressionAst' { return 'constant' }
				'ConstantExpressionAst' { return 'constant' }
				'ExpandableStringExpressionAst' { If ($N.NestedExpressions.Count -eq 0) { return 'constant' }; return $null }
				'VariableExpressionAst'
				{
					$Private:VName = $N.VariablePath.UserPath
					If ($Private:VName -in 'true', 'false', 'null', 'PID') { return 'constant' }
					return (Test-UelVariable $N $Private:VName $Depth $Visited)
				}
				'IfStatementAst'
				{
					# $x = If (cond) { 'D' } Else { 'P' }: safe when every branch ends in a safe value.
					If (-not $N.ElseClause) { return $null }
					$Private:Blocks = @($N.Clauses | ForEach-Object { $_.Item2 }) + $N.ElseClause
					ForEach ($Private:B in $Private:Blocks)
					{
						If ($Private:B.Statements.Count -eq 0) { return $null }
						$Private:Tail = $Private:B.Statements[$Private:B.Statements.Count - 1]
						If (-not (Test-UelSafeArg $Private:Tail ($Depth + 1) $Visited)) { return $null }
					}
					return 'safe-variable'
				}
				'ConvertExpressionAst'
				{
					If (Test-UelSafeType $N.StaticType) { return 'typed' }
					If ($N.StaticType -eq [string]) { return (Test-UelSafeArg $N.Child ($Depth + 1) $Visited) }
					return $null
				}
				'PipelineAst'
				{
					$Private:Last = $N.PipelineElements[$N.PipelineElements.Count - 1]
					return (Test-UelSafeArg $Private:Last ($Depth + 1) $Visited)
				}
				'CommandAst'
				{
					$Private:CName = $N.GetCommandName()
					If ($Private:CName -and $Private:CName -in 'Get-Date', 'New-Guid', 'Get-Random') { return 'safe-command' }
					return $null
				}
				'InvokeMemberExpressionAst'
				{
					If ($N.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return $null }
					If ($N.Static -and $N.Member.Value -ieq 'NewGuid') { return 'typed' }
					If ($N.Member.Value -ieq 'ToString' -and $N.Arguments.Count -ge 1)
					{
						$Private:Spec = Get-UelConstText $N.Arguments[0]
						If ($null -ne $Private:Spec -and ($Private:Spec -match '^[A-Za-z][0-9]{0,3}$' -or $Private:Spec -match '^[yMdHhmsfFtzgK:/. ,-]+$')) { return 'formatted' }
					}
					return $null
				}
				'MemberExpressionAst'
				{
					If ($N.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $N.Member.Value -in 'Count', 'Length', 'Ticks') { return 'numeric' }
					return $null
				}
				'BinaryExpressionAst'
				{
					If ($N.Operator -in 'Minus', 'Multiply', 'Divide', 'Rem') { return 'numeric' }
					If ($N.Operator -eq 'Plus' -and (Test-UelSafeArg $N.Left ($Depth + 1) $Visited) -and (Test-UelSafeArg $N.Right ($Depth + 1) $Visited)) { return 'safe-variable' }
					return $null
				}
			}
			return $null
		}

		# Argument nodes of a -f right-hand side: the elements of a list, or the single value.
		Function Get-UelArgList
		{
			Param ($Right)
			$Private:R = Get-UelInner $Right
			If ($Private:R -is [System.Management.Automation.Language.ArrayLiteralAst]) { return , @($Private:R.Elements) }
			If ($Private:R -is [System.Management.Automation.Language.ArrayExpressionAst] -and $Private:R.SubExpression.Statements.Count -eq 1)
			{
				$Private:Inner = Get-UelInner $Private:R.SubExpression.Statements[0]
				If ($Private:Inner -is [System.Management.Automation.Language.ArrayLiteralAst]) { return , @($Private:Inner.Elements) }
			}
			return , @($Right)
		}

		# Indexes of the placeholders that sit directly between two single quotes: '{n}'.
		Function Get-UelQuotedIndex
		{
			Param ([String]$Text)
			$Private:Out = [System.Collections.Generic.List[int]]::new()
			ForEach ($Private:M in $Script:UelPlaceholder.Matches($Text))
			{
				If (-not $Private:M.Groups[1].Success) { Continue }
				$Private:I = $Private:M.Index
				$Private:Next = $Private:I + $Private:M.Length
				If ($Private:I -gt 0 -and $Private:Next -lt $Text.Length -and $Text[$Private:I - 1] -ceq [char]39 -and $Text[$Private:Next] -ceq [char]39)
				{ $Private:N = [int]$Private:M.Groups[1].Value; If (-not $Private:Out.Contains($Private:N)) { $Private:Out.Add($Private:N) } }
			}
			return , $Private:Out.ToArray()
		}

		# True when the whole -f result is only displayed or thrown (argument of a display command, or of throw).
		Function Test-UelDisplay
		{
			Param ($Site, [String[]]$Names)
			$Private:Cur = $Site
			$Private:Climb = 'ParenExpressionAst', 'CommandExpressionAst', 'ArrayLiteralAst', 'ArrayExpressionAst', 'SubExpressionAst', 'ExpandableStringExpressionAst', 'PipelineAst', 'ConvertExpressionAst'
			While ($Private:Cur.Parent)
			{
				$Private:P = $Private:Cur.Parent
				$Private:T = $Private:P.GetType().Name
				If ($Private:T -eq 'CommandAst') { $Private:Nm = $Private:P.GetCommandName(); return [bool]($Private:Nm -and ($Names -contains $Private:Nm)) }
				If ($Private:T -eq 'ThrowStatementAst') { return $true }
				If ($Private:T -eq 'PipelineAst')
				{
					$Private:Seen = $false
					ForEach ($Private:El in $Private:P.PipelineElements)
					{
						If ($Private:Seen -and $Private:El -is [System.Management.Automation.Language.CommandAst])
						{ $Private:En = $Private:El.GetCommandName(); If ($Private:En -and ($Names -contains $Private:En)) { return $true } }
						If ([object]::ReferenceEquals($Private:El, $Private:Cur)) { $Private:Seen = $true }
					}
				}
				ElseIf ($Private:T -eq 'BinaryExpressionAst' -and $Private:P.Operator -ne 'Plus') { return $false }
				ElseIf ($Private:T -ne 'BinaryExpressionAst' -and $Private:T -notin $Private:Climb) { return $false }
				$Private:Cur = $Private:P
			}
			return $false
		}

		# Format text of a site: a constant, or a variable with exactly one constant assignment before the site.
		Function Get-UelFormatText
		{
			Param ($Fmt, $Site)
			$Private:Text = Get-UelConstText $Fmt
			If ($null -ne $Private:Text) { return $Private:Text }
			$Private:F = Get-UelInner $Fmt
			If ($Private:F -isnot [System.Management.Automation.Language.VariableExpressionAst]) { return $null }
			$Private:Key = Get-UelVarKey $Private:F.VariablePath.UserPath
			ForEach ($Private:Scope in (Get-UelScopeChain $Site))
			{
				$Private:Index = Get-UelScopeIndex $Private:Scope
				If (-not $Private:Index.ContainsKey($Private:Key)) { Continue }
				$Private:Assigns = @($Private:Index[$Private:Key] | Where-Object { $_.Kind -eq 'assign' -and $_.Offset -lt $Site.Extent.StartOffset })
				If ($Private:Assigns.Count -ne 1 -or $null -eq $Private:Assigns[0].Node -or $Private:Assigns[0].Node.Operator -ne 'Equals') { return $null }
				return (Get-UelConstText $Private:Assigns[0].Node.Right)
			}
			return $null
		}
	}

	Process
	{
		ForEach ($Private:P in $Path)
		{
			If (-not (Test-Path -LiteralPath $Private:P)) { $Script:UelSkipped.Add(('{0} (path not found)' -f $Private:P)); Continue }
			$Private:Root = (Resolve-Path -LiteralPath $Private:P).ProviderPath
			$Private:IsDir = Test-Path -LiteralPath $Private:Root -PathType Container
			$Private:Files = @(Get-PSHGScanFile -Path $Private:Root -ExcludePattern $Script:UelExclude -Problem $Script:UelSkipped)
			$Private:Base = If ($Private:IsDir) { $Private:Root } Else { [System.IO.Path]::GetDirectoryName($Private:Root) }

			ForEach ($Private:File in $Private:Files)
			{
				$Private:Rel = If ($Private:File.StartsWith($Private:Base, [StringComparison]::OrdinalIgnoreCase)) { $Private:File.Substring($Private:Base.Length).TrimStart('\') } Else { $Private:File }
				If ([String]::IsNullOrEmpty($Private:Rel)) { $Private:Rel = Split-Path -Leaf $Private:File }
				If ($Private:IsDir -and -not $IncludeTests -and $Private:Rel -match '(^|\\)Tests\\|\.Tests\.ps1$') { Continue }

				$Script:UelFileCount++
				$Private:Parsed = Read-PSHGAst -File $Private:File
				If (-not $Private:Parsed.Ok)
				{ $Script:UelSkipped.Add(('{0} ({1})' -f $Private:File, $Private:Parsed.Reason)); If (-not $Private:Parsed.Ast) { Continue } }   # a partial tree is still scanned

				$Script:UelCache.Clear()
				$Private:Sites = $Private:Parsed.Ast.FindAll({
						Param($N)
						($N -is [System.Management.Automation.Language.BinaryExpressionAst] -and $N.Operator -eq 'Format') -or
						($N -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $N.Static -and
						$N.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $N.Member.Value -ieq 'Format' -and
						$N.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and $N.Expression.TypeName.FullName -in 'string', 'System.String')
					}, $true)

				ForEach ($Private:S in $Private:Sites)
				{
					$Private:Fmt = $null; $Private:ArgNodes = $null; $Private:Via = '-f'
					If ($Private:S -is [System.Management.Automation.Language.BinaryExpressionAst])
					{ $Private:Fmt = $Private:S.Left; $Private:ArgNodes = Get-UelArgList $Private:S.Right }
					Else
					{
						$Private:Via = 'Format'
						$Private:A = @($Private:S.Arguments)
						If ($Private:A.Count -eq 0) { Continue }
						$Private:Skip = 0
						If ($null -eq (Get-UelConstText $Private:A[0]) -and $Private:A.Count -ge 2 -and $null -ne (Get-UelConstText $Private:A[1])) { $Private:Skip = 1 }   # leading IFormatProvider
						$Private:Fmt = $Private:A[$Private:Skip]
						$Private:Rest = @($Private:A | Select-Object -Skip ($Private:Skip + 1))
						If ($Private:Rest.Count -eq 1) { $Private:ArgNodes = Get-UelArgList $Private:Rest[0] } Else { $Private:ArgNodes = $Private:Rest }
					}

					$Private:Text = Get-UelFormatText $Private:Fmt $Private:S
					If ($null -eq $Private:Text) { Continue }
					$Private:Quoted = (Get-UelQuotedIndex $Private:Text)
					If ($Private:Quoted.Count -eq 0) { Continue }

					If (-not $IncludeDisplay -and (Test-UelDisplay $Private:S $DisplayCommand)) { $Script:UelDisplaySkipped++; Continue }

					ForEach ($Private:Idx in $Private:Quoted)
					{
						If ($Private:Idx -ge @($Private:ArgNodes).Count) { Continue }
						$Private:Arg = @($Private:ArgNodes)[$Private:Idx]
						If (Test-UelSafeArg $Private:Arg) { Continue }

						$Private:Inner = Get-UelInner $Private:Arg
						$Private:Kind = 'value'
						If ($Private:Inner -is [System.Management.Automation.Language.VariableExpressionAst] -and $Private:Inner.VariablePath.UserPath -match '(Esc|Escaped|ForCb)$') { $Private:Kind = 'name-only' }

						$Script:UelFindings.Add([PSCustomObject]@{
								File  = $Private:Rel
								Line  = $Private:S.Extent.StartLineNumber
								Arg   = $Private:Idx
								Kind  = $Private:Kind
								Via   = $Private:Via
								Value = (($Private:Arg.Extent.Text -split "`r?`n")[0].Trim())
								Text  = (($Private:S.Extent.Text -split "`r?`n")[0].Trim())
								Path  = $Private:File
							})
					}
				}
			}
		}
	}

	End
	{
		$Private:Found = @($Script:UelFindings | Sort-Object Path, Line, Arg)
		If (-not $Quiet) { Write-Host ('Scanned {0} file(s) for unescaped values inside quoted format placeholders...' -f $Script:UelFileCount) -ForegroundColor Cyan }

		Write-PSHGSkipReport -Skipped $Script:UelSkipped

		If ($Csv -and $Found.Count -gt 0)
		{
			$Found | Select-Object File, Line, Arg, Kind, Value, Text | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
			Write-Host ('CSV: {0} row(s) -> {1}' -f $Found.Count, $Csv) -ForegroundColor DarkGray
		}

		If (-not $Quiet -and $Script:UelDisplaySkipped -gt 0)
		{ Write-Host ('{0} display-only format site(s) skipped (-IncludeDisplay lists them).' -f $Script:UelDisplaySkipped) -ForegroundColor DarkGray }

		If ($Found.Count -eq 0)
		{
			If ($Script:UelSkipped.Count -gt 0)
			{ Write-Host ('NOT CLEAN - no findings, but {0} path(s)/file(s) were not checked.' -f $Script:UelSkipped.Count) -ForegroundColor Red; $Global:LASTEXITCODE = 2; return }
			Write-Host 'PASS - no unescaped value inside a quoted format placeholder found.' -ForegroundColor Green
			$Global:LASTEXITCODE = 0; return
		}

		Write-Host ''
		ForEach ($F in $Found)
		{
			Write-Host ('  {0}:{1}  arg{2}: {3}  [{4}]' -f $F.File, $F.Line, $F.Arg, $F.Value, $F.Kind) -ForegroundColor Red
			Write-Host ('    {0}' -f $F.Text) -ForegroundColor DarkGray
			If (-not $Quiet)
			{
				Write-Host '    Review: is this value ever user/disk controlled, and is the result parsed as PowerShell or as a data file? If so, an apostrophe in the value ends the literal early; wrap it in Format-EscapedLiteral.' -ForegroundColor Yellow
				If ($F.Kind -eq 'name-only') { Write-Host '    The name looks like an escaped variable, but no escape call was found in its assignment in this function - verify it.' -ForegroundColor Yellow }
			}
			If ($PassThru) { $F }
		}
		Write-Host ''
		Write-Host ('REVIEW - {0} site(s) to review (a lead list, not a verdict).' -f $Found.Count) -ForegroundColor Red
		$Global:LASTEXITCODE = 1; return
	}
}
