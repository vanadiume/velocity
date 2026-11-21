module optimize

import vanadiume.velocity.ir

// The rewrite layer. A pass that changes which value an operand names, or that
// removes an instruction, goes through these three functions, because the value
// table and every site that names it have to change together.

// use_counts answers one count per value: how many operand sites name it.
// Instruction operands, jump arguments, switch case arguments and inline asm
// inputs all count, and a block's terminator counts like any instruction.
pub fn use_counts(function &ir.Function) []int {
	mut counts := []int{len: function.values.len}
	for block in function.blocks {
		for inst in block.instructions {
			count_sites(inst, mut counts)
		}
		count_sites(block.terminator, mut counts)
	}
	return counts
}

fn count_sites(inst ir.Instruction, mut counts []int) {
	for operand in inst.operands {
		count_site(operand, mut counts)
	}
	for operand in inst.target.args {
		count_site(operand, mut counts)
	}
	for operand in inst.else_target.args {
		count_site(operand, mut counts)
	}
	for case_ in inst.cases {
		for operand in case_.target.args {
			count_site(operand, mut counts)
		}
	}
	for input in inst.asm.inputs {
		count_site(input.value, mut counts)
	}
}

fn count_site(operand ir.Operand, mut counts []int) {
	if operand.kind != .value {
		return
	}
	if operand.idx < 0 || operand.idx >= counts.len {
		return
	}
	counts[operand.idx]++
}

// replace_uses points every operand that names `value` at `replacement`, and
// answers how many sites it changed. The definition is left where it is; a
// pass that has made it dead leaves that to dead code elimination.
pub fn replace_uses(mut function ir.Function, value int, replacement ir.Operand) int {
	mut count := 0
	for bi in 0 .. function.blocks.len {
		for ii in 0 .. function.blocks[bi].instructions.len {
			mut inst := function.blocks[bi].instructions[ii]
			count += replace_in_instruction(mut inst, value, replacement)
			function.blocks[bi].instructions[ii] = inst
		}
		mut terminator := function.blocks[bi].terminator
		count += replace_in_instruction(mut terminator, value, replacement)
		function.blocks[bi].terminator = terminator
	}
	return count
}

fn replace_in_instruction(mut inst ir.Instruction, value int, replacement ir.Operand) int {
	mut count := replace_in_operands(mut inst.operands, value, replacement)
	mut target := inst.target
	count += replace_in_operands(mut target.args, value, replacement)
	inst.target = target
	mut else_target := inst.else_target
	count += replace_in_operands(mut else_target.args, value, replacement)
	inst.else_target = else_target
	for ci in 0 .. inst.cases.len {
		mut case_target := inst.cases[ci].target
		count += replace_in_operands(mut case_target.args, value, replacement)
		inst.cases[ci].target = case_target
	}
	for ai in 0 .. inst.asm.inputs.len {
		mut input := inst.asm.inputs[ai]
		if names(input.value, value) {
			input.value = replacement
			inst.asm.inputs[ai] = input
			count++
		}
	}
	return count
}

fn replace_in_operands(mut operands []ir.Operand, value int, replacement ir.Operand) int {
	mut count := 0
	for i in 0 .. operands.len {
		if names(operands[i], value) {
			operands[i] = replacement
			count++
		}
	}
	return count
}

fn names(operand ir.Operand, value int) bool {
	return operand.kind == .value && operand.idx == value
}

