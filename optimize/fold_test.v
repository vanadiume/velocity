module optimize

import vanadiume.velocity.ir

// Constant folding: every opcode in the set, the flags around it, the ops that
// are deliberately left alone, and the value table staying where it was.

fn parse_body(body string) ir.Module {
	text := 'target 64 little 8\n' + body
	return ir.parse_text(text) or { panic('${err.msg()}') }
}

fn assert_verifies(module &ir.Module) {
	errors := ir.verify_module(module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
}

fn fold_all(mut module ir.Module) bool {
	mut function := module.functions[0]
	changed := fold_function(mut function)
	module.functions[0] = function
	assert_verifies(module)
	return changed
}

fn folded_instruction(body string, index int) ir.Instruction {
	mut module := parse_body(body)
	fold_all(mut module)
	return module.functions[0].blocks[0].instructions[index]
}

fn assert_constant(inst ir.Instruction, typ ir.Type, bits u128) {
	assert inst.opcode == .iconst
	assert inst.typ == typ, '${inst.typ.str()} is not ${typ.str()}'
	assert inst.operands.len == 1
	assert inst.operands[0].kind == .int_imm
	assert inst.operands[0].imm == bits, '${inst.operands[0].imm} is not ${bits}'
}

fn test_arithmetic_folds_and_keeps_the_result_index() {
	inst := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 2
  %v1 = iconst i32 3
  %v2 = iadd %v0, %v1
  return
}
', 2)
	assert_constant(inst, ir.ty_i32, 5)
	assert inst.results.len == 1
	assert inst.results[0] == 2
}

fn test_a_chain_folds_in_one_walk() {
	body := 'fn @f() {
block0:
  %v0 = iconst i32 1
  %v1 = iconst i32 2
  %v2 = iadd %v0, %v1
  %v3 = iconst i32 3
  %v4 = iadd %v2, %v3
  return
}
'
	inner := folded_instruction(body, 2)
	assert_constant(inner, ir.ty_i32, 3)
	outer := folded_instruction(body, 4)
	assert_constant(outer, ir.ty_i32, 6)
}

fn test_an_immediate_operand_counts_as_a_constant() {
	inst := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 2
  %v1 = iadd %v0, 3
  return
}
', 1)
	assert_constant(inst, ir.ty_i32, 5)
}

fn test_wrapping_arithmetic_folds_without_flags() {
	inst := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 2147483647
  %v1 = iconst i32 1
  %v2 = iadd %v0, %v1
  return
}
', 2)
	assert_constant(inst, ir.ty_i32, 2147483648)
}

fn test_a_promise_that_holds_folds() {
	inst := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 2
  %v1 = iconst i32 3
  %v2 = iadd nsw %v0, %v1
  return
}
', 2)
	assert_constant(inst, ir.ty_i32, 5)
}

fn test_signed_overflow_leaves_the_instruction_alone() {
	inst := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 2147483647
  %v1 = iconst i32 1
  %v2 = iadd nsw %v0, %v1
  return
}
', 2)
	assert inst.opcode == .iadd
	assert inst.flags.nsw
}

fn test_unsigned_underflow_leaves_the_instruction_alone() {
	inst := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 1
  %v1 = iconst i32 2
  %v2 = isub nuw %v0, %v1
  return
}
', 2)
	assert inst.opcode == .isub
	assert inst.flags.nuw
}

fn test_multiplication_checks_its_flags() {
	held := folded_instruction('fn @f() {
block0:
  %v0 = iconst i64 4294967296
  %v1 = iconst i64 3
  %v2 = imul nsw %v0, %v1
  return
}
', 2)
	assert_constant(held, ir.ty_i64, 12884901888)
	broken := folded_instruction('fn @f() {
block0:
  %v0 = iconst i64 4294967296
  %v1 = iconst i64 4294967296
  %v2 = imul nsw %v0, %v1
  return
}
', 2)
	assert broken.opcode == .imul
}

fn test_shifts_fold_within_the_width() {
	shifted := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 1
  %v1 = iconst i32 4
  %v2 = shl %v0, %v1
  return
}
', 2)
	assert_constant(shifted, ir.ty_i32, 16)
	too_wide := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 1
  %v1 = iconst i32 32
  %v2 = shl %v0, %v1
  return
}
', 2)
	assert too_wide.opcode == .shl
}

fn test_a_shift_promise_is_checked() {
	held := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 1
  %v1 = iconst i32 31
  %v2 = shl nuw %v0, %v1
  return
}
', 2)
	assert_constant(held, ir.ty_i32, 2147483648)
	broken := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 2
  %v1 = iconst i32 30
  %v2 = shl nsw %v0, %v1
  return
}
', 2)
	assert broken.opcode == .shl
}

fn test_right_shifts_are_arithmetic_or_logical() {
	signed := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 -16
  %v1 = iconst i32 2
  %v2 = sshr %v0, %v1
  return
}
', 2)
	assert_constant(signed, ir.ty_i32, 4294967292)
	logical := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 -16
  %v1 = iconst i32 2
  %v2 = ushr %v0, %v1
  return
}
', 2)
	assert_constant(logical, ir.ty_i32, 1073741820)
}

fn test_rotates_wrap_the_amount() {
	rotated := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 2147483649
  %v1 = iconst i32 33
  %v2 = rotl %v0, %v1
  return
}
', 2)
	assert_constant(rotated, ir.ty_i32, 3)
}

