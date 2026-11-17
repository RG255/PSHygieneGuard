# PSHG-TestTypographicQuoteEscape - user guide

Finds quote escaping that only knows the ASCII quote.

## The problem, in thirty seconds

PowerShell does not only treat `'` and `"` as quotes. The parser also accepts the typographic ones: U+2018, U+2019,
U+201A and U+201B as single quotes, and U+201C, U+201D and U+201E as double quotes. Code that builds text for PowerShell
to parse again (an elevated command, a `-Command` string, a generated script) and escapes a value like this:

```powershell
$Safe = $Value -replace "'", "''"
$Cmd  = "Set-Thing -Name '$Safe'"
```

works until a value contains a curly apostrophe (`Ray` + U+2019 + `s backup`): the parser reads it as the closing quote of
the literal, the rest of the value becomes code, and the command breaks - or, with a crafted value, runs what the value says,
with whatever rights the command has.

The fix is to double the whole quote class, in one shared helper rather than a hand-rolled replace at every call site:

```powershell
$Class = '[''{0}{1}{2}{3}]' -f [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B
$Safe  = [Regex]::Replace($Value, $Class, '$0$0')
```

## What it reports

A `-replace` / `-creplace` / `-ireplace`, a `.Replace(a, b)` call, or a `[regex]::Replace(input, a, b)` call where

* the pattern (first argument) is exactly the ASCII single quote and the replacement is two single quotes, or
* the pattern is exactly the ASCII double quote and the replacement is two double quotes or a backtick and a double quote,

and the chained expression it belongs to does not also name a typographic quote of that kind (the character itself, a
`0x2018`-style or `‘`-style code, or the decimal code point). A character-class pattern such as the one above is not
"exactly the ASCII quote", so the fixed form passes.

| Written as | Reported |
|---|---|
| `$v -replace "'", "''"` | yes |
| `$v.Replace("'", "''")` | yes |
| `[regex]::Replace($v, "'", "''")` | yes |
| `$v -replace '"', '""'` | yes |
| `$v.Replace("'", "''").Replace([string][char]0x2019, ...)` | no - the chain covers a typographic quote |
| `[Regex]::Replace($v, $Class, '$0$0')` | no |
| `$v -replace "'", ""` (removing quotes) | no - not doubling |

## Running it

```powershell
PSHG-TestTypographicQuoteEscape -Path .\src                 # a file or a folder (recurses; .ps1 and .psm1)
Get-ChildItem .\src -Recurse -Filter *.ps1 | PSHG-TestTypographicQuoteEscape -Csv .\quotes.csv
$LASTEXITCODE                                                # 0 clean, 1 findings, 2 not clean (a file could not be read or parsed)
```

`-Quiet` prints only the findings and the verdict; `-Csv` writes File, Line, Kind and Text; `-PassThru` also emits the
findings as objects. There is **no baseline and no marker comment**: every site is listed on every run, so existing ones stay
visible until the file they are in is next edited. Folders named `Original`, `Originals`, `_RetiredModules`, `.archive`,
`_PlanningDocs` and `.git` are skipped. It uses the PowerShell parser only, so it needs no PSScriptAnalyzer.

## What it cannot see

It looks at constant arguments only. A pattern or replacement held in a variable, a `-f` format used to build the
replacement, or a value that is escaped some other way (`Replace([char]39, ...)`) is not examined. Dashes are a related trap
(U+2013 to U+2015 are read as `-`) and are not checked.

## Examples

* Good: `Examples\Good\CorrectTypographicQuoteEscape.ps1` (the class form and a covering chain).
