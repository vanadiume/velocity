module ir

// The lexical layer of ir-text.md. Whitespace separates tokens, a newline
// separates declarations and instructions, and `;` starts a comment that runs
// to the end of the line. Every token carries the line and column it started
// at, which is what a parse error reports.

const max_u128 = u128(340282366920938463463374607431768211455)

enum TokenKind {
	eof
	newline
	ident
	number
	str
	value
	symbol
	punct
}

struct Token {
	kind     TokenKind
	text     string // the identifier, the punct, the decoded string, or the digits
	num      u128   // the value of a number token, as a 128-bit two's complement
	hex      bool   // the number was written with a 0x prefix
	negative bool   // the number was written with a leading '-'
	line     int
	col      int
}

struct Tokenizer {
mut:
	text string
	pos  int
	line int
	col  int
}

fn is_digit(c u8) bool {
	return c >= `0` && c <= `9`
}

fn is_hex_digit(c u8) bool {
	return is_digit(c) || (c >= `a` && c <= `f`) || (c >= `A` && c <= `F`)
}

fn hex_digit_value(c u8) u8 {
	if is_digit(c) {
		return c - `0`
	}
	if c >= `a` && c <= `f` {
		return c - `a` + 10
	}
	return c - `A` + 10
}

fn is_ident_start(c u8) bool {
	return (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`) || c == `_`
}

fn is_ident_continue(c u8) bool {
	return is_ident_start(c) || is_digit(c) || c == `.`
}

fn tokenize(text string) ![]Token {
	mut t := Tokenizer{
		text: text
		line: 1
		col:  1
	}
	mut tokens := []Token{cap: text.len / 4 + 8}
	for t.pos < t.text.len {
		c := t.text[t.pos]
		if c == ` ` || c == `\t` || c == `\r` {
			t.pos++
			t.col++
			continue
		}
		if c == `\n` {
			tokens << Token{
				kind: .newline
				line: t.line
				col:  t.col
			}
			t.pos++
			t.line++
			t.col = 1
			continue
		}
		if c == `;` {
			for t.pos < t.text.len && t.text[t.pos] != `\n` {
				t.pos++
				t.col++
			}
			continue
		}
		if c == `"` {
			tokens << t.scan_string()!
			continue
		}
		if c == `%` {
			tokens << t.scan_sigil(.value)!
			continue
		}
		if c == `@` {
			tokens << t.scan_sigil(.symbol)!
			continue
		}
		if is_digit(c) || (c == `-` && t.pos + 1 < t.text.len && (is_digit(t.text[t.pos + 1])
			|| (t.text[t.pos + 1] == `0` && t.pos + 2 < t.text.len && (t.text[t.pos + 2] == `x`
				|| t.text[t.pos + 2] == `X`)))) {
			tokens << t.scan_number()!
			continue
		}
		if is_ident_start(c) {
			tokens << t.scan_ident()
			continue
		}
		match c {
			`:` {
				tokens << t.punct(':')
			}
			`,` {
				tokens << t.punct(',')
			}
			`(` {
				tokens << t.punct('(')
			}
			`)` {
				tokens << t.punct(')')
			}
			`{` {
				tokens << t.punct('{')
			}
			`}` {
				tokens << t.punct('}')
			}
			`[` {
				tokens << t.punct('[')
			}
			`]` {
				tokens << t.punct(']')
			}
			`<` {
				tokens << t.punct('<')
			}
			`>` {
				tokens << t.punct('>')
			}
			`=` {
				tokens << t.punct('=')
			}
			`-` {
				if t.pos + 1 < t.text.len && t.text[t.pos + 1] == `>` {
					tokens << Token{
						kind: .punct
						text: '->'
						line: t.line
						col:  t.col
					}
					t.pos += 2
					t.col += 2
				} else {
					return ParseError{
						line:    t.line
						col:     t.col
						message: "unexpected character '-'"
					}
				}
			}
			else {
				return ParseError{
					line:    t.line
					col:     t.col
					message: "unexpected character '${c.ascii_str()}'"
				}
			}
		}
	}
	tokens << Token{
		kind: .eof
		line: t.line
		col:  t.col
	}
	return tokens
}

fn (mut t Tokenizer) punct(text string) Token {
	token := Token{
		kind: .punct
		text: text
		line: t.line
		col:  t.col
	}
	t.pos++
	t.col++
	return token
}

fn (mut t Tokenizer) scan_ident() Token {
	start := t.pos
	for t.pos < t.text.len && is_ident_continue(t.text[t.pos]) {
		t.pos++
		t.col++
	}
	return Token{
		kind: .ident
		text: t.text[start..t.pos]
		line: t.line
		col:  t.col - (t.pos - start)
	}
}

