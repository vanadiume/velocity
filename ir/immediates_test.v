module ir

// Literals: integers in decimal, hex and negative form, floats as hex bit
// patterns, strings with the documented escapes, switch cases, and immediates
// passed to a jump.

fn parse_body(body string) Module {
	text := 'target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
  ${body}
  return %arg0
}
'
	return parse_text(text) or { panic('${err.msg()}') }
}

fn first_instruction(m Module) Instruction {
	return m.functions[0].blocks[0].instructions[0]
}

fn test_negative_immediate_is_masked_to_the_type() {
	inst := first_instruction(parse_body('%v0 = iconst i32 -1'))
	assert inst.opcode == .iconst
	assert inst.typ == ty_i32
	assert inst.operands[0].imm == u128(4294967295)
}

fn test_hex_immediate() {
	inst := first_instruction(parse_body('%v0 = iconst i64 0x7f'))
	assert inst.operands[0].imm == u128(127)
	inst2 := first_instruction(parse_body('%v0 = iconst i32 0xFFFFFFFF'))
	assert inst2.operands[0].imm == u128(4294967295)
}

fn test_i128_immediate() {
	inst := first_instruction(parse_body('%v0 = iconst i128 -1'))
	assert inst.typ == ty_i128
	assert inst.operands[0].imm == u128(340282366920938463463374607431768211455)
	largest := '170141183460469231731687303715884105727'
	inst2 := first_instruction(parse_body('%v0 = iconst i128 ${largest}'))
	assert inst2.operands[0].imm == u128(170141183460469231731687303715884105727)
}

// The largest value a u128 holds is the one a 128-bit literal may name, and one
// more than it is a bad literal rather than a wrapped one.
fn test_the_widest_literal() {
	inst := first_instruction(parse_body('%v0 = iconst i128 340282366920938463463374607431768211455'))
	assert inst.operands[0].imm == u128(340282366920938463463374607431768211455)
	text := 'target 64 little 8
fn @f() {
block0:
  %v0 = iconst i128 340282366920938463463374607431768211456
  return
}
'
	parse_text(text) or {
		assert err is ParseError
		e := err as ParseError
		assert e.line == 4
		assert e.col == 21
		assert e.message.contains('does not fit in 128 bits')
		return
	}
	assert false, 'a literal wider than 128 bits parsed'
}

fn test_a_narrow_width_keeps_its_low_bits() {
	inst := first_instruction(parse_body('%v0 = iconst i3 -1'))
	assert inst.typ == int_type(3)
	assert inst.operands[0].imm == u128(7)
	one := first_instruction(parse_body('%v0 = iconst i1 1'))
	assert one.operands[0].imm == u128(1)
}

// An immediate operand has no type of its own, so the parser keeps the 128-bit
// pattern and leaves the width to the verifier.
fn test_operand_immediates() {
	inst := first_instruction(parse_body('%v0 = iadd %arg0, -1'))
	assert inst.operands[1].kind == .int_imm
	assert inst.operands[1].imm == u128(340282366920938463463374607431768211455)
	hex := first_instruction(parse_body('%v0 = iadd %arg0, 0x10'))
	assert hex.operands[1].imm == u128(16)
}

fn test_float_immediate_is_a_hex_bit_pattern() {
	inst := first_instruction(parse_body('%v0 = fconst f32 0x3fc00000'))
	assert inst.opcode == .fconst
	assert inst.typ == ty_f32
	assert inst.operands[0].kind == .float_imm
	assert inst.operands[0].typ == ty_f32
	assert inst.operands[0].imm == u128(1069547520)
	double := first_instruction(parse_body('%v0 = fconst f64 0x3ff0000000000000'))
	assert double.operands[0].imm == u128(4607182418800017408)
	assert double.operands[0].typ == ty_f64
}

