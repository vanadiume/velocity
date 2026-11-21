module optimize

import vanadiume.velocity.ir

// Dead code elimination. An instruction that computes a value, touches nothing
// else, and has no result anybody reads is erased, and erasing it can make its
// operands dead in turn. The use counts are taken once and updated locally, so
// the pass walks the function once.

pub fn dead_code_elim() Pass {
	return Pass{
		name: 'dead_code_elim'
		run:  eliminate_function
	}
}

struct Candidate {
	block int
	inst  int
}

fn eliminate_function(mut function ir.Function) bool {
	mut counts := use_counts(function)
	mut dead := [][]bool{len: function.blocks.len}
	mut queue := []Candidate{}
	for bi in 0 .. function.blocks.len {
		dead[bi] = []bool{len: function.blocks[bi].instructions.len}
		for ii in 0 .. function.blocks[bi].instructions.len {
			inst := function.blocks[bi].instructions[ii]
			if removes(inst) && unused(inst, counts) {
				queue << Candidate{
					block: bi
					inst:  ii
				}
			}
		}
	}
	mut changed := false
	for queue.len > 0 {
		candidate := queue.pop()
		if candidate.block < 0 || candidate.block >= function.blocks.len {
			continue
		}
		if candidate.inst < 0 || candidate.inst >= function.blocks[candidate.block].instructions.len {
			continue
		}
		if dead[candidate.block][candidate.inst] {
			continue
		}
		inst := function.blocks[candidate.block].instructions[candidate.inst]
		if !removes(inst) || !unused(inst, counts) {
			// A candidate can be queued while an operand still has a use that a
			// later erase removes. The recheck is what keeps the queue honest.
			continue
		}
		dead[candidate.block][candidate.inst] = true
		changed = true
		release(inst, mut counts, mut dead, mut queue, function)
	}
	if !changed {
		return false
	}
	erase_instructions(mut function, dead)
	return true
}

// release drops one use of each operand and queues the definition of an operand
// that no longer has any. The queue decides whether the definition is
// removable; this only notices that it became a candidate.
fn release(inst ir.Instruction, mut counts []int, mut dead [][]bool, mut queue []Candidate,
	function &ir.Function) {
	for operand in inst.operands {
		release_operand(operand, mut counts, mut dead, mut queue, function)
	}
	for operand in inst.target.args {
		release_operand(operand, mut counts, mut dead, mut queue, function)
	}
	for operand in inst.else_target.args {
		release_operand(operand, mut counts, mut dead, mut queue, function)
	}
	for case_ in inst.cases {
		for operand in case_.target.args {
			release_operand(operand, mut counts, mut dead, mut queue, function)
		}
	}
	for input in inst.asm.inputs {
		release_operand(input.value, mut counts, mut dead, mut queue, function)
	}
}

fn release_operand(operand ir.Operand, mut counts []int, mut dead [][]bool, mut queue []Candidate,
	function &ir.Function) {
	if operand.kind != .value {
		return
	}
	index := operand.idx
	if index < 0 || index >= counts.len || counts[index] == 0 {
		return
	}
	counts[index]--
	if counts[index] > 0 {
		return
	}
	value := function.values[index]
	if value.kind != .instruction_result {
		return
	}
	if value.block < 0 || value.block >= function.blocks.len {
		return
	}
	if value.inst < 0 || value.inst >= function.blocks[value.block].instructions.len {
		return
	}
	if dead[value.block][value.inst] {
		return
	}
	queue << Candidate{
		block: value.block
		inst:  value.inst
	}
}

// removes is the set from optimizer.md: an instruction that computes a value and
// touches nothing else. A load, a store, a call, an inline asm block and an
// assume all stay, and so does every terminator.
fn removes(inst ir.Instruction) bool {
	if inst.opcode.is_terminator() {
		return false
	}
	return match inst.opcode {
		.iconst, .fconst, .null, .poison, .freeze {
			true
		}
		.iadd, .isub, .imul, .sdiv, .udiv, .srem, .urem, .ineg, .iabs, .smin, .smax,
		.umin, .umax {
			true
		}
		.sadd_overflow, .uadd_overflow, .ssub_overflow, .usub_overflow, .smul_overflow,
		.umul_overflow {
			true
		}
		.sadd_sat, .uadd_sat, .ssub_sat, .usub_sat, .smul_sat, .umul_sat {
			true
		}
		.band, .bor, .bxor, .bnot, .shl, .sshr, .ushr, .rotl, .rotr, .clz, .ctz, .popcnt,
		.bswap {
			true
		}
		.icmp, .fcmp {
			true
		}
		.fadd, .fsub, .fmul, .fdiv, .frem, .fneg, .fabs, .fsqrt, .fcopysign, .fma, .fmin,
		.fmax, .fceil, .ffloor, .ftrunc, .fnearest {
			true
		}
		.sext, .zext, .trunc, .bitcast, .ptrtoint, .inttoptr, .sitofp, .uitofp, .fptosi,
		.fptoui, .fpext, .fptrunc {
			true
		}
		.@select, .ptradd, .stack_addr, .global_addr, .func_addr {
			true
		}
		else {
			false
		}
	}
}

fn unused(inst ir.Instruction, counts []int) bool {
	if inst.results.len == 0 {
		return false
	}
	for result in inst.results {
		if result < 0 || result >= counts.len {
			return false
		}
		if counts[result] > 0 {
			return false
		}
	}
	return true
}