fn test_bit_counts_and_bswap_fold() {
	leading := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 1
  %v1 = clz %v0
  return
}
', 1)
	assert_constant(leading, ir.ty_i32, 31)
	trailing := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 8
  %v1 = ctz %v0
  return
}
', 1)
	assert_constant(trailing, ir.ty_i32, 3)
	counted := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 7
  %v1 = popcnt %v0
  return
}
', 1)
	assert_constant(counted, ir.ty_i32, 3)
	swapped := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 305419896
  %v1 = bswap %v0
  return
}
', 1)
	assert_constant(swapped, ir.ty_i32, 2018915346)
}

fn test_comparisons_fold_to_an_i1() {
	greater := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 2
  %v1 = iconst i32 1
  %v2 = icmp sgt %v0, %v1
  return
}
', 2)
	assert_constant(greater, ir.ty_i1, 1)
	signed_less := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 -1
  %v1 = iconst i32 0
  %v2 = icmp slt %v0, %v1
  return
}
', 2)
	assert_constant(signed_less, ir.ty_i1, 1)
	unsigned_less := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 -1
  %v1 = iconst i32 0
  %v2 = icmp ult %v0, %v1
  return
}
', 2)
	assert_constant(unsigned_less, ir.ty_i1, 0)
}

fn test_conversions_fold_to_the_destination_width() {
	truncated := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 300
  %v1 = trunc %v0 to i8
  return
}
', 1)
	assert_constant(truncated, ir.int_type(8), 44)
	sign_extended := folded_instruction('fn @f() {
block0:
  %v0 = iconst i8 -1
  %v1 = sext %v0 to i32
  return
}
', 1)
	assert_constant(sign_extended, ir.ty_i32, 4294967295)
	zero_extended := folded_instruction('fn @f() {
block0:
  %v0 = iconst i8 -1
  %v1 = zext %v0 to i32
  return
}
', 1)
	assert_constant(zero_extended, ir.ty_i32, 255)
}

// select_fixture puts the select's uses somewhere a value replacement can be
// read.
const select_fixture = 'fn @f(%arg0: i32, %arg1: i32) -> i32 {
block0:
  %v0 = iconst i1 1
  %v1 = select %v0, %arg0, %arg1
  return %v1
}
'

fn test_a_constant_condition_replaces_the_uses_with_the_chosen_value() {
	mut module := parse_body(select_fixture)
	assert fold_all(mut module)
	function := module.functions[0]
	assert function.blocks[0].instructions[1].opcode == .select
	assert function.blocks[0].terminator.operands[0].idx == 0
	assert use_counts(function)[3] == 0
}

fn test_a_constant_arm_that_is_an_immediate_becomes_the_selects_constant() {
	inst := folded_instruction('fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iconst i1 1
  %v1 = select %v0, 5, %arg0
  return %v1
}
', 1)
	assert_constant(inst, ir.ty_i32, 5)
	assert inst.results[0] == 2
}

fn test_a_chosen_constant_value_keeps_its_own_definition() {
	mut module := parse_body('fn @f() -> i32 {
block0:
  %v0 = iconst i1 0
  %v1 = iconst i32 4
  %v2 = iconst i32 9
  %v3 = select %v0, %v1, %v2
  return %v3
}
')
	assert fold_all(mut module)
	function := module.functions[0]
	assert function.blocks[0].instructions[3].opcode == .select
	assert function.blocks[0].terminator.operands[0].idx == 2
	assert use_counts(function)[3] == 0
}

fn test_freeze_of_a_constant_folds() {
	inst := folded_instruction('fn @f() {
block0:
  %v0 = iconst i32 42
  %v1 = freeze %v0
  return
}
', 1)
	assert_constant(inst, ir.ty_i32, 42)
}

fn test_freeze_of_poison_and_of_a_parameter_stay() {
	poisoned := folded_instruction('fn @f() {
block0:
  %v0 = poison i32
  %v1 = freeze %v0
  return
}
', 1)
	assert poisoned.opcode == .freeze
	parameter := folded_instruction('fn @f(%arg0: i32) {
block0:
  %v0 = freeze %arg0
  return
}
', 0)
	assert parameter.opcode == .freeze
}

fn test_folding_stops_at_an_operand_that_is_not_constant() {
	inst := folded_instruction('fn @f(%arg0: i32) {
block0:
  %v0 = iconst i32 7
  %v1 = iadd %arg0, %v0
  return
}
', 1)
	assert inst.opcode == .iadd
}

fn test_nothing_foldable_reports_no_change() {
	mut module := parse_body('fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iadd %arg0, %arg0
  return %v0
}
')
	assert !fold_all(mut module)
}

// A model whose block order puts a definition after its use is valid IR that the
// text form cannot spell, so the fixture is parsed and then typed by hand. It is
// the one case where a chain needs a second sweep: block1 is walked before
// block2 has folded the constant it reads.
fn test_a_definition_listed_after_its_use_needs_a_second_sweep() {
	mut module := parse_body('fn @f() -> i32 {
block0:
  br block2()
block1:
  %v0 = iadd %v1, 1
  return %v0
block2:
  %v2 = iconst i32 2
  %v3 = iconst i32 3
  %v1 = iadd %v2, %v3
  br block1()
}
')
	mut function := module.functions[0]
	function.values[0].typ = ir.ty_i32
	module.functions[0] = function
	assert_verifies(&module)
	assert fold_all(mut module)
	function = module.functions[0]
	assert_constant(function.blocks[1].instructions[0], ir.ty_i32, 6)
	assert_constant(function.blocks[2].instructions[2], ir.ty_i32, 5)
}
