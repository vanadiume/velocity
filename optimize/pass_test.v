module optimize

import vanadiume.velocity.ir

// The manager: the order passes run in, what it reports, which functions it
// visits, and what it does with a pass that leaves broken IR.

fn parse_body(body string) ir.Module {
	text := 'target 64 little 8\n' + body
	return ir.parse_text(text) or { panic('${err.msg()}') }
}

fn assert_verifies(module &ir.Module) {
	errors := ir.verify_module(module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
}

fn one_constant() ir.Module {
	return parse_body('fn @f() -> i32 {
block0:
  %v0 = iconst i32 0
  return %v0
}
')
}

// set_zero rewrites the constant to 0, so two passes in a row can be told apart
// by which value the last one wrote.
fn set_zero(mut function ir.Function) bool {
	function.blocks[0].instructions[0].operands[0].imm = 0
	return true
}

fn set_seven(mut function ir.Function) bool {
	function.blocks[0].instructions[0].operands[0].imm = 7
	return true
}

fn test_passes_run_in_order_and_every_change_is_reported() {
	mut module := one_constant()
	mut function := module.functions[0]
	mut manager := new_pass_manager()
	manager.add(Pass{
		name: 'seven'
		run:  set_seven
	})
	manager.add(Pass{
		name: 'zero'
		run:  set_zero
	})
	assert manager.run_function(module, mut function)
	assert function.blocks[0].instructions[0].operands[0].imm == 0
	module.functions[0] = function
	assert_verifies(&module)
}

fn publish(mut function ir.Function) bool {
	if function.public {
		return false
	}
	function.public = true
	return true
}

fn test_run_module_visits_definitions_and_skips_declarations() {
	mut module := parse_body('extern fn @puts(%arg0: ptr) -> i32

fn @f() -> i32 {
block0:
  %v0 = iconst i32 0
  return %v0
}
')
	assert module.functions[0].defined == false
	mut manager := new_pass_manager()
	manager.add(Pass{
		name: 'publish'
		run:  publish
	})
	assert manager.run_module(mut module)
	assert module.functions[0].public == false
	assert module.functions[1].public == true
	assert_verifies(&module)
}

fn test_a_second_run_reports_no_change() {
	mut module := one_constant()
	mut manager := new_pass_manager()
	manager.add(Pass{
		name: 'publish'
		run:  publish
	})
	assert manager.run_module(mut module)
	assert !manager.run_module(mut module)
}

fn break_the_table(mut function ir.Function) bool {
	function.blocks[0].terminator.operands[0].idx = 999
	return true
}

fn run_breaker() {
	module := one_constant()
	mut function := module.functions[0]
	mut manager := new_pass_manager()
	manager.add(Pass{
		name: 'breaker'
		run:  break_the_table
	})
	manager.run_function(module, mut function)
}

struct Caught {
mut:
	message string
}

fn catch_panic(run fn (), mut caught Caught) {
	defer {
		if err := recover() {
			caught.message = err
		}
	}
	run()
}

fn test_a_pass_that_breaks_the_ir_stops_the_manager() {
	mut caught := Caught{}
	catch_panic(run_breaker, mut caught)
	assert caught.message.starts_with("optimize: pass 'breaker' left @f"), caught.message
	assert caught.message.contains('block 0'), caught.message
	assert caught.message.contains('unverifiable: V005'), caught.message
}
