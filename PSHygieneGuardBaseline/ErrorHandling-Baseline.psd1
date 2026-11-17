# Accepted silent-failure findings - triaged and judged NOT to be defects.
#
# Key: Rule|VersionAgnosticPath|Function|ContentHash    Value: WHY it is accepted.
#
# The hash covers the JUDGED CONSTRUCT (catch body, param block, if-condition),
# whitespace-normalised. Reformatting does not lapse an entry; CHANGING the construct
# does - the finding then returns for re-triage rather than staying silently accepted.
# Prefer an inline "# SILENT-OK: <reason>" comment when the reason belongs with the code.
#
# This is the SHIPPED, EMPTY template - populate it by running
# PSHG-InvokeSilentFailureSweep -UpdateBaseline against your own codebase, then replace
# each generated placeholder reason with a real one (BY DESIGN / FALSE POSITIVE / a real
# fix) before trusting a clean run - see Examples\Baselining\README.md and
# Examples\Baselining\SampleBaselineEntry.psd1 for a fully-worked example.
#
# Regenerate: PSHG-InvokeSilentFailureSweep -UpdateBaseline
@{
}
