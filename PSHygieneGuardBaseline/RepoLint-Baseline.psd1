<#
    Accepted PSScriptAnalyzer findings - the repo lint BASELINE.

    Each entry is RuleName|RelativePath|FunctionName (NO line number, so
    edits above a finding do not resurrect it). Test-RepoLint.ps1 reports
    only findings that are NOT listed here, so the rules stay ON for new
    code while existing accepted debt stays quiet.

    Do NOT hand-edit to silence something new - fix the code, or add it
    deliberately via -UpdateBaseline and say why in the commit/todo.

    This is the SHIPPED, EMPTY template - populate it by running
    Test-RepoLint.ps1 -UpdateBaseline against your own codebase, then
    replace each generated placeholder reason with a real one before
    trusting a clean run (see Examples\Baselining\README.md).

    Regenerated: (never - ships empty)
    Entries: 0
#>
@{
    Accepted = @(
    )
}
