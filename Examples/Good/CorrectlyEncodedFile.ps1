# Correct: UTF-8 WITH BOM. Safe under both Windows PowerShell 5.1 and PowerShell 7 regardless
# of whether the file ever gains a non-ASCII character later - an unconditional rule that
# cannot rot the way a "BOM only if needed" rule can.
# Compare against ..\Bad\MisencodedFile.ps1 - same content, different encoding only.
Write-Host 'This file correctly has a BOM.'
