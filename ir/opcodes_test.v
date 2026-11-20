module ir

import os

fn read_fixture(name string) string {
	path := os.join_path(@DIR, 'testdata', name)
	return os.read_file(path) or { panic('cannot read ${path}: ${err}') }
}

// The canonical list from ir-instructions.md, "Opcodes at a glance", copied
// here so the test fails if the table in opcodes.v and the reference drift
// apart. The order is the reference's order.
const canonical_opcodes = [
	'iconst',
	'fconst',
	'null',
	'poison',
	'freeze',
	'iadd',
	'isub',
	'imul',
	'sdiv',
	'udiv',
	'srem',
	'urem',
	'ineg',
	'iabs',
	'smin',
	'smax',
	'umin',
	'umax',
	'sadd_overflow',
	'uadd_overflow',
	'ssub_overflow',
	'usub_overflow',
	'smul_overflow',
	'umul_overflow',
	'sadd_sat',
	'uadd_sat',
	'ssub_sat',
	'usub_sat',
	'smul_sat',
	'umul_sat',
	'band',
	'bor',
	'bxor',
	'bnot',
	'shl',
	'sshr',
	'ushr',
	'rotl',
	'rotr',
	'clz',
	'ctz',
	'popcnt',
	'bswap',
	'icmp',
	'fcmp',
	'fadd',
	'fsub',
	'fmul',
	'fdiv',
	'frem',
	'fneg',
	'fabs',
	'fsqrt',
	'fcopysign',
	'fma',
	'fmin',
	'fmax',
	'fceil',
	'ffloor',
	'ftrunc',
	'fnearest',
	'sext',
	'zext',
	'trunc',
	'bitcast',
	'ptrtoint',
	'inttoptr',
	'sitofp',
	'uitofp',
	'fptosi',
	'fptoui',
	'fpext',
	'fptrunc',
	'select',
	'load',
	'store',
	'ptradd',
	'memcpy',
	'memmove',
	'memset',
	'stack_addr',
	'global_addr',
	'func_addr',
	'br',
	'condbr',
	'switch',
	'return',
	'unreachable',
	'trap',
	'assume',
	'call',
	'call_indirect',
	'tailcall',
	'tailcall_indirect',
	'inline_asm',
]

fn test_the_opcode_table_matches_the_reference() {
	names := opcode_names_list()
	assert canonical_opcodes.len == 95
	assert names.len == 95
	for i in 0 .. canonical_opcodes.len {
		assert names[i] == canonical_opcodes[i], 'opcode ${i} is ${names[i]}, the reference has ${canonical_opcodes[i]}'
	}
}

fn test_every_opcode_has_one_name_and_one_entry() {
	mut seen_names := map[string]bool{}
	mut seen_opcodes := map[int]bool{}
	for op in all_opcodes() {
		name := op.name()
		assert name != 'unknown'
		assert name !in seen_names, 'two opcodes are spelled ${name}'
		seen_names[name] = true
		assert int(op) !in seen_opcodes, '${name} is listed twice'
		seen_opcodes[int(op)] = true
	}
	assert seen_names.len == 95
	assert seen_opcodes.len == 95
	for name in canonical_opcodes {
		op := opcode_from_name(name) or { panic('${name} is not in the table') }
		assert op.name() == name
	}
	assert opcode_from_name('frobnicate') == none
}

fn test_terminators() {
	terminators := [Opcode.br, .condbr, .switch, .@return, .tailcall, .tailcall_indirect, .unreachable,
		.trap]
	for op in terminators {
		assert op.is_terminator(), '${op.name()} is a terminator'
	}
	for op in all_opcodes() {
		if op in terminators {
			continue
		}
		assert !op.is_terminator(), '${op.name()} is not a terminator'
	}
}

fn test_result_counts() {
	assert Opcode.iadd.fixed_result_count() == 1
	assert Opcode.sadd_overflow.fixed_result_count() == 2
	assert Opcode.umul_overflow.fixed_result_count() == 2
	assert Opcode.store.fixed_result_count() == 0
	assert Opcode.@return.fixed_result_count() == 0
	assert Opcode.tailcall.fixed_result_count() == 0
	assert Opcode.unreachable.fixed_result_count() == 0
	// The count comes from the callee's signature or from the asm outputs.
	assert Opcode.call.fixed_result_count() == -1
	assert Opcode.call_indirect.fixed_result_count() == -1
	assert Opcode.inline_asm.fixed_result_count() == -1
}

// The fixture under testdata parses into a module whose opcodes are exactly the
// reference's list: every one appears, and none appears that is not in it.
fn test_the_fixture_exercises_every_opcode() {
	text := read_fixture('opcodes.vel')
	m := parse_text(text) or { panic('${err.msg()}') }
	mut seen := map[int]bool{}
	for f in m.functions {
		for b in f.blocks {
			for inst in b.instructions {
				seen[int(inst.opcode)] = true
			}
			seen[int(b.terminator.opcode)] = true
		}
	}
	assert seen.len == 95, '${seen.len} opcodes appear'
	for name in canonical_opcodes {
		op := opcode_from_name(name) or { panic('${name} is not in the table') }
		assert int(op) in seen, '${name} does not appear in the fixture'
	}
}
