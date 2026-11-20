module ir

// A call, a global_addr or a func_addr may name a symbol the file declares
// later. The parser reads the whole module first and resolves the names after,
// the way a linker does, and refuses a name that is never declared.

fn forward_text() string {
	return 'target 64 little 8
fn @first(%arg0: i64) -> i64 {
block0:
  %v0 = call @second(%arg0)
  %v1 = global_addr @later
  return %v0
}

fn @second(%arg0: i64) -> i64 {
block0:
  %v0 = func_addr @third
  %v1 = call @first(%arg0)
  return %arg0
}

fn @third(%arg0: i64) -> i64 {
block0:
  return %arg0
}

global @later: 8 bytes align 8
'
}

fn test_a_call_to_a_later_function_resolves() {
	m := parse_text(forward_text()) or { panic('${err.msg()}') }
	first := m.functions[0]
	call := first.blocks[0].instructions[0]
	assert call.opcode == .call
	assert call.operands[0].name == 'second'
	assert call.operands[0].sym == .function
	assert call.operands[0].idx == 1
	assert call.signature.params == [ty_i64]
	assert call.signature.results == [ty_i64]
	assert first.values[call.results[0]].typ == ty_i64
}

fn test_a_global_addr_to_a_later_global_resolves() {
	m := parse_text(forward_text()) or { panic('${err.msg()}') }
	global_addr := m.functions[0].blocks[0].instructions[1]
	assert global_addr.opcode == .global_addr
	assert global_addr.operands[0].name == 'later'
	assert global_addr.operands[0].sym == .global
	assert global_addr.operands[0].idx == 0
	assert m.functions[0].values[global_addr.results[0]].typ == ty_ptr
}

fn test_a_func_addr_resolves_and_a_recursive_call_resolves() {
	m := parse_text(forward_text()) or { panic('${err.msg()}') }
	second := m.functions[1]
	func_addr := second.blocks[0].instructions[0]
	assert func_addr.operands[0].name == 'third'
	assert func_addr.operands[0].sym == .function
	assert func_addr.operands[0].idx == 2
	recursive := second.blocks[0].instructions[1]
	assert recursive.operands[0].name == 'first'
	assert recursive.operands[0].idx == 0
}

fn test_a_symbol_that_is_never_declared_is_refused() {
	text := 'target 64 little 8
fn @f(%arg0: i64) -> i64 {
block0:
  %v0 = call @nowhere(%arg0)
  return %v0
}
'
	m := parse_text(text) or {
		assert err is ParseError
		e := err as ParseError
		assert e.line == 4
		assert e.col == 14
		assert e.message.contains("unknown symbol '@nowhere'")
		return
	}
	assert false, 'the call to @nowhere parsed (${m.functions.len} functions)'
}

fn test_a_global_addr_to_a_function_is_not_a_parse_error() {
	// Whether a name is a function or a global is the verifier's rule (V012 and
	// V020). The parser resolves the name and records what it found.
	text := 'target 64 little 8
fn @f() -> ptr {
block0:
  %v0 = global_addr @f
  return %v0
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	operand := m.functions[0].blocks[0].instructions[0].operands[0]
	assert operand.name == 'f'
	assert operand.sym == .function
}

fn test_a_declaration_and_a_definition_of_one_name_both_resolve() {
	text := 'target 64 little 8
extern fn @puts(%arg0: ptr) -> i32

fn @puts(%arg0: ptr) -> i32 {
block0:
  %v0 = iconst i32 0
  return %v0
}

fn @f(%arg0: ptr) -> i32 {
block0:
  %v0 = call @puts(%arg0)
  return %v0
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	assert m.functions.len == 3
	assert m.functions[0].defined == false
	assert m.functions[1].defined
	call := m.functions[2].blocks[0].instructions[0]
	assert call.operands[0].idx == 0
}

fn test_an_indirect_call_signature_with_no_parenthesized_results() {
	text := 'target 64 little 8
fn @f(%arg0: ptr) {
block0:
  %v0 = call_indirect %arg0 : (i32) -> i32 ()
  tailcall_indirect %arg0 : (i32) ()
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	f := m.functions[0]
	call := f.blocks[0].instructions[0]
	assert call.signature.params == [ty_i32]
	assert call.signature.results == [ty_i32]
	term := f.blocks[0].terminator
	assert term.opcode == .tailcall_indirect
	assert term.signature.results.len == 0
}
