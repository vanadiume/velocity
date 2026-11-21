module optimize

import vanadiume.velocity.ir

// Dead code elimination: what leaves, what stays, and the arity a block keeps.

fn parse_body(body string) ir.Module {
	text := 'target 64 little 8\n' + body
	return ir.parse_text(text) or { panic('${err.msg()}') }
}

fn assert_verifies(module &ir.Module) {
	errors := ir.verify_module(module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
}

fn eliminate_all(mut module ir.Module) bool {
	mut function := module.functions[0]
	changed := eliminate_function(mut function)
	module.functions[0] = function
	assert_verifies(module)
	return changed
}

fn test_an_unused_computation_goes_with_its_operands() {
	mut module := parse_body('fn @f() -> i32 {
block0:
  %v0 = iconst i32 1
  %v1 = iconst i32 2
  %v2 = iadd %v0, %v1
  %v3 = iconst i32 7
  return %v3
}
')
	assert eliminate_all(mut module)
	assert module.functions[0].values.len == 1
	expected := 'target 64 little 8

fn @f() -> i32 {
block0:
  %v0 = iconst i32 7
  return %v0
}
'
	assert ir.print_module(&module) == expected
}

fn test_a_used_computation_stays() {
	mut module := parse_body('fn @f() -> i32 {
block0:
  %v0 = iconst i32 1
  %v1 = iadd %v0, %v0
  return %v1
}
')
	assert !eliminate_all(mut module)
	assert module.functions[0].values.len == 2
}

fn test_a_chain_of_dead_instructions_goes_in_one_pass() {
	mut module := parse_body('fn @f() -> i32 {
block0:
  %v0 = iconst i32 1
  %v1 = iadd %v0, %v0
  %v2 = iadd %v1, %v1
  %v3 = iconst i32 5
  return %v3
}
')
	assert eliminate_all(mut module)
	assert module.functions[0].values.len == 1
	assert module.functions[0].blocks[0].instructions.len == 1
}

fn has_opcode(opcodes []ir.Opcode, opcode ir.Opcode) bool {
	for op in opcodes {
		if op == opcode {
			return true
		}
	}
	return false
}

fn test_memory_calls_and_promises_stay() {
	mut module := parse_body('extern fn @g() -> i32

fn @f(%arg0: ptr, %arg1: i1) {
block0:
  %v0 = load %arg0 : i32 align 4
  %v1 = iconst i32 3
  store %arg0, %v1 align 4
  %v2 = call @g()
  assume %arg1
  %v3 = iconst i32 9
  return
}
')
	mut function := module.functions[1]
	assert eliminate_function(mut function)
	module.functions[1] = function
	assert_verifies(&module)
	mut opcodes := []ir.Opcode{cap: function.blocks[0].instructions.len}
	for inst in function.blocks[0].instructions {
		opcodes << inst.opcode
	}
	assert has_opcode(opcodes, .load)
	assert has_opcode(opcodes, .store)
	assert has_opcode(opcodes, .call)
	assert has_opcode(opcodes, .assume)
	assert has_opcode(opcodes, .iconst)
	// Only the unused iconst %v3 went.
	assert function.blocks[0].instructions.len == 5
	assert function.values.len == 5
}

fn test_an_unused_block_parameter_keeps_its_edge() {
	mut module := parse_body('fn @f(%arg0: i32) -> i32 {
block0:
  br block1(%arg0)
block1(%v0: i32):
  %v1 = iconst i32 4
  return %arg0
}
')
	assert eliminate_all(mut module)
	function := module.functions[0]
	assert function.blocks[1].params.len == 1
	assert function.blocks[0].terminator.target.args.len == 1
	assert function.values.len == 2
	expected := 'target 64 little 8

fn @f(%arg0: i32) -> i32 {
block0:
  br block1(%arg0)
block1(%v0: i32):
  return %arg0
}
'
	assert ir.print_module(&module) == expected
}

fn test_an_erase_that_makes_a_later_value_live_is_not_mistaken() {
	// %v1 is read by %v2, which is itself dead, so both go. %v3 is read by the
	// return and stays with both of its operands.
	mut module := parse_body('fn @f() -> i32 {
block0:
  %v0 = iconst i32 1
  %v1 = iadd %v0, %v0
  %v2 = iadd %v1, %v1
  %v3 = iadd %v2, %v2
  %v4 = iadd %v0, %v0
  return %v4
}
')
	assert eliminate_all(mut module)
	function := module.functions[0]
	assert function.blocks[0].instructions.len == 2
	assert function.blocks[0].terminator.operands[0].idx == 1
}

fn test_nothing_dead_reports_no_change() {
	mut module := parse_body('fn @f(%arg0: i32) -> i32 {
block0:
  return %arg0
}
')
	assert !eliminate_all(mut module)
}