// scan_sigil reads a value name after `%` or a symbol name after `@`. A value
// may be named anything the ident rule accepts; the printer renumbers it.
fn (mut t Tokenizer) scan_sigil(kind TokenKind) !Token {
	line := t.line
	col := t.col
	sigil := if kind == .value { '%' } else { '@' }
	t.pos++
	t.col++
	start := t.pos
	for t.pos < t.text.len && is_ident_continue(t.text[t.pos]) {
		t.pos++
		t.col++
	}
	if t.pos == start {
		return ParseError{
			line:    line
			col:     col
			message: "expected a name after '${sigil}'"
		}
	}
	return Token{
		kind: kind
		text: t.text[start..t.pos]
		line: line
		col:  col
	}
}

fn (mut t Tokenizer) scan_number() !Token {
	line := t.line
	col := t.col
	mut negative := false
	if t.text[t.pos] == `-` {
		negative = true
		t.pos++
		t.col++
	}
	mut start := t.pos
	mut value := u128(0)
	mut digits := 0
	mut is_hex := false
	if t.pos + 1 < t.text.len && t.text[t.pos] == `0` && (t.text[t.pos + 1] == `x`
		|| t.text[t.pos + 1] == `X`) {
		is_hex = true
		t.pos += 2
		t.col += 2
		start = t.pos
		for t.pos < t.text.len && is_hex_digit(t.text[t.pos]) {
			if value > max_u128 / 16 {
				return ParseError{
					line:    line
					col:     col
					message: 'integer literal does not fit in 128 bits'
				}
			}
			value = value * 16 + u128(hex_digit_value(t.text[t.pos]))
			t.pos++
			t.col++
			digits++
		}
		if digits == 0 {
			return ParseError{
				line:    line
				col:     col
				message: "expected a hex digit after '0x'"
			}
		}
	} else {
		for t.pos < t.text.len && is_digit(t.text[t.pos]) {
			digit := u128(t.text[t.pos] - `0`)
			// The last digit is the only one that may land on the maximum: a
			// plain `value > max / 10` refuses 2^128 - 1 itself.
			if value > max_u128 / 10 || (value == max_u128 / 10 && digit > max_u128 % 10) {
				return ParseError{
					line:    line
					col:     col
					message: 'integer literal does not fit in 128 bits'
				}
			}
			value = value * 10 + digit
			t.pos++
			t.col++
			digits++
		}
		if digits == 0 {
			return ParseError{
				line:    line
				col:     col
				message: "expected a digit after '-'"
			}
		}
	}
	if negative {
		// A negative immediate is held as its two's complement pattern, so the
		// bits that reach an N-bit value are the ones the text meant.
		value = u128(0) - value
	}
	return Token{
		kind:     .number
		text:     t.text[start..t.pos]
		num:      value
		hex:      is_hex
		negative: negative
		line:     line
		col:      col
	}
}

fn (mut t Tokenizer) scan_string() !Token {
	line := t.line
	col := t.col
	t.pos++ // the opening quote
	t.col++
	mut bytes := []u8{}
	for {
		if t.pos >= t.text.len {
			return ParseError{
				line:    line
				col:     col
				message: 'unterminated string'
			}
		}
		c := t.text[t.pos]
		if c == `"` {
			t.pos++
			t.col++
			return Token{
				kind: .str
				text: bytes.bytestr()
				line: line
				col:  col
			}
		}
		if c == `\n` {
			return ParseError{
				line:    line
				col:     col
				message: 'unterminated string'
			}
		}
		if c != `\\` {
			bytes << c
			t.pos++
			t.col++
			continue
		}
		escape_line := t.line
		escape_col := t.col
		t.pos++ // the backslash
		t.col++
		if t.pos >= t.text.len {
			return ParseError{
				line:    line
				col:     col
				message: 'unterminated string'
			}
		}
		escape := t.text[t.pos]
		match escape {
			`\\` {
				bytes << u8(`\\`)
			}
			`"` {
				bytes << u8(`"`)
			}
			`n` {
				bytes << u8(10)
			}
			`t` {
				bytes << u8(9)
			}
			`0` {
				bytes << u8(0)
			}
			`x` {
				if t.pos + 2 >= t.text.len || !is_hex_digit(t.text[t.pos + 1])
					|| !is_hex_digit(t.text[t.pos + 2]) {
					return ParseError{
						line:    escape_line
						col:     escape_col
						message: 'expected two hex digits after \\x'
					}
				}
				bytes << hex_digit_value(t.text[t.pos + 1]) * 16 + hex_digit_value(t.text[t.pos + 2])
				t.pos += 2
				t.col += 2
			}
			else {
				return ParseError{
					line:    escape_line
					col:     escape_col
					message: "unknown escape '\\${escape.ascii_str()}'"
				}
			}
		}
		t.pos++
		t.col++
	}
	return error('unreachable')
}
