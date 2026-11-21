module ir

import os

fn read_fixture(name string) string {
	path := os.join_path(@DIR, 'testdata', name)
	return os.read_file(path) or { panic('cannot read ${path}: ${err}') }
}

// Malformed text is refused with the line and the column, never with a panic.
// Each row is one thing the parser has to say no to.

const prelude = 'target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
'

struct BadText {
	name    string
	text    string
	line    int
	col     int
	message string
}

fn parse_error(text string) ParseError {
	m := parse_text(text) or {
		if err is ParseError {
			return err
		}
		panic('the failure was not a ParseError: ${err.msg()}')
	}
	panic('the text parsed without an error (${m.functions.len} functions)')
}

fn bad_cases() []BadText {
	return [
		BadText{'unknown opcode', prelude + '  %v0 = frobnicate %arg0\n}\n', 4, 9, "unknown opcode 'frobnicate'"},
		BadText{'missing operand', prelude + '  %v0 = iadd %arg0\n}\n', 4, 19, "expected an operand for 'iadd'"},
		BadText{'extra operand', prelude + '  %v0 = iadd %arg0, %arg0, %arg0\n}\n', 4, 26, "too many operands for 'iadd'"},
		BadText{'missing comma', prelude + '  %v0 = iadd %arg0 %arg0\n  return %v0\n}\n', 4, 20, "expected ','"},
		BadText{'truncated operand', prelude + '  %v0 = iadd %arg0,\n  return %arg0\n}\n', 4, 20, "expected an operand for 'iadd'"},
		BadText{'bad hex literal', prelude + '  %v0 = iconst i32 0x\n}\n', 4, 20, "expected a hex digit after '0x'"},
		BadText{'literal wider than 128 bits', prelude + '  %v0 = iconst i32 99999999999999999999999999999999999999999\n}\n', 4, 20, 'does not fit in 128 bits'},
		BadText{'unknown flag', prelude + '  %v0 = iadd bogus %arg0, %arg0\n}\n', 4, 14, "unknown flag 'bogus'"},
		BadText{'unknown predicate', prelude + '  %v0 = icmp almost %arg0, %arg0\n}\n', 4, 14, "unknown predicate 'almost'"},
		BadText{'duplicate block label', prelude + '  return %arg0\nblock0:\n  return %arg0\n}\n', 5, 1, "duplicate block label 'block0'"},
		BadText{'duplicate value name', prelude + '  %v0 = iadd %arg0, %arg0\n  %v0 = iadd %arg0, %arg0\n  return %v0\n}\n', 5, 3, "duplicate value '%v0'"},
		BadText{'unterminated string', prelude + '  %v0 = inline_asm "abc\n}\n', 4, 20, 'unterminated string'},
		BadText{'type i0', prelude + '  %v0 = poison i0\n}\n', 4, 16, "unknown type 'i0'"},
		BadText{'type i129', prelude + '  %v0 = poison i129\n}\n', 4, 16, "unknown type 'i129'"},
		BadText{'missing closing brace', prelude + '  return %arg0\n', 5, 1, "missing '}'"},
		BadText{'missing terminator', prelude + '  %v0 = iadd %arg0, %arg0\n}\n', 5, 1, "block 'block0' has no terminator"},
		BadText{'unknown value', prelude + '  return %nope\n}\n', 4, 10, "value '%nope' is used but never defined"},
		BadText{'unknown block', prelude + '  br block9()\n}\n', 4, 6, "unknown block 'block9'"},
		BadText{'unknown symbol', prelude + '  %v0 = call @nope(%arg0)\n  return %v0\n}\n', 4, 14, "unknown symbol '@nope'"},
		BadText{'missing target line', 'fn @f() {\nblock0:\n  return\n}\n', 1, 1, "expected the 'target' line first"},
		BadText{'bad endianness', 'target 64 middle 8\n', 1, 11, "expected 'little' or 'big'"},
		BadText{'load without an alignment', prelude + '  %v0 = load %arg0 : i32\n  return %arg0\n}\n', 4, 25, "expected 'align'"},
		BadText{'conversion without a target type', prelude + '  %v0 = zext %arg0 f64\n  return %v0\n}\n', 4, 20, "expected 'to'"},
		BadText{'wrong result count', prelude + '  %v0 = sadd_overflow %arg0, %arg0\n  return %arg0\n}\n', 4, 9, 'takes two results, found 1'},
		BadText{'direct call arity', 'target 64 little 8\nfn @g() -> (i32, i32) {\nblock0:\n  return\n}\nfn @f() {\nblock0:\n  %v0 = call @g()\n  return\n}\n', 8, 14, 'returns 2 results, found 1'},
		BadText{'global without an initializer', 'target 64 little 8\nglobal @g: i32 =\n', 2, 17, 'expected a constant'},
		BadText{'float leaf with a long pattern', 'target 64 little 8\nglobal @g: f32 = f32 0x3fc00000ff\n', 2, 22, 'has more than 8 hex digits'},
		BadText{'float leaf without a hex pattern', 'target 64 little 8\nglobal @g: f32 = f32 12\n', 2, 22, 'expected a hex bit pattern'},
		BadText{'array type without a closing bracket', 'target 64 little 8\nglobal @g: [4 x i32 = zeroinit\n', 2, 21, "expected ']'"},
		BadText{'unterminated constant list', 'target 64 little 8\nglobal @g: [2 x i32] = [1, 2\n', 2, 29, "expected ']'"},
		BadText{'unknown constant', 'target 64 little 8\nglobal @g: i32 = true\n', 2, 18, 'expected a constant'},
		BadText{'duplicate noundef', 'target 64 little 8\nfn @f(%a: i32 noundef noundef) {\nblock0:\n  return\n}\n', 2, 23, "expected ')'"},
		BadText{'unknown effect', 'target 64 little 8\nextern fn @f() -> i32 readonly bogus\n', 2, 32, 'expected the end of the line after the declaration'},
		BadText{'indirect signature without its arguments', prelude + '  %v0 = call_indirect %arg0 : (i32) -> i32 readonly\n  return %v0\n}\n', 4, 52, "expected '('"},
	]
}

