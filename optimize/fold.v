module optimize

import vanadiume.velocity.ir

// Constant folding. An instruction whose operands are all constants becomes the
// iconst that holds its result, in place, so the value keeps its index and every
// use keeps naming it.
//
// The result is not written into the use sites as an immediate: an integer
// immediate has no type of its own, and ir/verify.v takes one from the operand
// beside it or from the type the site states. The IR's answer for a constant
// that has to be a value is iconst, so that is what a fold produces, and dead
// code elimination removes the ones nothing reads.

pub fn constant_fold() Pass {
	return Pass{
		name: 'constant_fold'
		run:  fold_function
	}
}

fn fold_function(mut function ir.Function) bool {
	mut changed := false
	for fold_sweep(mut function) {
		changed = true
	}
	return changed
}

// fold_sweep folds everything it can in one walk. Sweeps repeat until one
// changes nothing, because block order is not dominance order: a value defined
// in a block listed after its user is valid IR, so one walk cannot promise to
// reach every chain.
fn fold_sweep(mut function ir.Function) bool {
	// Every iconst is a constant at the start of a sweep, and a folded result
	// joins them as the sweep writes it. Recording them first is what keeps a
	// chain inside one block to one sweep.
	mut known := map[int]ir.Operand{}
	for block in function.blocks {
		for inst in block.instructions {
			if inst.opcode == .iconst && inst.results.len == 1 && inst.operands.len == 1 {
				known[inst.results[0]] = int_operand(inst.operands[0].imm)
			}
		}
	}
	mut changed := false
	for bi in 0 .. function.blocks.len {
		for ii in 0 .. function.blocks[bi].instructions.len {
			inst := function.blocks[bi].instructions[ii]
			if inst.results.len != 1 {
				continue
			}
			result := inst.results[0]
			if result < 0 || result >= function.values.len {
				continue
			}
			typ := function.values[result].typ
			if !typ.is_int() {
				continue
			}
			if inst.opcode == .select {
				replacement := select_result(inst, known) or { continue }
				if replacement.kind == .value {
					// The chosen arm dominates the select, so it dominates every
					// use of the select's result. The select is left dead for
					// elimination.
					if replace_uses(mut function, result, replacement) > 0 {
						changed = true
					}
					continue
				}
				function.blocks[bi].instructions[ii] = constant_instruction(typ,
					replacement.imm, inst)
				known[result] = int_operand(truncate(replacement.imm, typ.bits))
				changed = true
				continue
			}
			bits := folded_bits(function, inst, known) or { continue }
			function.blocks[bi].instructions[ii] = constant_instruction(typ, bits, inst)
			known[result] = int_operand(truncate(bits, typ.bits))
			changed = true
		}
	}
	return changed
}

// folded_bits answers what the instruction computes when every operand is a
// constant, or none when the opcode is outside the fold set or a flag it
// carries would be broken by folding.
fn folded_bits(function &ir.Function, inst ir.Instruction, known map[int]ir.Operand) ?u128 {
	mut operands := []u128{cap: inst.operands.len}
	for operand in inst.operands {
		value := constant_of(operand, known) or { return none }
		operands << value
	}
	match inst.opcode {
		.freeze {
			if operands.len != 1 {
				return none
			}
			return operands[0]
		}
		.iadd, .isub, .imul {
			width := operand_width(function, inst) or { return none }
			return folded_arithmetic(inst, operands, width)
		}
		.band, .bor, .bxor {
			width := operand_width(function, inst) or { return none }
			return folded_bitwise(inst, operands, width)
		}
		.bnot {
			width := operand_width(function, inst) or { return none }
			if operands.len != 1 {
				return none
			}
			return ~truncate(operands[0], width) & mask_width(width)
		}
		.shl, .sshr, .ushr, .rotl, .rotr {
			width := operand_width(function, inst) or { return none }
			return folded_shift(inst, operands, width)
		}
		.clz, .ctz, .popcnt {
			width := operand_width(function, inst) or { return none }
			return folded_count(inst, operands, width)
		}
		.bswap {
			width := operand_width(function, inst) or { return none }
			return folded_bswap(operands, width)
		}
		.icmp {
			width := operand_width(function, inst) or { return none }
			return folded_compare(inst, operands, width)
		}
		.sext, .zext, .trunc, .bitcast {
			return folded_conversion(function, inst, operands)
		}
		else {
			return none
		}
	}
	return none
}

