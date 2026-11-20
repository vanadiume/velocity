module ir

// The builder's contract, as ir-builder.md states it. Each function is built
// the way a frontend would build it and then handed to the verifier, because
// the builder's job is IR the verifier accepts without being asked twice.

fn builder_target() TargetInfo {
	return TargetInfo{
		pointer_width: 64
		pointer_align: 8
		endian:        .little
	}
}

fn assert_verified_function(function Function) {
	module := Module{
		target:    builder_target()
		functions: [function]
	}
	errors := verify_module(&module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
}

fn test_a_constant_returns_and_verifies() {
	mut function := new_function('answer', [], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	value := builder.iconst(ty_i32, 42)
	builder.return_([value])
	builder.finish()

	assert function.blocks.len == 1
	assert function.blocks[0].terminator.opcode == .@return
	assert function.blocks[0].terminator.operands.len == 1
	assert function.values.len == 1
	assert function.values[0].kind == .instruction_result
	assert function.values[0].block == 0
	assert function.values[0].inst == 0
	assert_verified_function(function)
}

fn test_a_parameter_is_the_first_value() {
	mut function := new_function('identity', [ty_i64], [ty_i64])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	argument := builder.param(0)
	assert argument.typ == ty_i64
	builder.return_([argument])
	builder.finish()

	assert function.values[0].kind == .function_param
	assert function.blocks[0].terminator.operands[0].idx == 0
	assert_verified_function(function)
}

fn test_a_jump_to_a_second_block_verifies() {
	mut function := new_function('jump', [], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	second := builder.create_block()
	builder.br(second, [])
	builder.switch_to_block(second)
	value := builder.iconst(ty_i32, 7)
	builder.return_([value])
	builder.finish()

	assert function.blocks[1].label == 'block1'
	assert function.blocks[0].terminator.target.block == 1
	assert_verified_function(function)
}

fn test_condbr_builds_two_edges() {
	mut function := new_function('choose', [ty_i1], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	condition := builder.param(0)
	taken := builder.create_block()
	other := builder.create_block()
	builder.condbr(condition, taken, [], other, [])
	builder.switch_to_block(taken)
	builder.return_([builder.iconst(ty_i32, 1)])
	builder.switch_to_block(other)
	builder.return_([builder.iconst(ty_i32, 0)])
	builder.finish()

	assert function.blocks[0].terminator.opcode == .condbr
	assert function.blocks[0].terminator.target.block == 1
	assert function.blocks[0].terminator.else_target.block == 2
	assert_verified_function(function)
}

fn test_switch_builds_a_default_and_its_cases() {
	mut function := new_function('pick', [ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	value := builder.param(0)
	fallback := builder.create_block()
	one := builder.create_block()
	two := builder.create_block()
	builder.switch_(value, fallback, [], [
		Case{
			value: u128(1)
			block: one
		},
		Case{
			value: u128(2)
			block: two
		},
	])
	builder.switch_to_block(fallback)
	builder.return_([builder.iconst(ty_i32, 0)])
	builder.switch_to_block(one)
	builder.return_([builder.iconst(ty_i32, 1)])
	builder.switch_to_block(two)
	builder.return_([builder.iconst(ty_i32, 2)])
	builder.finish()

	terminator := function.blocks[0].terminator
	assert terminator.opcode == .switch
	assert terminator.cases.len == 2
	assert terminator.cases[1].target.block == 3
	assert_verified_function(function)
}

fn test_trap_and_unreachable_end_a_block() {
	mut function := new_function('stop', [], [])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	builder.trap(7)
	builder.finish()
	assert function.blocks[0].terminator.trap_code == 7
	assert_verified_function(function)

	mut other := new_function('never', [], [])
	mut second := new_builder(mut other, builder_target())
	start := second.create_entry_block()
	second.switch_to_block(start)
	second.unreachable()
	second.finish()
	assert other.blocks[0].terminator.opcode == .unreachable
	assert_verified_function(other)
}

fn test_the_location_is_copied_onto_every_instruction() {
	mut function := new_function('located', [], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	builder.set_loc(loc('main.c', 12, 5))
	first := builder.iconst(ty_i32, 1)
	builder.clear_loc()
	second := builder.iconst(ty_i32, 2)
	total := builder.freeze(second)
	builder.return_([first])
	builder.finish()

	if first_location := function.blocks[0].instructions[0].loc {
		assert first_location.file == 'main.c'
		assert first_location.line == 12
		assert first_location.col == 5
	} else {
		assert false, 'the first instruction has no location'
	}
	assert function.blocks[0].instructions[1].loc == none
	_ = total
	_ = first
	_ = second
	assert_verified_function(function)
}

fn test_fconst_null_and_poison() {
	mut function := new_function('values', [], [ty_ptr])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	zero := builder.fconst(ty_f64, u128(0))
	pointer := builder.null()
	safe := builder.poison(ty_ptr)
	builder.return_([pointer])
	builder.finish()

	assert zero.typ == ty_f64
	assert safe.typ == ty_ptr
	assert_verified_function(function)
}