fn test_malformed_text_reports_the_right_line_and_column() {
	for c in bad_cases() {
		e := parse_error(c.text)
		assert e.line == c.line, '${c.name}: reported line ${e.line}, expected ${c.line} (${e.msg()})'
		assert e.col == c.col, '${c.name}: reported column ${e.col}, expected ${c.col} (${e.msg()})'
		assert e.message.contains(c.message), '${c.name}: "${e.message}" does not name "${c.message}"'
	}
}

// A ParseError is what the parser returns, so a caller can read the position
// rather than a string.
fn test_the_error_carries_the_position() {
	e := parse_error('target 64 little 8\nfn @f() {\nblock0:\n  %v0 = nope\n  return\n}\n')
	assert e.line == 4
	assert e.col == 9
	assert e.msg().contains('line 4, column 9')
}

// Whatever the input, the parser answers with a value or an error. An empty
// file, a file of newlines, and a file that stops in the middle are all
// refusals rather than panics.
fn test_truncated_and_empty_input() {
	inputs := ['', '\n', '\n\n\n', 'target', 'target 64', 'target 64 little', 'target 64 little 8\nfn',
		'target 64 little 8\nfn @f', 'target 64 little 8\nfn @f(', 'target 64 little 8\nglobal @g:']
	for text in inputs {
		e := parse_error(text)
		assert e.line >= 1
		assert e.col >= 1
		assert e.message.len > 0
	}
}

// Every prefix of a canonical file is either a module or a refusal. This is the
// cheap way to be sure no truncation reaches an index out of bounds.
fn test_every_prefix_of_a_module_is_refused_or_read() {
	text := read_fixture('canonical.vel')
	for end in 0 .. text.len {
		prefix := text[..end]
		_ := parse_text(prefix) or { continue }
	}
}
