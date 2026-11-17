# Putting a value between single quotes in a format string: every value is escaped first, or cannot
# contain a quote. PSHG-TestUnescapedLiteral reports nothing here.

Function Format-EscapedLiteral
{
	Param ([String]$Value)

	# [ASCII quote + U+2018 U+2019 U+201A U+201B], built from char codes so the file stays ASCII.
	$Class = '[''{0}{1}{2}{3}]' -f [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B
	return [Regex]::Replace($Value, $Class, '$0$0')
}

Function Format-SettingCommand
{
	Param (
		[String]$Path,
		[int]$Retries,
		[ValidateSet('Fast', 'Safe')][String]$Mode
	)

	# The path is escaped; the number and the fixed-choice value cannot hold a quote.
	$PathEsc = Format-EscapedLiteral $Path
	return ("Set-Thing -Path '{0}' -Retries '{1}' -Mode '{2}'" -f $PathEsc, $Retries, $Mode)
}

Function Format-SettingFile
{
	Param ([String]$Path)

	# A generated data file: the same rule applies.
	return ("@{{ Path = '{0}'; Stamp = '{1}' }}" -f (Format-EscapedLiteral $Path), (Get-Date -Format 'yyyy-MM-dd'))
}
