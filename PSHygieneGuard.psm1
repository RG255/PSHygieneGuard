#requires -Version 5.0
#
# PSHygieneGuard.psm1
# PowerShell hygiene toolkit: baseline-gated lint, encoding enforcement, silent-failure
# detection, and a handful of narrow AST-based checkers for defect classes that parse
# cleanly and pass PSScriptAnalyzer but fail silently at runtime. Every function is
# self-contained (no vendored dependencies beyond the public PSScriptAnalyzer module).
#
# Functions are dot-sourced one-per-file from Functions\, matching this project's own
# convention for keeping one function per file.
#

Set-StrictMode -Off

$Private:FunctionsPath = Join-Path $PSScriptRoot 'Functions'

if (-not (Test-Path -LiteralPath $Private:FunctionsPath -PathType Container))
{ throw ('PSHygieneGuard: the Functions folder is missing ({0}); the module install is incomplete.' -f $Private:FunctionsPath) }

$Private:FunctionFiles = @(Get-ChildItem -LiteralPath $Private:FunctionsPath -Filter '*.ps1' -ErrorAction Stop)
if ($Private:FunctionFiles.Count -eq 0)
{ throw ('PSHygieneGuard: no function files found in {0}; the module install is incomplete.' -f $Private:FunctionsPath) }

foreach ($Private:File in $Private:FunctionFiles)
{ . $Private:File.FullName }
