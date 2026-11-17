# PSHG-TestJoinPathDriveRoot - user guide

Finds `Join-Path` called on a **drive root that is built from a variable**. Such a call throws
`Cannot find drive. A drive with the name 'X' does not exist.` whenever that drive is not currently mounted -
which is usually exactly the situation the code was written for.

## The problem, in thirty seconds

`Join-Path` is not a string function. Before it joins anything it asks PowerShell's provider system whether the
drive named in `-Path` exists. If it does not, you get an error and no path:

```powershell
$Letter = 'Q'                                           # a USB stick that is not plugged in yet
Join-Path -Path ('{0}:\' -f $Letter) -ChildPath 'Rec'   # Cannot find drive. A drive with the name 'Q' does not exist.
```

Two things make this easy to miss:

* **It only fails when the drive is absent.** On the machine you wrote it on, the drive is there, and every test passes.
  It is found on the next machine, or the first time someone plugs the drive in *after* the session started (a running
  session does not always notice a drive that appeared later).
* **Without `-ErrorAction Stop` it is not even loud.** The error is non-terminating, `Join-Path` returns nothing, and the
  next line quietly works with an empty path. Under `$ErrorActionPreference = 'Stop'` it becomes a terminating error.

The fix is to build the string without asking about the drive:

```powershell
[System.IO.Path]::Combine(('{0}:\' -f $Letter), 'Rec')   # Q:\Rec - just a string, nothing is checked
```

## What it reports

A `Join-Path` call is reported when its `-Path` argument (named, or the first positional argument) is, or contains, a
string that **starts with a drive-root template**:

| Written as | Reported |
|---|---|
| `Join-Path -Path ('{0}:\' -f $Letter) -ChildPath $Rel` | yes |
| `Join-Path ('{0}:\' -f $Letter) $Rel` (positional) | yes |
| `Join-Path -Path "${Letter}:\Users" -ChildPath 'Public'` | yes |
| `Join-Path -Path "$($Letter):\Users" -ChildPath 'Public'` | yes |
| `Join-Path -Path 'C:\Temp' -ChildPath 'x'` (a literal drive) | no - a different question, see `PSHG-FindDriveLetterAssumption` |
| `Join-Path -Path $Base -ChildPath $Name` (a path held in a variable) | no - the checker cannot know what the variable holds |
| `Join-Path -Path $Base -ChildPath ('{0}:\' -f $L)` (template only in the child) | no |

## Running it

```powershell
PSHG-TestJoinPathDriveRoot -Path .\src          # a file, or a folder (recurses)
$LASTEXITCODE                                    # 0 = clean, 1 = at least one finding
```

Output is one block per finding: the file and line, the offending line, and the fix. There is no baseline - a hit is
either a bug or carries the marker below. Folders named `Original`, `Originals` and `_RetiredModules`, and `.git`, are
skipped. It uses the PowerShell parser only, so it needs no PSScriptAnalyzer.

## Fixing a finding

Replace `Join-Path` with `[System.IO.Path]::Combine(<root>, <child>)`. Two details:

* `Combine` takes the child **as given**: a child that starts with `\` or is rooted replaces the root instead of joining
  to it, and it does not normalise separators. Trim a leading `\` first (`$Rel.TrimStart('\')`) if the child can have one.
* For the parent folder of a path use `[System.IO.Path]::GetDirectoryName($Path)` (`Split-Path -Parent` is fine too -
  it is a pure string operation and does not check the drive).

## When a hit is legitimate

If the drive is known to exist - for example the system drive - say so on the same line and the checker skips it:

```powershell
Join-Path -Path ('{0}:\' -f $SystemLetter) -ChildPath $Rel # PSHG-OK: JoinPathDriveRoot - the system drive always exists
```

The marker covers only the line that carries it.

## What it cannot see

It looks at the *text of the argument*, so it misses the same bug when the root only arrives in a variable:

```powershell
$Root = '{0}:\vhd\BL' -f $Letter
Join-Path -Path $Root -ChildPath 'x'        # same failure, not reported
```

and a nested form such as `Join-Path (Join-Path (Split-Path $ConfigValue -Parent) 'a') 'b'`, where the drive comes from data.
For those, run the test suite on a machine that does not have the drive - that is how the two real cases that prompted this
checker were found. If you find another shape worth catching, add a fixture to `Examples\Bad.zip` and a test.

## Examples

* Bad: `Examples\Bad.zip` -> `JoinPathDriveRoot.ps1` (two functions; the checker reports both).
* Good: `Examples\Good\CorrectJoinPathDriveRoot.ps1` (the `Combine` form, a plain variable path, and a line carrying the marker).
* `Demo\Invoke-Demo.ps1` runs the checker against the extracted Bad example in its report-only section.
