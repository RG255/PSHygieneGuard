# Escaping a value for a single-quoted literal: the whole quote class is doubled, so a typographic
# quote in the value cannot end the literal early. PSHG-TestTypographicQuoteEscape reports nothing here.

Function Format-EscapedLiteral
{
	Param ([String]$Value)

	# [ASCII quote + U+2018 U+2019 U+201A U+201B], built from char codes so the file stays ASCII.
	$Class = '[''{0}{1}{2}{3}]' -f [char]0x2018, [char]0x2019, [char]0x201A, [char]0x201B
	return [Regex]::Replace($Value, $Class, '$0$0')
}

# A chain that doubles the ASCII quote AND the typographic ones is also fine.
Function Format-QuotedChain
{
	Param ([String]$Value)

	return $Value.Replace("'", "''").Replace([string][char]0x2019, ([string][char]0x2019 * 2))
}
