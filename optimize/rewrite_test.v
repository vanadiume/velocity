module optimize

import vanadiume.velocity.ir

// The rewrite layer: how many times a value is named, what happens when every
// site is pointed somewhere else, and what an erase does to the table.

fn parse_body(body string) ir.Module {
	text := 'target 64 little 8\n' + body
	return ir.parse_text(text) or { panic('${err.msg()}') }
}

fn assert_verifies(module &ir.Module) {
	errors := ir.verify_module(module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
}

// jump_counts is a function where one value is named at three sites: two jump
// arguments and a return in another block.
const jump_counts = 'fn @f(%arg0: i1, %arg1: i32) -> i32 {
block0:
  %v0 = iconst i32 7
  condbr %arg0, block1(%v0), block2(%v0, %arg1)
block1(%v1: i32):
  return %v0
block2(%v2: i32, %v3: i32):
  return %v2
}
'

fn test_use_counts_count_operands_and_jump_arguments() {
	module := parse_body(jump_counts)
	assert_verifies(&module)
	function := module.functions[0]
	counts := use_counts(function)
	assert function.values.len == 6
	assert counts.len == 6
	assert counts[0] == 1 // %arg0, the condbr condition
	assert counts[1] == 1 // %arg1, a jump argument
	assert counts[2] == 3 // %v0, two jump arguments and a return
	assert counts[3] == 0 // the block parameters are named nowhere else
	assert counts[4] == 1 // %v2, the last return
	assert counts[5] == 0
}

fn test_replace_uses_points_every_site_at_the_replacement() {
	mut module := parse_body(jump_counts)
	mut function := module.functions[0]
	changed := replace_uses(mut function, 2, ir.Operand{
		kind: .value
		idx:  1
	})
	assert changed == 3
	counts := use_counts(function)
	assert counts[2] == 0
	assert counts[1] == 4
	module.functions[0] = function
	assert_verifies(&module)
}

fn test_erasing_a_definition_renumbers_the_values_after_it() {
	mut module := parse_body('fn @f(%arg0: i32, %arg1: i1) -> i32 {
block0:
  %v0 = iconst i32 99
  %v1 = iadd %arg0, %arg0
  condbr %arg1, block1(%v1), block2(%v1)
block1(%v2: i32):
  return %v2
block2(%v3: i32):
  return %v3
}
')
	assert_verifies(&module)
	mut function := module.functions[0]
	assert function.values.len == 6

	mut dead := [][]bool{len: function.blocks.len}
	for bi in 0 .. function.blocks.len {
		dead[bi] = []bool{len: function.blocks[bi].instructions.len}
	}
	dead[0][0] = true
	assert erase_instructions(mut function, dead)

	// Two parameters, one instruction result, two block parameters.
	assert function.values.len == 5
	live := function.values[2]
	assert live.kind == .instruction_result
	assert live.block == 0
	assert live.inst == 0
	assert function.blocks[0].instructions[0].opcode == .iadd
	terminator := function.blocks[0].terminator
	assert terminator.target.args[0].idx == 2
	assert terminator.else_target.args[0].idx == 2
	assert function.blocks[1].params[0] == 3
	assert function.blocks[2].params[0] == 4

	module.functions[0] = function
	assert_verifies(&module)
	expected := 'target 64 little 8

fn @f(%arg0: i32, %arg1: i1) -> i32 {
block0:
  %v0 = iadd %arg0, %arg0
  condbr %arg1, block1(%v0), block2(%v0)
block1(%v1: i32):
  return %v1
block2(%v2: i32):
  return %v2
}
'
	assert ir.print_module(&module) == expected
}

fn test_erasing_renumbers_an_inline_asm_input() {
	mut module := parse_body('fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iconst i32 1
  %v1 = iadd %arg0, %arg0
  %v2 = inline_asm "nop" out(i32, "=r") in(%v1, "r")
  return %v2
}
')
	assert_verifies(&module)
	mut function := module.functions[0]

	mut dead := [][]bool{len: 1}
	dead[0] = []bool{len: function.blocks[0].instructions.len}
	dead[0][0] = true
	assert erase_instructions(mut function, dead)

	assert function.values.len == 3
	assert function.blocks[0].instructions[0].opcode == .iadd
	assembled := function.blocks[0].instructions[1]
	assert assembled.opcode == .inline_asm
	assert assembled.asm.inputs[0].value.idx == 1
	assert function.values[1].kind == .instruction_result
	assert function.values[1].inst == 0
	module.functions[0] = function
	assert_verifies(&module)
}

fn test_erasing_nothing_reports_no_change() {
	mut module := parse_body(jump_counts)
	mut function := module.functions[0]
	mut dead := [][]bool{len: function.blocks.len}
	for bi in 0 .. function.blocks.len {
		dead[bi] = []bool{len: function.blocks[bi].instructions.len}
	}
	assert !erase_instructions(mut function, dead)
	assert function.values.len == 6
}
