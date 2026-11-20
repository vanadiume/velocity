module ir

import os

fn read_fixture(name string) string {
	path := os.join_path(@DIR, 'testdata', name)
	return os.read_file(path) or { panic('cannot read ${path}: ${err}') }
}

fn load_canonical() Module {
	return parse_text(read_fixture('canonical.vel')) or { panic('${err.msg()}') }
}

fn function_index(m Module, name string) int {
	return m.find_function_index(name) or { panic('@${name} is not in the module') }
}

fn test_target_line() {
	m := load_canonical()
	assert m.target.pointer_width == 64
	assert m.target.pointer_align == 8
	assert m.target.endian == .little
}

fn test_globals_keep_their_order_and_bytes() {
	m := load_canonical()
	assert m.globals.len == 4
	counter := m.globals[0]
	assert counter.name == 'counter'
	assert counter.size == 8
	assert counter.align == 8
	assert counter.public
	assert counter.readonly == false
	assert counter.init == [u8(0), 0, 0, 0, 0, 0, 0, 1]
	message := m.globals[1]
	assert message.name == 'message'
	assert message.size == 16
	assert message.align == 16
	assert message.readonly
	assert message.public == false
	assert message.init.len == 16
	assert message.init[0] == u8(`h`)
	assert message.init[4] == u8(`o`)
	scratch := m.globals[2]
	assert scratch.size == 4096
	assert scratch.init.len == 0
	// The last global is declared after the functions that name it.
	assert m.globals[3].name == 'late_global'
}

fn test_functions_keep_their_order() {
	m := load_canonical()
	names := ['puts', 'identity', 'minmax', 'max', 'classify', 'dispatch', 'copy', 'tail', 'forward_ref',
		'late_function']
	assert m.functions.len == names.len
	for i in 0 .. names.len {
		assert m.functions[i].name == names[i]
	}
}

fn test_extern_declaration_has_a_signature_and_no_blocks() {
	m := load_canonical()
	index := function_index(m, 'identity')
	f := m.functions[index]
	assert f.defined == false
	assert f.blocks.len == 0
	assert f.signature.params == [ty_i64]
	assert f.signature.results == [ty_i64]
}

fn test_signature_with_two_results() {
	m := load_canonical()
	f := m.functions[function_index(m, 'classify')]
	assert f.public
	assert f.defined
	assert f.signature.params == [ty_i32]
	assert f.signature.results == [ty_i32, ty_i32]
}

fn test_stack_slot_before_the_blocks() {
	m := load_canonical()
	f := m.functions[function_index(m, 'classify')]
	assert f.stack_slots.len == 1
	slot := f.stack_slots[0]
	assert slot.size == 8
	assert slot.align == 8
	assert slot.name or { '' } == 'slot0'
	first := f.blocks[0].instructions[0]
	assert first.opcode == .stack_addr
	assert first.operands[0].kind == .stack_slot
	assert first.operands[0].idx == 0
}

fn test_blocks_and_block_parameters() {
	m := load_canonical()
	f := m.functions[function_index(m, 'classify')]
	assert f.blocks.len == 7
	labels := ['block0', 'block1', 'block2', 'block3', 'block4', 'block5', 'block6']
	for i in 0 .. labels.len {
		assert f.blocks[i].label == labels[i]
	}
	assert f.blocks[0].params.len == 0
	assert f.blocks[3].params.len == 2
	assert f.values[f.blocks[3].params[0]].typ == ty_i32
	assert f.blocks[5].params.len == 1
}

fn test_terminator_is_stored_apart_from_the_instructions() {
	m := load_canonical()
	f := m.functions[function_index(m, 'classify')]
	// block0 writes a slot address, a store, a load and a comparison, then the
	// branch: the branch is the block's terminator, not one of its instructions.
	assert f.blocks[0].instructions.len == 4
	assert f.blocks[0].terminator.opcode == .condbr
	for inst in f.blocks[0].instructions {
		assert inst.opcode.is_terminator() == false
	}
	assert f.blocks[1].terminator.opcode == .br
	assert f.blocks[1].instructions.len == 1
}

