module optimize

import vanadiume.velocity.ir

// The default pipeline end to end: what a caller gets from optimize_module,
// that running it twice changes nothing the second time, and that its output
// still parses and verifies.

fn parse_body(body string) ir.Module {
	text := 'target 64 little 8\n' + body
	return ir.parse_text(text) or { panic('${err.msg()}') }
}

fn assert_verifies(module &ir.Module) {
	errors := ir.verify_module(module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
}

fn test_a_used_fold_becomes_one_constant() {
	mut module := parse_body('fn @f() -> i32 {
block0:
  %v0 = iconst i32 2
  %v1 = iconst i32 3
  %v2 = iadd %v0, %v1
  return %v2
}
')
	assert optimize_module(mut module)
	assert_verifies(&module)
	assert module.functions[0].values.len == 1
	expected := 'target 64 little 8

fn @f() -> i32 {
block0:
  %v0 = iconst i32 5
  return %v0
}
'
	assert ir.print_module(&module) == expected
}

fn test_a_chain_nothing_reads_becomes_nothing() {
	mut module := parse_body('fn @f() {
block0:
  %v0 = iconst i32 1
  %v1 = iadd %v0, %v0
  %v2 = imul %v1, %v1
  return
}
')
	assert optimize_module(mut module)
	assert_verifies(&module)
	assert module.functions[0].values.len == 0
	assert module.functions[0].blocks[0].instructions.len == 0
	expected := 'target 64 little 8

fn @f() {
block0:
  return
}
'
	assert ir.print_module(&module) == expected
}

fn test_a_second_run_changes_nothing() {
	mut module := parse_body('fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iconst i32 2
  %v1 = iconst i32 3
  %v2 = iadd %v0, %v1
  %v3 = imul %v2, %arg0
  %v4 = iconst i32 0
  return %v3
}
')
	assert optimize_module(mut module)
	assert !optimize_module(mut module)
}

fn test_the_output_round_trips_through_the_text_form() {
	mut module := parse_body('fn @f(%arg0: i32, %arg1: i1) -> i32 {
block0:
  %v0 = iconst i32 6
  %v1 = iconst i32 7
  %v2 = imul %v0, %v1
  %v3 = select %arg1, %v2, %arg0
  %v4 = iconst i32 1
  return %v3
}
')
	assert optimize_module(mut module)
	printed := ir.print_module(&module)
	again := ir.parse_text(printed) or { panic('${err.msg()}') }
	assert_verifies(&again)
	assert ir.print_module(&again) == printed
}

fn test_optimize_module_visits_every_definition() {
	mut module := parse_body('extern fn @g() -> i32

fn @first() -> i32 {
block0:
  %v0 = iconst i32 1
  %v1 = iconst i32 2
  %v2 = iadd %v0, %v1
  return %v2
}

fn @second() -> i32 {
block0:
  %v0 = iconst i32 4
  %v1 = imul %v0, %v0
  return %v1
}
')
	assert optimize_module(mut module)
	assert_verifies(&module)
	assert module.functions[0].defined == false
	assert module.functions[1].blocks[0].instructions.len == 1
	assert module.functions[2].blocks[0].instructions.len == 1
	assert module.functions[1].blocks[0].instructions[0].operands[0].imm == 3
	assert module.functions[2].blocks[0].instructions[0].operands[0].imm == 16
}

// A chain long enough that a per-sweep walk and a per-removal walk would both
// show: every fold feeds the next, and nothing reads the last one.
fn test_a_chain_of_ten_thousand_folds_and_erases() {
	steps := 10000
	mut text := 'fn @f() {\nblock0:\n  %v0 = iconst i32 0\n'
	for i in 1 .. steps + 1 {
		text += '  %v${i} = iadd %v${i - 1}, 1\n'
	}
	text += '  return\n}\n'
	mut module := parse_body(text)
	assert module.functions[0].blocks[0].instructions.len == steps + 1
	assert optimize_module(mut module)
	assert_verifies(&module)
	assert module.functions[0].values.len == 0
	assert module.functions[0].blocks[0].instructions.len == 0
}