fn folded_arithmetic(inst ir.Instruction, operands []u128, width u16) ?u128 {
	if operands.len != 2 {
		return none
	}
	a := truncate(operands[0], width)
	b := truncate(operands[1], width)
	if inst.opcode == .imul && width > 64 {
		// The wrapped product needs twice the width, and the implementation's
		// widest integer is 128 bits, so an imul wider than 64 bits is left for a
		// stage that can do the multiplication.
		return none
	}
	result := match inst.opcode {
		.iadd { truncate(wrap_add(a, b), width) }
		.isub { truncate(wrap_sub(a, b), width) }
		.imul { truncate(a * b, width) }
		else { return none }
	}
	if inst.flags.nuw {
		product := a * b
		holds := match inst.opcode {
			.iadd { result >= a }
			.isub { a >= b }
			.imul { product == result }
			else { false }
		}
		if !holds {
			return none
		}
	}
	if inst.flags.nsw {
		holds := match inst.opcode {
			.iadd {
				!(sign_bit(a, width) == sign_bit(b, width) && sign_bit(result, width) != sign_bit(a, width))
			}
			.isub {
				!(sign_bit(a, width) != sign_bit(b, width) && sign_bit(result, width) != sign_bit(a, width))
			}
			.imul { product_fits_signed(a, b, width) }
			else { false }
		}
		if !holds {
			return none
		}
	}
	return result
}

fn folded_bitwise(inst ir.Instruction, operands []u128, width u16) ?u128 {
	if operands.len != 2 {
		return none
	}
	a := truncate(operands[0], width)
	b := truncate(operands[1], width)
	return match inst.opcode {
		.band { a & b }
		.bor { a | b }
		.bxor { a ^ b }
		else { return none }
	}
}

fn folded_shift(inst ir.Instruction, operands []u128, width u16) ?u128 {
	if operands.len != 2 {
		return none
	}
	a := truncate(operands[0], width)
	amount := operands[1]
	if inst.opcode == .rotl || inst.opcode == .rotr {
		rotate := u16(amount % u128(width))
		if rotate == 0 {
			return a
		}
		if inst.opcode == .rotl {
			return truncate((a << rotate) | (a >> (width - rotate)), width)
		}
		return truncate((a >> rotate) | (a << (width - rotate)), width)
	}
	if amount >= u128(width) {
		// A shift amount at or above the width is poison.
		return none
	}
	shift := u16(amount)
	if inst.opcode == .shl {
		if shift == 0 {
			return a
		}
		if inst.flags.nuw && (a >> (width - shift)) != 0 {
			return none
		}
		if inst.flags.nsw {
			top := a >> (width - shift)
			wanted := if (a >> (width - shift - 1)) & 1 == 1 {
				mask_width(shift)
			} else {
				u128(0)
			}
			if top != wanted {
				return none
			}
		}
		return truncate(a << shift, width)
	}
	// "No bits shifted out" is read as the discarded bits being zero, for the
	// signed shift as well as the unsigned one.
	if inst.flags.exact && truncate(a, shift) != 0 {
		return none
	}
	if inst.opcode == .ushr {
		return truncate(a >> shift, width)
	}
	return truncate(sign_extend(a, width) >> shift, width)
}

fn folded_count(inst ir.Instruction, operands []u128, width u16) ?u128 {
	if operands.len != 1 {
		return none
	}
	a := truncate(operands[0], width)
	mut count := 0
	if inst.opcode == .clz {
		for i := int(width) - 1; i >= 0; i-- {
			if (a >> u32(i)) & 1 == 1 {
				break
			}
			count++
		}
	} else if inst.opcode == .ctz {
		for i := 0; i < int(width); i++ {
			if (a >> u32(i)) & 1 == 1 {
				break
			}
			count++
		}
	} else {
		for i := 0; i < int(width); i++ {
			if (a >> u32(i)) & 1 == 1 {
				count++
			}
		}
	}
	return u128(count)
}

fn folded_bswap(operands []u128, width u16) ?u128 {
	if operands.len != 1 || width % 8 != 0 {
		return none
	}
	value := truncate(operands[0], width)
	bytes := int(width) / 8
	mut result := u128(0)
	for i in 0 .. bytes {
		byte := (value >> u32(i * 8)) & 0xff
		result |= byte << u32((bytes - 1 - i) * 8)
	}
	return result
}