fn test_string_escapes() {
	// The IR string is "a\nb\t\"\\\0\x41": every escape ir-text.md lists.
	text := 'target 64 little 8
fn @f() {
block0:
  %v0 = inline_asm "a\\nb\\t\\"\\\\\\0\\x41" out(i32, "=r")
  return
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	template := m.functions[0].blocks[0].instructions[0].asm.template
	assert template.bytes() == [u8(`a`), 10, `b`, 9, u8(`"`), u8(`\\`), 0, u8(`A`)]
}

fn test_hex_escape_takes_any_byte() {
	text := 'target 64 little 8
fn @f() {
block0:
  %v0 = inline_asm "\\xff" out(i32, "=r")
  return
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	template := m.functions[0].blocks[0].instructions[0].asm.template
	assert template.bytes() == [u8(255)]
}

fn test_string_escapes_in_a_location() {
	text := 'target 64 little 8
fn @f() {
block0:
  unreachable @loc("dir\\\\file.vel", 5, 12)
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	loc := m.functions[0].blocks[0].terminator.loc or { panic('no location') }
	assert loc.file == 'dir\\file.vel'
	assert loc.line == 5
	assert loc.col == 12
}

fn test_switch_cases_are_constants() {
	text := 'target 64 little 8
fn @f(%arg0: i32) {
block0:
  switch %arg0, block1(), 0: block1(), 16: block1(), -1: block1()
block1:
  return
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	sw := m.functions[0].blocks[0].terminator
	assert sw.cases.len == 3
	assert sw.cases[0].value == u128(0)
	assert sw.cases[1].value == u128(16)
	assert sw.cases[2].value == u128(340282366920938463463374607431768211455)
	for c in sw.cases {
		assert c.target.block == 1
	}
}

fn test_jump_arguments_may_be_immediates() {
	text := 'target 64 little 8
fn @f() {
block0:
  br block1(-1, 0x20)
block1(%v0: i32, %v1: i32):
  return
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	target := m.functions[0].blocks[0].terminator.target
	assert target.args.len == 2
	assert target.args[0].kind == .int_imm
	assert target.args[0].imm == u128(340282366920938463463374607431768211455)
	assert target.args[1].imm == u128(32)
}

fn test_pointer_conversion_with_an_explicit_type() {
	text := 'target 32 little 4
fn @f(%arg0: ptr) -> i32 {
block0:
  %v0 = ptrtoint %arg0 to i32
  %v1 = inttoptr %v0 to ptr
  return %v0
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	f := m.functions[0]
	assert f.values[f.blocks[0].instructions[0].results[0]].typ == ty_i32
	assert f.values[f.blocks[0].instructions[1].results[0]].typ == ty_ptr
}

fn test_pointer_conversion_defaults_to_the_target_width() {
	text := 'target 32 little 4
fn @f(%arg0: ptr) -> i32 {
block0:
  %v0 = ptrtoint %arg0
  %v1 = inttoptr %v0
  return %v0
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	f := m.functions[0]
	assert f.values[f.blocks[0].instructions[0].results[0]].typ == ty_i32
	assert f.values[f.blocks[0].instructions[1].results[0]].typ == ty_ptr
}

fn test_result_types_come_from_the_opcode() {
	m := parse_body('%v1 = iadd %arg0, 1')
	f := m.functions[0]
	// iadd takes its type from the first operand.
	assert f.values[f.blocks[0].instructions[0].results[0]].typ == ty_i32
	text := 'target 64 little 8
fn @f(%arg0: i64, %arg1: i64) -> i1 {
block0:
  %v0 = icmp slt %arg0, %arg1
  %v1 = fcmp ult %arg0, %arg1
  %v2 = select %v0, %arg0, %arg1
  return %v0
}
'
	full := parse_text(text) or { panic('${err.msg()}') }
	values := full.functions[0].values
	assert values[full.functions[0].blocks[0].instructions[0].results[0]].typ == ty_i1
	assert values[full.functions[0].blocks[0].instructions[1].results[0]].typ == ty_i1
	assert values[full.functions[0].blocks[0].instructions[2].results[0]].typ == ty_i64
}

fn test_a_function_with_several_results() {
	text := 'target 64 little 8
fn @f(%arg0: i32) -> (i32, i64) {
block0:
  %v0 = sext %arg0 to i64
  %v1, %v2 = sadd_overflow %arg0, %arg0
  return %arg0, %v0
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	f := m.functions[0]
	assert f.signature.result_types() == [ty_i32, ty_i64]
	overflow := f.blocks[0].instructions[1]
	assert overflow.results.len == 2
	assert f.values[overflow.results[0]].typ == ty_i32
	assert f.values[overflow.results[1]].typ == ty_i1
}

fn test_flags_are_read_in_any_order() {
	text := 'target 64 little 8
fn @f(%arg0: i32, %arg1: i32) -> i32 {
block0:
  %v0 = iadd nuw nsw %arg0, %arg1
  %v1 = ptradd inbounds %arg0, 8
  return %v0
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	iadd := m.functions[0].blocks[0].instructions[0]
	assert iadd.flags.nsw
	assert iadd.flags.nuw
	assert iadd.flags.exact == false
	ptradd := m.functions[0].blocks[0].instructions[1]
	assert ptradd.flags.inbounds
}