// erase_instructions removes the instructions the matrix marks dead, together
// with the value-table rows they defined, and renumbers every index that named
// a surviving value. dead is parallel to the blocks and to each block's
// instruction list; a terminator is never dead.
//
// It panics rather than answering an error when a site still names a value that
// was erased: that is a bug in the caller, and a dangling index is worse than a
// stop.
pub fn erase_instructions(mut function ir.Function, dead [][]bool) bool {
	if dead.len != function.blocks.len {
		panic('erase_instructions: the dead matrix has ${dead.len} blocks, and @${function.name} has ${function.blocks.len}')
	}
	mut any_dead := false
	for bi in 0 .. function.blocks.len {
		if dead[bi].len != function.blocks[bi].instructions.len {
			panic('erase_instructions: block ${bi} of @${function.name} has ${function.blocks[bi].instructions.len} instructions, and the dead matrix gives it ${dead[bi].len}')
		}
		for ii in 0 .. dead[bi].len {
			if dead[bi][ii] {
				any_dead = true
			}
		}
	}
	if !any_dead {
		return false
	}

	// keep is the rows that stay, and remap is where each of them lands.
	mut keep := []bool{len: function.values.len}
	for i, value in function.values {
		keep[i] = match value.kind {
			.function_param, .block_param { true }
			.instruction_result {
				value.block >= 0 && value.block < function.blocks.len && value.inst >= 0
					&& value.inst < function.blocks[value.block].instructions.len
					&& !dead[value.block][value.inst]
			}
		}
	}
	mut remap := []int{len: function.values.len, init: -1}
	mut kept := 0
	for i in 0 .. keep.len {
		if keep[i] {
			remap[i] = kept
			kept++
		}
	}

	// Erase the instructions and remember where each survivor landed inside its
	// block, because Value.inst is an instruction index.
	mut landed := [][]int{len: function.blocks.len}
	for bi in 0 .. function.blocks.len {
		landed[bi] = []int{len: function.blocks[bi].instructions.len, init: -1}
		mut instructions := []ir.Instruction{cap: function.blocks[bi].instructions.len}
		for ii in 0 .. function.blocks[bi].instructions.len {
			if dead[bi][ii] {
				continue
			}
			landed[bi][ii] = instructions.len
			instructions << function.blocks[bi].instructions[ii]
		}
		function.blocks[bi].instructions = instructions
	}

	// Renumber every site.
	for bi in 0 .. function.blocks.len {
		for pi in 0 .. function.blocks[bi].params.len {
			function.blocks[bi].params[pi] = renumber(remap, function.blocks[bi].params[pi],
				function.name, 'a block parameter')
		}
		for ii in 0 .. function.blocks[bi].instructions.len {
			mut inst := function.blocks[bi].instructions[ii]
			renumber_sites(mut inst, remap, function.name)
			function.blocks[bi].instructions[ii] = inst
		}
		mut terminator := function.blocks[bi].terminator
		renumber_sites(mut terminator, remap, function.name)
		function.blocks[bi].terminator = terminator
	}

	mut values := []ir.Value{cap: kept}
	for i, value in function.values {
		if remap[i] >= 0 {
			values << value
		}
	}
	for bi in 0 .. function.blocks.len {
		for ii in 0 .. function.blocks[bi].instructions.len {
			for result in function.blocks[bi].instructions[ii].results {
				values[result].block = bi
				values[result].inst = ii
			}
		}
	}
	function.values = values
	return true
}

fn renumber_sites(mut inst ir.Instruction, remap []int, name string) {
	for i in 0 .. inst.results.len {
		inst.results[i] = renumber(remap, inst.results[i], name, 'a result')
	}
	renumber_operands(mut inst.operands, remap, name)
	mut target := inst.target
	renumber_operands(mut target.args, remap, name)
	inst.target = target
	mut else_target := inst.else_target
	renumber_operands(mut else_target.args, remap, name)
	inst.else_target = else_target
	for ci in 0 .. inst.cases.len {
		mut case_target := inst.cases[ci].target
		renumber_operands(mut case_target.args, remap, name)
		inst.cases[ci].target = case_target
	}
	for ai in 0 .. inst.asm.inputs.len {
		mut input := inst.asm.inputs[ai]
		renumber_operand(mut input.value, remap, name)
		inst.asm.inputs[ai] = input
	}
}

fn renumber_operands(mut operands []ir.Operand, remap []int, name string) {
	for i in 0 .. operands.len {
		renumber_operand(mut operands[i], remap, name)
	}
}

fn renumber_operand(mut operand ir.Operand, remap []int, name string) {
	if operand.kind != .value {
		return
	}
	operand.idx = renumber(remap, operand.idx, name, 'an operand')
}

fn renumber(remap []int, index int, name string, site string) int {
	if index < 0 || index >= remap.len {
		panic('erase_instructions: @${name} has ${site} naming value ${index}, and the table holds ${remap.len}')
	}
	if remap[index] < 0 {
		panic('erase_instructions: @${name} still names value ${index}, which was erased')
	}
	return remap[index]
}
