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

fn test_integer_arithmetic_verifies() {
	mut function := new_function('arith', [ty_i32, ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	a := builder.param(0)
	c := builder.param(1)
	sum := builder.iadd_flags(a, c, flags(.nsw))
	product := builder.imul(sum, c)
	difference := builder.isub(product, a)
	quotient := builder.sdiv(difference, c)
	remainder := builder.srem(quotient, c)
	smallest := builder.smin(remainder, a)
	largest := builder.umax(smallest, c)
	builder.return_([largest])
	builder.finish()

	assert function.blocks[0].instructions[0].flags.nsw
	assert function.blocks[0].instructions[0].opcode == .iadd
	assert_verified_function(function)
}

fn test_overflow_pairs_carry_the_flag() {
	mut function := new_function('overflow', [ty_i64, ty_i64], [ty_i64])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	pair := builder.uadd_overflow(builder.param(0), builder.param(1))
	assert pair.value.typ == ty_i64
	assert pair.flag.typ == ty_i1
	other := builder.smul_overflow(pair.value, builder.param(1))
	builder.return_([other.value])
	builder.finish()

	assert function.blocks[0].instructions[0].results.len == 2
	assert function.values[function.blocks[0].instructions[0].results[1]].typ == ty_i1
	assert_verified_function(function)
}

fn test_saturating_and_bitwise_operations_verify() {
	mut function := new_function('bits', [ty_i32, ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	a := builder.param(0)
	c := builder.param(1)
	saturated := builder.sadd_sat(a, c)
	clamped := builder.usub_sat(saturated, c)
	masked := builder.band(clamped, c)
	flipped := builder.bnot(masked)
	shifted := builder.shl_flags(flipped, c, flags(.nuw))
	arith := builder.sshr(shifted, c)
	logical := builder.ushr_flags(arith, c, flags(.exact))
	rotated := builder.rotl(logical, c)
	counted := builder.popcnt(rotated)
	leading := builder.clz(counted)
	trailing := builder.ctz(leading)
	reversed := builder.bswap(trailing)
	builder.return_([reversed])
	builder.finish()

	assert function.blocks[0].instructions[4].flags.nuw
	assert function.blocks[0].instructions[6].flags.exact
	assert_verified_function(function)
}

fn test_comparisons_return_i1() {
	mut function := new_function('compare', [ty_i32, ty_i32, ty_f64, ty_f64], [ty_i1])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	integer := builder.icmp(.slt, builder.param(0), builder.param(1))
	float := builder.fcmp(.olt, builder.param(2), builder.param(3))
	both := builder.band(integer, float)
	builder.return_([both])
	builder.finish()

	assert function.blocks[0].instructions[0].predicate == 'slt'
	assert function.blocks[0].instructions[1].predicate == 'olt'
	assert_verified_function(function)
}

fn test_float_arithmetic_verifies() {
	mut function := new_function('math', [ty_f64, ty_f64, ty_f64], [ty_f64])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	a := builder.param(0)
	c := builder.param(1)
	d := builder.param(2)
	product := builder.fmul(a, c)
	fused := builder.fma(product, c, d)
	root := builder.fsqrt(fused)
	closest := builder.fnearest(root)
	lower := builder.fmin(closest, a)
	builder.return_([lower])
	builder.finish()

	assert function.blocks[0].instructions[1].opcode == .fma
	assert_verified_function(function)
}

fn test_conversions_verify() {
	mut function := new_function('convert', [ty_i32, ty_i64, ty_f32, ty_f64, ty_ptr], [ty_i64])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	small := builder.param(0)
	large := builder.param(1)
	narrow := builder.param(2)
	wide := builder.param(3)
	pointer := builder.param(4)
	extended := builder.sext(small, ty_i64)
	zeroed := builder.zext(small, ty_i64)
	truncated := builder.trunc(large, ty_i32)
	as_bits := builder.bitcast(wide, ty_i64)
	from_int := builder.sitofp(small, ty_f64)
	to_int := builder.fptosi(from_int, ty_i32)
	wider := builder.fpext(narrow, ty_f64)
	narrower := builder.fptrunc(wide, ty_f32)
	address := builder.ptrtoint(pointer, ty_i64)
	back := builder.inttoptr(address, ty_ptr)
	builder.return_([address])
	builder.finish()

	_ = extended
	_ = zeroed
	_ = truncated
	_ = as_bits
	_ = to_int
	_ = wider
	_ = narrower
	_ = back
	assert function.blocks[0].instructions[0].opcode == .sext
	assert function.blocks[0].instructions[0].typ == ty_i64
	assert_verified_function(function)
}

fn test_select_verifies() {
	mut function := new_function('pick', [ty_i32, ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	condition := builder.icmp(.sgt, builder.param(0), builder.param(1))
	chosen := builder.select(condition, builder.param(0), builder.param(1))
	builder.return_([chosen])
	builder.finish()
	assert_verified_function(function)
}

fn test_memory_operations_verify() {
	mut function := new_function('memory', [ty_ptr, ty_ptr, ty_i64], [ty_i64])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	dst := builder.param(0)
	src := builder.param(1)
	len := builder.param(2)
	loaded := builder.load(dst, ty_i64)
	builder.store_aligned(src, loaded, 8)
	shifted := builder.ptradd_flags(dst, builder.iconst(ty_i64, 8), flags(.inbounds))
	read_back := builder.load_volatile_aligned(shifted, ty_i64, 8)
	builder.store_volatile(shifted, read_back)
	builder.memcpy(dst, src, len, 8, 8)
	builder.memmove(src, dst, len, 8, 8)
	builder.memset(dst, builder.iconst(ty_i8, 0), len, 8)
	builder.return_([read_back])
	builder.finish()

	assert function.blocks[0].instructions[0].align == 8
	assert function.blocks[0].instructions[3].flags.inbounds
	assert_verified_function(function)
}

fn test_a_stack_slot_is_addressed() {
	mut function := new_function('slot', [], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	slot := builder.create_stack_slot(16, 8, 'scratch')
	address := builder.stack_addr(slot)
	builder.store(address, builder.iconst(ty_i32, 5))
	loaded := builder.load(address, ty_i32)
	builder.return_([loaded])
	builder.finish()

	assert function.stack_slots[0].name or { '' } == 'scratch'
	assert function.blocks[0].instructions[0].operands[0].kind == .stack_slot
	assert_verified_function(function)
}

fn test_the_address_of_a_global_and_a_function_verify() {
	mut function := new_function('addresses', [], [ty_ptr])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	data := builder.global_addr('data')
	code := builder.func_addr('helper')
	builder.return_([data])
	builder.finish()

	module := Module{
		target:    builder_target()
		functions: [
			Function{
				name:      'helper'
				signature: Signature{}
			},
			function,
		]
		globals:   [
			Global{
				name:  'data'
				size:  8
				align: 8
			},
		]
	}
	errors := verify_module(&module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
	_ = code
}

fn test_a_direct_call_and_a_tail_call_verify() {
	mut function := new_function('caller', [ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	signature := Signature{
		params:  [ty_i32]
		results: [ty_i32]
	}
	results := builder.call('callee', signature, [builder.param(0)])
	builder.return_([results[0]])
	builder.finish()

	mut tail := new_function('tail', [ty_i32], [ty_i32])
	mut tail_builder := new_builder(mut tail, builder_target())
	tail_entry := tail_builder.create_entry_block()
	tail_builder.switch_to_block(tail_entry)
	tail_builder.tailcall('callee', signature, [tail_builder.param(0)])
	tail_builder.finish()

	module := Module{
		target:    builder_target()
		functions: [
			Function{
				name:      'callee'
				signature: signature
			},
			function,
			tail,
		]
	}
	errors := verify_module(&module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
}

fn test_an_indirect_call_verifies() {
	mut function := new_function('dispatch', [ty_ptr, ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	results := builder.call_indirect(builder.param(0), Signature{
		params:  [ty_i32]
		results: [ty_i32]
	}, [builder.param(1)])
	builder.return_([results[0]])
	builder.finish()
	assert function.blocks[0].terminator.opcode == .@return
	assert_verified_function(function)
}

fn test_inline_asm_and_assume_verify() {
	mut function := new_function('asm', [ty_i64], [ty_i64])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	argument := builder.param(0)
	builder.assume(builder.icmp(.ne, argument, builder.iconst(ty_i64, 0)))
	outputs := builder.inline_asm(Asm{
		template: 'mov $1, $0'
		outputs:  [
			AsmOutput{
				typ:        ty_i64
				constraint: '=r'
			},
		]
		inputs:   [
			AsmInput{
				value:      argument
				constraint: 'r'
			},
		]
		clobbers: ['cc']
		volatile: true
	})
	builder.return_([outputs[0]])
	builder.finish()

	assert function.blocks[0].instructions[3].asm.outputs.len == 1
	assert function.blocks[0].instructions[3].asm.volatile
	assert_verified_function(function)
}