fn test_jump_targets_resolve_to_block_indices() {
	m := load_canonical()
	f := m.functions[function_index(m, 'classify')]
	condbr := f.blocks[0].terminator
	assert condbr.target.label == 'block1'
	assert condbr.target.block == 1
	assert condbr.else_target.label == 'block2'
	assert condbr.else_target.block == 2
	br := f.blocks[1].terminator
	assert br.target.block == 3
	assert br.target.args.len == 2
	// The jump passes an immediate and a value.
	assert br.target.args[0].kind == .value
	assert br.target.args[0].idx == f.blocks[1].instructions[0].results[0] // %v3
	assert br.target.args[1].kind == .value
	assert br.target.args[1].idx == f.blocks[0].instructions[2].results[0] // %v1
}

fn test_switch_cases() {
	m := load_canonical()
	f := m.functions[function_index(m, 'classify')]
	sw := f.blocks[3].terminator
	assert sw.opcode == .switch
	assert sw.target.label == 'block6'
	assert sw.cases.len == 2
	assert sw.cases[0].value == u128(0)
	assert sw.cases[0].target.block == 4
	assert sw.cases[1].value == u128(1)
	assert sw.cases[1].target.label == 'block5'
	assert sw.cases[1].target.args.len == 1
}

fn test_load_and_store_carry_their_type_and_alignment() {
	m := load_canonical()
	f := m.functions[function_index(m, 'classify')]
	store := f.blocks[0].instructions[1]
	assert store.opcode == .store
	assert store.align == 4
	assert store.operands.len == 2
	load := f.blocks[0].instructions[2]
	assert load.opcode == .load
	assert load.typ == ty_i32
	assert load.align == 4
	assert m.functions[function_index(m, 'classify')].values[load.results[0]].typ == ty_i32
}

fn test_direct_calls_take_their_signature_from_the_declaration() {
	m := load_canonical()
	f := m.functions[function_index(m, 'max')]
	assert f.blocks[0].terminator.opcode == .@return
	classify := m.functions[function_index(m, 'classify')]
	call := classify.blocks[5].instructions[0]
	assert call.opcode == .call
	assert call.operands[0].kind == .symbol
	assert call.operands[0].name == 'max'
	assert call.operands[0].sym == .function
	assert call.signature.params == [ty_i32, ty_i32]
	assert call.signature.results == [ty_i32]
	assert classify.values[call.results[0]].typ == ty_i32
}

fn test_indirect_calls_carry_a_signature() {
	m := load_canonical()
	f := m.functions[function_index(m, 'dispatch')]
	first := f.blocks[0].instructions[0]
	assert first.opcode == .call_indirect
	assert first.operands.len == 2
	assert first.operands[0].kind == .value
	assert first.signature.params == [ty_i64]
	assert first.signature.results == [ty_i64]
	assert f.values[first.results[0]].typ == ty_i64
	last := f.blocks[0].instructions[7]
	assert last.opcode == .call_indirect
	assert last.signature.params == [ty_i64, ty_i64]
	assert last.operands.len == 3
}

fn test_tail_calls() {
	m := load_canonical()
	f := m.functions[function_index(m, 'tail')]
	term := f.blocks[0].terminator
	assert term.opcode == .tailcall_indirect
	assert term.signature.params == [ty_i64]
	assert term.signature.results == [ty_i64]
	classify := m.functions[function_index(m, 'classify')]
	tail := classify.blocks[6].terminator
	assert tail.opcode == .tailcall
	assert tail.operands[0].name == 'minmax'
}

fn test_pointer_conversions() {
	m := load_canonical()
	f := m.functions[function_index(m, 'dispatch')]
	ptrtoint := f.blocks[0].instructions[4]
	assert ptrtoint.opcode == .ptrtoint
	// ptrtoint without `to` takes the target's pointer width.
	assert f.values[ptrtoint.results[0]].typ == ty_i64
	inttoptr := f.blocks[0].instructions[5]
	assert inttoptr.opcode == .inttoptr
	assert f.values[inttoptr.results[0]].typ == ty_ptr
	ptradd := f.blocks[0].instructions[6]
	assert ptradd.opcode == .ptradd
	assert ptradd.flags.inbounds
	assert f.values[ptradd.results[0]].typ == ty_ptr
}

