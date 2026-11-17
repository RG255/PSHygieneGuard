# PSHG-TestUnescapedLiteral - user guide

Finds values that are put inside a single-quoted literal of a `-f` format string with **no escaping at all**.

It is a **lead finder, not a verdict**. Every site it lists is a question: *is this value ever user or disk controlled, and is
the result parsed as PowerShell or as a data file?* If both are true, an apostrophe in the value is a bug.

## The problem, in thirty seconds

Code that generates a command, or a data file that is read back later, often does this:

```powershell
$Cmd  = "Set-Thing -Path '{0}'" -f $Path
$Data = "@{{ Path = '{0}' }}" -f $Path
```

It works until `$Path` is `C:\Ray's disks\a.vhdx`: the apostrophe ends the literal early, the generated command fails, and with
a crafted value the rest of the value is executed as code (or, in the data file, fails to import and takes the setting with it).
Typographic quotes (U+2018 to U+201B) do the same thing, which is the separate problem
[PSHG-TestTypographicQuoteEscape](PSHG-TestTypographicQuoteEscape.md) looks for.

The fix is to double the whole quote class with one shared helper before the value goes between the quotes:

```powershell
$Cmd = "Set-Thing -Path '{0}'" -f (Format-EscapedLiteral $Path)
```

## What it reports

A `-f` expression, or a `[string]::Format(...)` call, whose format string has a placeholder **directly between two single
quotes** (`'{n}'`, also inside a here-string and beside doubled braces as in `"@{{ ... }}"`), and whose n-th argument is none
of the following.

| Argument | Counted as safe |
|---|---|
| a call to `Format-EscapedLiteral` (any case or module prefix, as an argument, through a pipeline, inside `( )` or `$( )`) | yes |
| `[Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent(...)`, or a `[Regex]::Replace` / `-replace` / `.Replace` expression that names a typographic quote | yes |
| a constant or literal (`'text'`, `42`, `$true`) | yes |
| a variable whose every assignment **before the site, in the same function**, is one of these safe forms | yes (a name such as `$PathEsc` proves nothing; the assignment is checked) |
| an `[int]`, `[guid]`, `[datetime]`, `[bool]`, enum ... value: a cast, a typed parameter, or a typed assignment | yes |
| a `[ValidateSet(...)]` parameter whose values hold no quote | yes |
| `.ToString('N')`, `.ToString('yyyy-MM-dd')` and other number/date/guid formats, `Get-Date`, `New-Guid`, `[guid]::NewGuid()`, `.Count`, `.Length` | yes |
| `If (c) { 'D' } Else { 'P' }` where every branch ends in a safe value | yes |
| anything else: a parameter, a property read (`$State.Path`), a method result, an unescaped variable | **reported** |

A variable named like an escaped one (`*Esc`, `*Escaped`, `*ForCb`) whose assignment is not an escape call is reported with
`Kind = name-only`: the name is a claim, not proof.

### Display text is skipped

When the whole `-f` result is only shown (an argument of `Write-Host`, `Write-Verbose`, `Write-Warning`, `Write-Debug`,
`Write-Information`, `Write-Error` or `Write-Progress`, piped to one of them, or the argument of `throw`), an apostrophe in
the value is harmless and the site is skipped; the verdict area says how many were skipped. `-IncludeDisplay` lists them too, and
`-DisplayCommand` adds your own logging command names.

## Running it

```powershell
PSHG-TestUnescapedLiteral -Path .\src                 # a file or a folder (recurses; .ps1 and .psm1)
Get-ChildItem .\src -Recurse -Filter *.ps1 | PSHG-TestUnescapedLiteral -Csv .\literals.csv
$LASTEXITCODE                                          # 0 clean, 1 sites to review, 2 not clean (a file could not be read or parsed)
```

`-Quiet` prints only the findings and the verdict; `-Csv` writes File, Line, Arg, Kind, Value and Text; `-PassThru` also emits
the findings as objects (`Arg` is the argument index, `Via` is `-f` or `Format`). Test files (a `Tests` folder, `*.Tests.ps1`) in
a scanned **folder** are skipped, because test fixtures build such strings on purpose; `-IncludeTests` scans them, and a test
file passed by name is always scanned. There is **no baseline and no marker comment**: every site is listed on every run.
Folders named `Original`, `Originals`, `_RetiredModules`, `.archive`, `_PlanningDocs` and `.git` are skipped. It uses the
PowerShell parser only, so it needs no PSScriptAnalyzer.

## What it cannot see (and where it over-reports)

* The format string must be a constant (also a `+` of constants, or a variable with exactly one constant assignment).
* A placeholder that is inside a literal but not **directly** between the quotes (`'{0}\sub'`), a double-quoted placeholder
  (`"{0}"`), and values interpolated into a double-quoted string (`"Set-Thing '$Path'"`) are not seen.
* A value escaped some other way (a private helper with another name, `Replace([char]39, ...)`) is reported; so is a value
  proven safe only by a check elsewhere (a regex-validated GUID, an enum checked by the caller) and a value that is a property
  or method result. Review those and, if the value really cannot hold a quote, leave the site.
* A message that is built with `-f`, stored, and displayed later (`$msg = ... -f $x; Write-Host $msg`), or added to a list, looks the same as a
  command string and is reported.
* A variable changed through `[ref]`, `-OutVariable` or a loop is judged by its plain assignments only; a variable defined
  outside the function is not followed.
* A `-f` whose right-hand side is a variable holding an array is not resolved.

## Examples

* Good: `Examples\Good\CorrectUnescapedLiteral.ps1` (an escaped path, a typed number, a fixed-choice value, a dated stamp in a data file).