fn folded_compare(inst ir.Instruction, operands []u128, width u16) ?u128 {
	if operands.len != 2 {
		return none
	}
	a := truncate(operands[0], width)
	b := truncate(operands[1], width)
	result := match inst.predicate {
		'eq' { a == b }
		'ne' { a != b }
		'ult' { a < b }
		'ule' { a <= b }
		'ugt' { a > b }
		'uge' { a >= b }
		'slt' { signed_less(a, b, width) }
		'sle' { !signed_less(b, a, width) }
		'sgt' { signed_less(b, a, width) }
		'sge' { !signed_less(a, b, width) }
		else { return none }
	}
	return if result { u128(1) } else { u128(0) }
}

fn folded_conversion(function &ir.Function, inst ir.Instruction, operands []u128) ?u128 {
	if operands.len != 1 || !inst.typ.is_int() {
		return none
	}
	if inst.operands[0].kind != .value {
		return none
	}
	source := function.values[inst.operands[0].idx].typ
	if !source.is_int() {
		return none
	}
	target := inst.typ.bits
	if inst.opcode == .sext {
		return truncate(sign_extend(operands[0], source.bits), target)
	}
	if inst.opcode == .bitcast && source.bits != target {
		return none
	}
	return truncate(operands[0], target)
}

// select_result is the arm a constant condition chooses. A value arm replaces
// the uses; a constant arm becomes the select's own constant.
fn select_result(inst ir.Instruction, known map[int]ir.Operand) ?ir.Operand {
	if inst.operands.len != 3 {
		return none
	}
	condition := constant_of(inst.operands[0], known) or { return none }
	if condition != 0 && condition != 1 {
		return none
	}
	chosen := if condition == 1 { inst.operands[1] } else { inst.operands[2] }
	if chosen.kind == .value || chosen.kind == .int_imm {
		return chosen
	}
	return none
}

fn constant_of(operand ir.Operand, known map[int]ir.Operand) ?u128 {
	if operand.kind == .int_imm {
		return operand.imm
	}
	if operand.kind == .value {
		stored := known[operand.idx] or { return none }
		return stored.imm
	}
	return none
}

// operand_width is the width the opcode's operands share. An immediate has no
// type, so the width comes from the value beside it.
fn operand_width(function &ir.Function, inst ir.Instruction) ?u16 {
	for operand in inst.operands {
		if operand.kind != .value || operand.idx < 0 || operand.idx >= function.values.len {
			continue
		}
		typ := function.values[operand.idx].typ
		if typ.is_int() {
			return typ.bits
		}
	}
	return none
}

fn constant_instruction(typ ir.Type, bits u128, old ir.Instruction) ir.Instruction {
	mut operands := []ir.Operand{cap: 1}
	operands << int_operand(truncate(bits, typ.bits))
	return ir.Instruction{
		opcode:   .iconst
		operands: operands
		results:  old.results
		typ:      typ
		loc:      old.loc
	}
}

fn int_operand(imm u128) ir.Operand {
	return ir.Operand{
		kind: .int_imm
		idx:  -1
		imm:  imm
	}
}

fn mask_width(width u16) u128 {
	if width >= 128 {
		return ~u128(0)
	}
	return (u128(1) << u32(width)) - 1
}

fn truncate(value u128, width u16) u128 {
	if width >= 128 {
		return value
	}
	return value & mask_width(width)
}

// wrap_add and wrap_sub are addition and subtraction modulo 2^128. V checks
// integer overflow, so the carry and the borrow are answered from a comparison
// instead of from the result.
fn wrap_add(a u128, b u128) u128 {
	top := ~u128(0)
	if a > top - b {
		return a - (top - b) - 1
	}
	return a + b
}

fn wrap_sub(a u128, b u128) u128 {
	if a < b {
		return a + (~u128(0) - b) + 1
	}
	return a - b
}

fn sign_extend(value u128, width u16) u128 {
	if width >= 128 {
		return value
	}
	low := truncate(value, width)
	if sign_bit(low, width) {
		return low | ~mask_width(width)
	}
	return low
}

fn sign_bit(value u128, width u16) bool {
	if width == 0 {
		return false
	}
	return (value >> u32(width - 1)) & 1 == 1
}

fn signed_less(a u128, b u128, width u16) bool {
	a_negative := sign_bit(a, width)
	b_negative := sign_bit(b, width)
	if a_negative != b_negative {
		return a_negative
	}
	return a < b
}

fn product_fits_signed(a u128, b u128, width u16) bool {
	left := i128(sign_extend(a, width))
	right := i128(sign_extend(b, width))
	product := left * right
	limit := i128(1) << u32(width - 1)
	return product >= -limit && product < limit
}