fn test_inline_asm_clauses() {
	m := load_canonical()
	f := m.functions[function_index(m, 'dispatch')]
	block_asm := f.blocks[0].instructions[3]
	assert block_asm.opcode == .inline_asm
	assert block_asm.asm.template == 'mov $0, $1; add $1, $2'
	assert block_asm.asm.outputs.len == 2
	assert block_asm.asm.outputs[0].typ == ty_i64
	assert block_asm.asm.outputs[0].constraint == '=r'
	assert block_asm.asm.outputs[1].typ == ty_i32
	assert block_asm.asm.inputs.len == 2
	assert block_asm.asm.inputs[0].value.kind == .value
	assert block_asm.asm.inputs[0].constraint == 'r'
	assert block_asm.asm.clobbers == ['cc', 'memory']
	assert block_asm.asm.volatile
	assert block_asm.asm.alignstack == false
	assert block_asm.asm.intel == false
	assert block_asm.results.len == 2
	assert f.values[block_asm.results[0]].typ == ty_i64
	assert f.values[block_asm.results[1]].typ == ty_i32
}

fn test_inline_asm_written_on_one_line() {
	text := 'target 64 little 8
fn @f(%arg0: i64) -> i64 {
block0:
  %v0 = inline_asm "nop" out(i64, "=r") in(%arg0, "r") clobber("memory") intel
  return %v0
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	block_asm := m.functions[0].blocks[0].instructions[0]
	assert block_asm.asm.inputs.len == 1
	assert block_asm.asm.clobbers == ['memory']
	assert block_asm.asm.intel
	assert block_asm.asm.volatile == false
}

fn test_source_location() {
	m := load_canonical()
	f := m.functions[function_index(m, 'dispatch')]
	located := f.blocks[0].instructions[7]
	loc := located.loc or { panic('the instruction has no location') }
	assert loc.file == 'dispatch.vel'
	assert loc.line == 12
	assert loc.col == 5
	assert f.blocks[0].instructions[0].loc == none
	assert f.blocks[0].instructions[3].loc == none
}

fn test_bulk_memory_takes_two_alignments() {
	m := load_canonical()
	f := m.functions[function_index(m, 'copy')]
	copy := f.blocks[0].instructions[0]
	assert copy.opcode == .memcpy
	assert copy.operands.len == 3
	assert copy.align_dst == 8
	assert copy.align_src == 4
	move := f.blocks[0].instructions[1]
	assert move.opcode == .memmove
	assert move.align_dst == 16
	assert move.align_src == 8
	set := f.blocks[0].instructions[2]
	assert set.opcode == .memset
	assert set.operands.len == 3
	assert set.operands[1].kind == .int_imm
	assert set.operands[2].imm == u128(32)
	assert set.align == 4
}

fn test_trap_code() {
	m := load_canonical()
	f := m.functions[function_index(m, 'late_function')]
	assert f.blocks[0].terminator.opcode == .trap
	assert f.blocks[0].terminator.trap_code == 7
}

// The same file through parse_file has to give the same module.
fn test_parse_file_matches_parse_text() {
	path := os.join_path(@DIR, 'testdata', 'canonical.vel')
	from_file := parse_file(path) or { panic('${err.msg()}') }
	from_text := load_canonical()
	assert from_file.functions.len == from_text.functions.len
	assert from_file.globals.len == from_text.globals.len
	assert from_file.functions[3].blocks.len == from_text.functions[3].blocks.len
	assert from_file.target == from_text.target
}

fn test_a_function_with_no_results_writes_no_arrow() {
	text := 'target 64 little 8
fn @f(%arg0: ptr) {
block0:
  return
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	assert m.functions[0].signature.results.len == 0
	assert m.functions[0].blocks[0].terminator.operands.len == 0
}

fn test_comments_and_blank_lines_are_ignored() {
	text := 'target 32 big 4
; a module with one function
fn @f() {

block0: ; the entry

  unreachable
}
'
	m := parse_text(text) or { panic('${err.msg()}') }
	assert m.target.pointer_width == 32
	assert m.target.endian == .big
	assert m.functions[0].blocks.len == 1
	assert m.functions[0].blocks[0].terminator.opcode == .unreachable
}
