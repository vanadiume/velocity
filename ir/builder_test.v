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
				name: 'data'
				typ:  ty_i64
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
	sig := signature([param(ty_i32, false)], [result(ty_i32, false)])
	results := builder.call('callee', sig, [builder.param(0)])
	builder.return_([results[0]])
	builder.finish()

	mut tail := new_function('tail', [ty_i32], [ty_i32])
	mut tail_builder := new_builder(mut tail, builder_target())
	tail_entry := tail_builder.create_entry_block()
	tail_builder.switch_to_block(tail_entry)
	tail_builder.tailcall('callee', sig, [tail_builder.param(0)])
	tail_builder.finish()

	module := Module{
		target:    builder_target()
		functions: [
			Function{
				name:      'callee'
				signature: sig
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
	results := builder.call_indirect(builder.param(0), signature([param(ty_i32, false)], [
		result(ty_i32, false),
	]), [builder.param(1)])
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

fn test_a_join_creates_one_parameter_per_live_variable() {
	mut function := new_function('diamond', [ty_i1], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	condition := builder.param(0)
	x := builder.declare_var(ty_i32)
	builder.def_var(x, builder.iconst(ty_i32, 0))
	then_block := builder.create_block()
	else_block := builder.create_block()
	join := builder.create_block()
	builder.condbr(condition, then_block, [], else_block, [])
	builder.switch_to_block(then_block)
	builder.def_var(x, builder.iconst(ty_i32, 1))
	builder.br(join, [])
	builder.switch_to_block(else_block)
	builder.def_var(x, builder.iconst(ty_i32, 2))
	builder.br(join, [])
	builder.switch_to_block(join)
	builder.seal_block(join)
	result := builder.use_var(x)
	builder.return_([result])
	builder.finish()

	assert function.blocks[join].params.len == 1
	parameter := function.blocks[join].params[0]
	assert function.values[parameter].typ == ty_i32
	assert function.values[parameter].kind == .block_param
	assert function.blocks[join].terminator.operands[0].idx == parameter
	assert function.blocks[then_block].terminator.target.args.len == 1
	assert function.blocks[else_block].terminator.target.args.len == 1
	then_value := function.blocks[then_block].instructions[0].results[0]
	else_value := function.blocks[else_block].instructions[0].results[0]
	assert function.blocks[then_block].terminator.target.args[0].idx == then_value
	assert function.blocks[else_block].terminator.target.args[0].idx == else_value
	assert_verified_function(function)
}

fn test_a_variable_defined_in_one_arm_reads_the_incoming_value() {
	mut function := new_function('one_arm', [ty_i1], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	condition := builder.param(0)
	x := builder.declare_var(ty_i32)
	incoming := builder.iconst(ty_i32, 0)
	builder.def_var(x, incoming)
	then_block := builder.create_block()
	else_block := builder.create_block()
	join := builder.create_block()
	builder.condbr(condition, then_block, [], else_block, [])
	builder.switch_to_block(then_block)
	builder.def_var(x, builder.iconst(ty_i32, 1))
	builder.br(join, [])
	builder.switch_to_block(else_block)
	builder.br(join, [])
	builder.switch_to_block(join)
	builder.seal_block(join)
	builder.seal_block(else_block)
	result := builder.use_var(x)
	builder.return_([result])
	builder.finish()

	assert function.blocks[join].params.len == 1
	assert function.blocks[else_block].terminator.target.args.len == 1
	assert function.blocks[else_block].terminator.target.args[0].idx == incoming.idx
	assert_verified_function(function)
}

fn test_a_loop_header_waits_for_its_back_edge() {
	mut function := new_function('sum', [ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	limit := builder.param(0)
	i := builder.declare_var(ty_i32)
	acc := builder.declare_var(ty_i32)
	builder.def_var(i, builder.iconst(ty_i32, 0))
	builder.def_var(acc, builder.iconst(ty_i32, 0))
	head := builder.create_block()
	builder.br(head, [])
	builder.switch_to_block(head)
	done := builder.icmp(.sge, builder.use_var(i), limit)
	body := builder.create_block()
	exit := builder.create_block()
	builder.condbr(done, exit, [], body, [])
	builder.switch_to_block(body)
	next := builder.iadd_flags(builder.use_var(i), builder.iconst(ty_i32, 1), flags(.nsw))
	builder.def_var(acc, builder.iadd(builder.use_var(acc), builder.use_var(i)))
	builder.def_var(i, next)
	builder.br(head, [])
	builder.seal_block(head)
	builder.seal_block(body)
	builder.switch_to_block(exit)
	builder.seal_block(exit)
	builder.return_([builder.use_var(acc)])
	builder.finish()

	assert function.blocks[head].params.len == 2
	assert function.blocks[entry].terminator.target.args.len == 2
	assert function.blocks[body].terminator.target.args.len == 2
	assert function.blocks[exit].params.len == 0
	assert_verified_function(function)
}

fn test_a_use_before_the_definition_reads_the_incoming_value() {
	mut function := new_function('shadow', [], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	x := builder.declare_var(ty_i32)
	five := builder.iconst(ty_i32, 5)
	builder.def_var(x, five)
	next := builder.create_block()
	builder.br(next, [])
	builder.switch_to_block(next)
	before := builder.use_var(x)
	builder.def_var(x, builder.iconst(ty_i32, 7))
	after := builder.use_var(x)
	total := builder.iadd(before, after)
	builder.return_([total])
	builder.seal_block(next)
	builder.finish()

	assert before.idx < 0
	assert function.blocks[next].params.len == 0
	addition := function.blocks[next].instructions[1]
	assert addition.opcode == .iadd
	assert addition.operands[0].idx == five.idx
	assert addition.operands[1].idx == after.idx
	assert_verified_function(function)
}

fn test_one_predecessor_resolves_the_use_directly() {
	mut function := new_function('direct', [], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	x := builder.declare_var(ty_i32)
	three := builder.iconst(ty_i32, 3)
	builder.def_var(x, three)
	next := builder.create_block()
	builder.br(next, [])
	builder.switch_to_block(next)
	result := builder.use_var(x)
	builder.return_([result])
	builder.seal_block(next)
	builder.finish()

	assert function.blocks[next].params.len == 0
	assert function.blocks[entry].terminator.target.args.len == 0
	assert function.blocks[next].terminator.operands[0].idx == three.idx
	assert_verified_function(function)
}

fn test_a_pending_value_is_patched_when_its_block_is_sealed() {
	mut function := new_function('late', [ty_i1], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	condition := builder.param(0)
	x := builder.declare_var(ty_i32)
	builder.def_var(x, builder.iconst(ty_i32, 0))
	then_block := builder.create_block()
	else_block := builder.create_block()
	join := builder.create_block()
	builder.condbr(condition, then_block, [], else_block, [])
	builder.switch_to_block(then_block)
	builder.def_var(x, builder.iconst(ty_i32, 1))
	builder.br(join, [])
	builder.switch_to_block(else_block)
	builder.def_var(x, builder.iconst(ty_i32, 2))
	builder.br(join, [])
	builder.switch_to_block(join)
	pending := builder.use_var(x)
	total := builder.iadd(pending, builder.iconst(ty_i32, 1))
	builder.seal_block(join)
	builder.return_([total])
	builder.finish()

	assert pending.idx < 0
	assert function.blocks[join].params.len == 1
	assert function.blocks[join].instructions[1].operands[0].idx == function.blocks[join].params[0]
	assert_verified_function(function)
}

fn test_a_switch_target_gets_an_argument_per_edge() {
	mut function := new_function('twice', [ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	selector := builder.param(0)
	x := builder.declare_var(ty_i32)
	builder.def_var(x, builder.iconst(ty_i32, 1))
	join := builder.create_block()
	builder.switch_(selector, join, [], [
		Case{
			value: u128(1)
			block: join
		},
	])
	builder.switch_to_block(join)
	builder.seal_block(join)
	builder.return_([builder.use_var(x)])
	builder.finish()

	assert function.blocks[join].params.len == 1
	assert function.blocks[entry].terminator.target.args.len == 1
	assert function.blocks[entry].terminator.cases[0].target.args.len == 1
	assert function.blocks[entry].terminator.target.args[0].idx == function.blocks[entry].terminator.cases[0].target.args[0].idx
	assert_verified_function(function)
}

fn test_if_creates_the_arms_and_the_join() {
	mut function := new_function('branchy', [ty_i1], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	condition := builder.param(0)
	x := builder.declare_var(ty_i32)
	builder.def_var(x, builder.iconst(ty_i32, 0))
	branch := builder.if_(condition)
	builder.switch_to_block(branch.then_block)
	builder.def_var(x, builder.iconst(ty_i32, 1))
	builder.br(branch.join, [])
	builder.switch_to_block(branch.else_block)
	builder.def_var(x, builder.iconst(ty_i32, 2))
	builder.br(branch.join, [])
	builder.switch_to_block(branch.join)
	builder.seal_block(branch.join)
	result := builder.use_var(x)
	builder.return_([result])
	builder.finish()

	assert branch.then_block == 1
	assert branch.else_block == 2
	assert branch.join == 3
	assert function.blocks[branch.join].params.len == 1
	assert function.blocks[branch.then_block].terminator.target.block == branch.join
	assert function.blocks[branch.else_block].terminator.target.block == branch.join
	assert_verified_function(function)
}

fn test_loop_builds_a_body_and_an_exit() {
	mut function := new_function('count', [ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	limit := builder.param(0)
	i := builder.declare_var(ty_i32)
	builder.def_var(i, builder.iconst(ty_i32, 0))
	loop := builder.loop_()
	next := builder.iadd(builder.use_var(i), builder.iconst(ty_i32, 1))
	builder.def_var(i, next)
	more := builder.icmp(.slt, builder.use_var(i), limit)
	builder.condbr(more, loop.head, [], loop.after, [])
	builder.seal_block(loop.head)
	builder.seal_block(loop.after)
	builder.switch_to_block(loop.after)
	builder.return_([builder.use_var(i)])
	builder.finish()

	assert loop.head == 1
	assert loop.body == 2
	assert loop.after == 3
	// i is live around the back edge, so the header takes it as a parameter
	assert function.blocks[loop.head].params.len == 1
	assert function.blocks[entry].terminator.target.args.len == 1
	assert function.blocks[loop.body].terminator.target.args.len == 1
	assert function.blocks[loop.after].params.len == 0
	assert_verified_function(function)
}

fn test_a_loop_that_breaks_out() {
	mut function := new_function('find', [ty_i32], [ty_i32])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	limit := builder.param(0)
	i := builder.declare_var(ty_i32)
	builder.def_var(i, builder.iconst(ty_i32, 0))
	loop := builder.loop_()
	step := builder.iadd(builder.use_var(i), builder.iconst(ty_i32, 1))
	builder.def_var(i, step)
	done := builder.icmp(.sge, builder.use_var(i), limit)
	break_block := builder.create_block()
	continue_block := builder.create_block()
	builder.condbr(done, break_block, [], continue_block, [])
	builder.switch_to_block(break_block)
	builder.loop_break(loop)
	builder.switch_to_block(continue_block)
	builder.loop_continue(loop)
	builder.switch_to_block(loop.after)
	builder.return_([builder.use_var(i)])
	builder.seal_all()
	builder.finish()

	assert function.blocks[break_block].terminator.target.block == loop.after
	assert function.blocks[continue_block].terminator.target.block == loop.head
	assert_verified_function(function)
}

// build_every_opcode is the builder's completeness check: one method per
// opcode, and the functions they build verify. The text corpus already proves
// the verifier covers the set; this proves the frontend can reach all of it.
fn build_every_opcode() Module {
	mut module := Module{
		target: builder_target()
	}
	callee := signature([param(ty_i32, false)], [result(ty_i32, false)])

	mut constants := new_function('op_constants', [ty_i32], [ty_i32])
	mut builder := new_builder(mut constants, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	answer := builder.iconst(ty_i32, 1)
	builder.fconst(ty_f64, u128(0))
	builder.null()
	builder.poison(ty_i32)
	builder.freeze(builder.param(0))
	builder.return_([answer])
	builder.finish()
	module.functions << constants

	mut integer := new_function('op_integer', [ty_i32, ty_i32], [ty_i32])
	mut ib := new_builder(mut integer, builder_target())
	start := ib.create_entry_block()
	ib.switch_to_block(start)
	a := ib.param(0)
	c := ib.param(1)
	one := ib.iconst(ty_i32, 1)
	mut value := ib.iadd(a, c)
	value = ib.isub(value, c)
	value = ib.imul(value, c)
	value = ib.sdiv(value, c)
	value = ib.udiv(value, c)
	value = ib.srem(value, c)
	value = ib.urem(value, c)
	value = ib.ineg(value)
	value = ib.iabs(value)
	value = ib.smin(value, a)
	value = ib.smax(value, a)
	value = ib.umin(value, a)
	value = ib.umax(value, a)
	value = ib.sadd_overflow(value, c).value
	value = ib.uadd_overflow(value, c).value
	value = ib.ssub_overflow(value, c).value
	value = ib.usub_overflow(value, c).value
	value = ib.smul_overflow(value, c).value
	value = ib.umul_overflow(value, c).value
	value = ib.sadd_sat(value, c)
	value = ib.uadd_sat(value, c)
	value = ib.ssub_sat(value, c)
	value = ib.usub_sat(value, c)
	value = ib.smul_sat(value, c)
	value = ib.umul_sat(value, c)
	value = ib.band(value, c)
	value = ib.bor(value, c)
	value = ib.bxor(value, c)
	value = ib.bnot(value)
	value = ib.shl(value, one)
	value = ib.sshr(value, one)
	value = ib.ushr(value, one)
	value = ib.rotl(value, one)
	value = ib.rotr(value, one)
	value = ib.clz(value)
	value = ib.ctz(value)
	value = ib.popcnt(value)
	value = ib.bswap(value)
	ib.return_([value])
	ib.finish()
	module.functions << integer

	mut float := new_function('op_float', [ty_f64, ty_f64, ty_f64], [ty_f64])
	mut fb := new_builder(mut float, builder_target())
	float_entry := fb.create_entry_block()
	fb.switch_to_block(float_entry)
	x := fb.param(0)
	y := fb.param(1)
	z := fb.param(2)
	mut f := fb.fadd(x, y)
	f = fb.fsub(f, y)
	f = fb.fmul(f, y)
	f = fb.fdiv(f, y)
	f = fb.frem(f, y)
	f = fb.fneg(f)
	f = fb.fabs(f)
	f = fb.fsqrt(f)
	f = fb.fcopysign(f, y)
	f = fb.fma(f, y, z)
	f = fb.fmin(f, y)
	f = fb.fmax(f, y)
	f = fb.fceil(f)
	f = fb.ffloor(f)
	f = fb.ftrunc(f)
	f = fb.fnearest(f)
	fb.fcmp(.ueq, x, y)
	fb.return_([f])
	fb.finish()
	module.functions << float

	mut conversion := new_function('op_conversion', [ty_i32, ty_i64, ty_f32, ty_f64, ty_ptr],
		[ty_i64])
	mut cb := new_builder(mut conversion, builder_target())
	conversion_entry := cb.create_entry_block()
	cb.switch_to_block(conversion_entry)
	small := cb.param(0)
	large := cb.param(1)
	narrow := cb.param(2)
	wide := cb.param(3)
	pointer := cb.param(4)
	cb.sext(small, ty_i64)
	cb.zext(small, ty_i64)
	cb.trunc(large, ty_i32)
	cb.bitcast(wide, ty_i64)
	cb.sitofp(small, ty_f64)
	cb.uitofp(small, ty_f64)
	cb.fptosi(wide, ty_i32)
	cb.fptoui(wide, ty_i32)
	cb.fpext(narrow, ty_f64)
	cb.fptrunc(wide, ty_f32)
	address := cb.ptrtoint(pointer, ty_i64)
	back := cb.inttoptr(address, ty_ptr)
	fb_condition := cb.icmp(.ugt, address, large)
	chosen := cb.select(fb_condition, address, large)
	cb.return_([chosen])
	cb.finish()
	module.functions << conversion

	mut memory := new_function('op_memory', [ty_ptr, ty_ptr, ty_i64], [ty_i32])
	mut mb := new_builder(mut memory, builder_target())
	memory_entry := mb.create_entry_block()
	mb.switch_to_block(memory_entry)
	dst := mb.param(0)
	src := mb.param(1)
	len := mb.param(2)
	loaded := mb.load(dst, ty_i32)
	mb.store(src, loaded)
	shifted := mb.ptradd(dst, len)
	mb.memcpy(dst, src, len, 4, 4)
	mb.memmove(src, dst, len, 4, 4)
	mb.memset(dst, mb.iconst(ty_i8, 0), len, 4)
	slot := mb.create_stack_slot(8, 4, 'slot')
	slot_address := mb.stack_addr(slot)
	mb.store_aligned(slot_address, loaded, 4)
	mb.global_addr('data')
	mb.func_addr('op_constants')
	mb.store(shifted, loaded)
	mb.return_([loaded])
	mb.finish()
	module.functions << memory

	mut calls := new_function('op_calls', [ty_ptr, ty_i32], [ty_i32])
	mut callb := new_builder(mut calls, builder_target())
	calls_entry := callb.create_entry_block()
	callb.switch_to_block(calls_entry)
	callee_pointer := callb.param(0)
	argument := callb.param(1)
	direct := callb.call('callee', callee, [argument])
	indirect := callb.call_indirect(callee_pointer, callee, [direct[0]])
	callb.assume(callb.icmp(.ne, indirect[0], callb.iconst(ty_i32, 0)))
	assembled := callb.inline_asm(Asm{
		template: 'mov $1, $0'
		outputs:  [
			AsmOutput{
				typ:        ty_i32
				constraint: '=r'
			},
		]
		inputs:   [
			AsmInput{
				value:      indirect[0]
				constraint: 'r'
			},
		]
	})
	taken := callb.create_block()
	other := callb.create_block()
	join := callb.create_block()
	callb.condbr(callb.icmp(.slt, assembled[0], argument), taken, [], other, [])
	callb.switch_to_block(taken)
	callb.br(join, [])
	callb.switch_to_block(other)
	callb.switch_(argument, join, [], [
		Case{
			value: u128(1)
			block: join
		},
	])
	callb.switch_to_block(join)
	callb.return_([assembled[0]])
	callb.finish()
	module.functions << calls

	mut tail := new_function('op_tail', [ty_i32], [ty_i32])
	mut tailb := new_builder(mut tail, builder_target())
	tail_entry := tailb.create_entry_block()
	tailb.switch_to_block(tail_entry)
	tailb.tailcall('callee', callee, [tailb.param(0)])
	tailb.finish()
	module.functions << tail

	mut tail_indirect := new_function('op_tail_indirect', [ty_ptr, ty_i32], [ty_i32])
	mut tib := new_builder(mut tail_indirect, builder_target())
	tib_entry := tib.create_entry_block()
	tib.switch_to_block(tib_entry)
	tib.tailcall_indirect(tib.param(0), callee, [tib.param(1)])
	tib.finish()
	module.functions << tail_indirect

	mut never := new_function('op_unreachable', [], [])
	mut neverb := new_builder(mut never, builder_target())
	never_entry := neverb.create_entry_block()
	neverb.switch_to_block(never_entry)
	neverb.unreachable()
	neverb.finish()
	module.functions << never

	mut stop := new_function('op_trap', [], [])
	mut stopb := new_builder(mut stop, builder_target())
	stop_entry := stopb.create_entry_block()
	stopb.switch_to_block(stop_entry)
	stopb.trap(3)
	stopb.finish()
	module.functions << stop

	module.functions << Function{
		name:      'callee'
		signature: callee
	}
	module.globals << Global{
		name: 'data'
		typ:  ty_i64
	}
	return module
}

fn test_every_opcode_has_a_builder_method() {
	module := build_every_opcode()
	mut seen := map[Opcode]bool{}
	for function in module.functions {
		for block in function.blocks {
			for inst in block.instructions {
				seen[inst.opcode] = true
			}
			if block.terminator.opcode.is_terminator() {
				seen[block.terminator.opcode] = true
			}
		}
	}
	mut missing := []string{}
	for op in all_opcodes() {
		if op !in seen {
			missing << op.name()
		}
	}
	assert missing.len == 0, 'no builder method builds: ${missing.join(', ')}'
	errors := verify_module(&module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')
}

fn test_float_flags_build_and_verify() {
	mut function := new_function('fmath', [ty_f64, ty_f64], [ty_f64])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	left := builder.param(0)
	right := builder.param(1)
	sum := builder.fadd_flags(left, right, fast_math(.nnan, .reassoc))
	product := builder.fmul_flags(sum, right, fast_math(.contract))
	root := builder.fsqrt_flags(product, fast_math(.ninf))
	measured := builder.fma_flags(left, right, root, fast_math(.afn))
	chosen := builder.select(builder.fcmp_flags(.olt, measured, left, fast_math(.nnan)), measured,
		left)
	builder.return_([chosen])
	builder.finish()
	instructions := function.blocks[0].instructions
	assert instructions[0].flags.nnan && instructions[0].flags.reassoc
	assert instructions[1].flags.contract
	assert instructions[2].flags.ninf
	assert instructions[3].flags.afn
	assert instructions[4].flags.nnan
	assert_verified_function(function)
}

fn test_a_width_that_is_not_a_power_of_two_aligns_to_one() {
	mut function := new_function('narrow', [ty_ptr], [int_type(24)])
	mut builder := new_builder(mut function, builder_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	pointer := builder.param(0)
	loaded := builder.load(pointer, int_type(24))
	builder.return_([loaded])
	builder.finish()
	assert function.blocks[0].instructions[0].align == 1
	assert_verified_function(function)
}

// A frontend builds a global from a type and a constant tree, and a function
// from a signature that carries effects and noundef. The module the builder
// assembles verifies, prints, and reads back as the same module.
fn test_the_builder_builds_a_typed_global_and_a_signature_with_effects() {
	target := builder_target()
	mut module := Module{
		target: target
	}
	pair := struct_type([ty_i32, ty_ptr])
	module.globals << new_global('table', pair, seq_const([int_const(7), null_const()]))
	module.globals << new_global('zeroed', array_type(ty_i32, 4), none)
	module.globals << new_global('weights', vector_type(ty_f32, 2), seq_const([
		float_const(ty_f32, 0x3f800000),
		float_const(ty_f32, 0x40000000),
	]))
	mut limit := new_global('limit', ty_i64, int_const(64))
	limit.readonly = true
	module.globals << limit

	sig := signature_with_effects([param(ty_ptr, true), param(ty_i32, false)], [
		result(ty_i32, true),
	], effects(.readonly, .nounwind))
	mut function := new_function_signature('select_limit', sig)
	mut builder := new_builder(mut function, target)
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	loaded := builder.load(builder.param(0), ty_i32)
	limited := builder.iadd(loaded, builder.param(1))
	builder.return_([limited])
	builder.finish()
	module.functions << function

	text := print_module(&module)
	assert text.contains('global @table: {i32, ptr} = {7, null}\n'), text
	assert text.contains('global @zeroed: [4 x i32]\n'), text
	assert text.contains('global @weights: <2 x f32> = [f32 0x3f800000, f32 0x40000000]\n'), text
	assert text.contains('fn @select_limit(%arg0: ptr noundef, %arg1: i32) -> i32 noundef readonly nounwind {\n'), text
	errors := verify_module(&module)
	assert errors.len == 0, errors.map(it.msg()).join('\n')

	parsed := parse_text(text) or { panic('the printed module does not parse: ${err.msg()}\n${text}') }
	assert parsed.globals.len == module.globals.len
	for i, global in parsed.globals {
		assert global.typ == module.globals[i].typ
	}
	table := parsed.globals[0]
	table_init := table.init or { panic('@table lost its initializer') }
	assert table_init.elems.len == 2
	assert table_init.elems[0].bits == u128(7)
	assert table_init.elems[1].kind == .null
	weights := parsed.globals[2].init or { panic('@weights lost its initializer') }
	assert weights.elems[0].typ == ty_f32
	assert parsed.functions[0].signature.params[0].noundef
	assert parsed.functions[0].signature.results[0].noundef
	assert parsed.functions[0].signature.effects.readonly
	assert parsed.functions[0].signature.effects.nounwind
	assert parsed.functions[0].signature.effects.readnone == false
	assert verify_module(&parsed).len == 0
	assert print_module(&parsed) == text
}
