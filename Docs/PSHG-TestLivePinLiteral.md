# PSHG-TestLivePinLiteral - user guide

Finds a literal version pin on a module that publishes its live version in a data file.

## The problem, in thirty seconds

Some codebases keep one small file per module saying which version folder is live:

```powershell
# <ModulesRoot>\NamedPipe\LiveVersion.psd1
@{
	Module      = 'NamedPipe'
	LiveVersion = '0.18'
}
```

A caller that asks the file (a resolver such as `Get-LiveModuleVersion`) follows the next branch for free. A caller that writes the
version out keeps loading the old one until somebody remembers to change it:

```powershell
Import-Module NamedPipe -RequiredVersion 0.17                       # reported: the live version moved on
Open-MyElevatedSession -ModuleName 'VaultTools' -ModuleVersion '0.7'  # reported
$Cmd = "Import-Module VaultTools -RequiredVersion 0.7; Do-It"         # reported (kind InString): a script text built for a child process
Import-Module NamedPipe -RequiredVersion $LiveVersion               # not reported: not a literal
```

## What it reports

A command found by the parser (comments, help text and variables never match) whose module has a `LiveVersion.psd1` under the modules root
and whose version is a literal. Each site carries `File`, `Line`, `Module`, `Version`, the module's `Live` version, `Kind`
(`Import`, `Elevated`, `InString`), `Frozen`, `Self`, `Accepted`.

Skipped by default:

* **Frozen code**: a file in a version folder that is not the newest of its module under the modules root. Older versions are backstops
  that keep their literals. `-IncludeFrozen` reports them too (`Frozen = true`).
* **Self references**: a file of module X importing X itself (its own tests and helpers); those are derived from the running module, not read
  from the file. `-IncludeSelf` reports them (`Self = true`).

## Running it

```powershell
PSHG-TestLivePinLiteral -Path .\Modules\VHDTools\0.13 -BaselinePath .\LivePin-Baseline.psd1
PSHG-TestLivePinLiteral -Path . -IncludeFrozen -PassThru -Quiet        # every site as objects
$LASTEXITCODE                                                           # 0 no new site, 1 a new site, 2 could not run reliably
```

The modules root (the folder holding `<Module>\LiveVersion.psd1`) is found by walking up from the first path, or given with `-ModulesRoot`.
Paths in the report and baseline are relative to `-RepoRoot` (default: the parent of the modules root).

## Baseline

`-BaselinePath` names a `.psd1` of accepted sites, `@{ Entries = @( 'LivePinLiteral|<relative path>|<Module>|<Kind>' ) }`. A line number is never
part of a key, so editing above a site does not make it new; two sites of the same kind on the same module in one file share one entry.
`-UpdateBaseline` writes every current site (a BOM file). `-All` also lists the accepted ones.

## What it cannot see

A module name or version built at run time, a `ModuleToLoad` hashtable, and pins in data files other than the commands above.
It needs no PSScriptAnalyzer.
