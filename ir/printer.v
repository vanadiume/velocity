module ir

import os
import strings

// The canonical text form in ir-text.md, written from the model. The parser
// reads the text and the printer writes it, and the pair is what makes the
// round trip checkable: a module printed and read again is the same module,
// and a canonical file printed out of the parser is the same bytes.
//
// Every value, block and stack slot is renamed as the text mentions it, so two
// modules that differ only in those names print the same bytes. A module keeps
// its globals and its functions in two lists, so the text writes the globals
// first and the functions after them; a file may declare them in any order.

pub fn print_module(m &Module) string {
	mut declarations := []string{cap: 1 + m.globals.len + m.functions.len}
	declarations << 'target ${m.target.pointer_width} ${endian_text(m.target.endian)} ${m.target.pointer_align}'
	for global in m.globals {
		declarations << print_global(global)
	}
	for function in m.functions {
		declarations << print_function(m, function)
	}
	return declarations.join('\n\n') + '\n'
}

// print_file writes the canonical text to a path.
pub fn print_file(m &Module, path string) ! {
	os.write_file(path, print_module(m))!
}

fn endian_text(endian Endian) string {
	return if endian == .big { 'big' } else { 'little' }
}

fn print_global(global &Global) string {
	mut out := strings.new_builder(64)
	if global.public {
		out.write_string('pub ')
	}
	out.write_string('global @${global.name}: ${global.typ.str()}')
	if global.readonly {
		out.write_string(' readonly')
	}
	if init := global.init {
		out.write_string(' = ${const_text(init, global.typ)}')
	}
	return out.str()
}

// const_text writes a global's initializer with the type that gives each leaf
// its width and its bracket. zeroinit prints as itself and never expands, which
// is what keeps a 4096-byte zero-filled tree out of the text.
fn const_text(value Const, typ Type) string {
	match value.kind {
		.zero {
			return 'zeroinit'
		}
		.null {
			return 'null'
		}
		.int {
			bits := if typ.is_int() { typ.bits } else { u16(128) }
			return '${mask_to(bits, value.bits)}'
		}
		.float {
			return '${value.typ.str()} 0x${bit_pattern(value.bits, value.typ)}'
		}
		.seq {
			object := typ.is_struct()
			mut out := strings.new_builder(32)
			out.write_string(if object { '{' } else { '[' })
			for i, elem in value.elems {
				if i > 0 {
					out.write_string(', ')
				}
				elem_type := if object {
					typ.field(i)
				} else {
					typ.elem()
				}
				out.write_string(const_text(elem, elem_type))
			}
			out.write_string(if object { '}' } else { ']' })
			return out.str()
		}
	}
}

// Printer holds the state one function needs: the name each value printed
// under, and the next number to hand out.
struct Printer {
mut:
	out   strings.Builder
	names map[int]string
	next  int
}

fn print_function(m &Module, function &Function) string {
	mut printer := Printer{
		out:   strings.new_builder(512)
		names: map[int]string{}
	}
	printer.out.write_string(header_text(function))
	if !function.defined {
		return printer.out.str()
	}
	printer.out.writeln(' {')
	for i, slot in function.stack_slots {
		printer.out.writeln('stack slot${i}: ${slot.size} bytes align ${slot.align}')
	}
	// Function parameters are named before the walk, so a use in the entry
	// block finds them and the count starts at the first value the text defines.
	for i in 0 .. function.signature.params.len {
		printer.names[i] = '%arg${i}'
	}
	for index, block in function.blocks {
		printer.print_block(m, function, index, block)
	}
	printer.out.write_string('}')
	return printer.out.str()
}

fn header_text(function &Function) string {
	mut out := strings.new_builder(64)
	if !function.defined {
		out.write_string('extern ')
	} else if function.public {
		out.write_string('pub ')
	}
	out.write_string('fn @${function.name}(')
	for i, param in function.signature.params {
		if i > 0 {
			out.write_string(', ')
		}
		out.write_string('%arg${i}: ${param.str()}')
	}
	out.write_string(')')
	out.write_string(result_suffix(function.signature.results))
	return out.str()
}

// result_suffix is what follows the parameter list: nothing, one type, or a
// parenthesized list of them.
fn result_suffix(results []Type) string {
	if results.len == 0 {
		return ''
	}
	if results.len == 1 {
		return ' -> ${results[0].str()}'
	}
	mut out := strings.new_builder(16)
	out.write_string(' -> (')
	for i, result in results {
		if i > 0 {
			out.write_string(', ')
		}
		out.write_string(result.str())
	}
	out.write_string(')')
	return out.str()
}

fn signature_form(signature &Signature) string {
	mut out := strings.new_builder(32)
	out.write_string('(')
	for i, param in signature.params {
		if i > 0 {
			out.write_string(', ')
		}
		out.write_string(param.str())
	}
	out.write_string(')')
	out.write_string(result_suffix(signature.results))
	return out.str()
}

fn (mut p Printer) print_block(m &Module, function &Function, index int, block &Block) {
	p.out.write_string('block${index}')
	if block.params.len > 0 {
		p.out.write_string('(')
		for i, value in block.params {
			if i > 0 {
				p.out.write_string(', ')
			}
			name := p.name_for(function, value)
			p.out.write_string('${name}: ${function.values[value].typ.str()}')
		}
		p.out.write_string(')')
	}
	p.out.writeln(':')
	for instruction in block.instructions {
		line := p.instruction_text(m, function, instruction)
		p.out.writeln('  ${line}')
	}
	terminator := p.instruction_text(m, function, block.terminator)
	p.out.writeln('  ${terminator}')
}

fn (mut p Printer) instruction_text(m &Module, function &Function, inst &Instruction) string {
	mut line := strings.new_builder(96)
	if inst.results.len > 0 {
		for i, value in inst.results {
			if i > 0 {
				line.write_string(', ')
			}
			line.write_string(p.name_for(function, value))
		}
		line.write_string(' = ')
	}
	line.write_string(inst.opcode.name())
	for flag in flags_text(inst) {
		line.write_string(' ${flag}')
	}
	operands := p.operands_text(m, function, inst)
	if operands != '' {
		line.write_string(' ${operands}')
	}
	if loc := inst.loc {
		line.write_string(' @loc(${quote_text(loc.file)}, ${loc.line}, ${loc.col})')
	}
	return line.str()
}

// flags_text is the flags in the canonical order. The volatile flag is an
// inline asm clause rather than a flag, so it is written there and not here.
fn flags_text(inst &Instruction) []string {
	mut written := []string{cap: 5}
	if inst.flags.nsw {
		written << 'nsw'
	}
	if inst.flags.nuw {
		written << 'nuw'
	}
	if inst.flags.exact {
		written << 'exact'
	}
	if inst.flags.inbounds {
		written << 'inbounds'
	}
	if inst.flags.volatile && inst.opcode != .inline_asm {
		written << 'volatile'
	}
	return written
}

// name_for is the name a value prints under. A definition is named in the order
// it is written, which is the numbering ir-text.md states; a use of a value no
// earlier line defined gets its number at the use, which keeps a module the
// verifier refuses printable rather than a printer that panics on it.
fn (mut p Printer) name_for(function &Function, index int) string {
	if index < 0 || index >= function.values.len {
		panic("printer: '@${function.name}' names value ${index}, and its value table holds ${function.values.len}")
	}
	if name := p.names[index] {
		return name
	}
	name := '%v${p.next}'
	p.next++
	p.names[index] = name
	return name
}

fn (mut p Printer) operand_text(function &Function, operand &Operand) string {
	match operand.kind {
		.value {
			return p.name_for(function, operand.idx)
		}
		.int_imm {
			return '${operand.imm}'
		}
		.float_imm {
			return '${operand.typ.str()} 0x${bit_pattern(operand.imm, operand.typ)}'
		}
		.symbol {
			return '@${operand.name}'
		}
		.stack_slot {
			return p.slot_text(function, operand.idx)
		}
	}
}

fn (mut p Printer) slot_text(function &Function, index int) string {
	if index < 0 || index >= function.stack_slots.len {
		panic("printer: '@${function.name}' names stack slot ${index}, and it declares ${function.stack_slots.len}")
	}
	return 'slot${index}'
}

fn (mut p Printer) at(function &Function, inst &Instruction, index int) string {
	if index < 0 || index >= inst.operands.len {
		panic("printer: '@${function.name}' has '${inst.opcode.name()}' with ${inst.operands.len} operands, so operand ${index + 1} is not one")
	}
	return p.operand_text(function, inst.operands[index])
}

// join is the operand list from `start` on, comma separated. It is what a call's
// arguments and a return's values print as.
fn (mut p Printer) join(function &Function, operands []Operand, start int) string {
	mut out := strings.new_builder(32)
	for i in start .. operands.len {
		if i > start {
			out.write_string(', ')
		}
		out.write_string(p.operand_text(function, operands[i]))
	}
	return out.str()
}

fn (mut p Printer) target_text(function &Function, target &BlockTarget) string {
	if target.block < 0 || target.block >= function.blocks.len {
		panic("printer: '@${function.name}' jumps to block ${target.block}, and the function has ${function.blocks.len}")
	}
	mut out := strings.new_builder(16)
	out.write_string('block${target.block}(')
	for i, arg in target.args {
		if i > 0 {
			out.write_string(', ')
		}
		out.write_string(p.operand_text(function, arg))
	}
	out.write_string(')')
	return out.str()
}

// fixed_operand_count is the number of operands the text form gives an opcode,
// and -1 where the instruction decides: a return's values, a call's arguments,
// an inline asm's clauses.
fn fixed_operand_count(op Opcode) int {
	return match op {
		.null, .poison, .br, .unreachable, .trap, .inline_asm {
			0
		}
		.iconst, .fconst, .ineg, .iabs, .bnot, .clz, .ctz, .popcnt, .bswap, .freeze,
		.fneg, .fabs, .fsqrt, .fceil, .ffloor, .ftrunc, .fnearest, .sext, .zext, .trunc,
		.bitcast, .ptrtoint, .inttoptr, .sitofp, .uitofp, .fptosi, .fptoui, .fpext,
		.fptrunc, .load, .stack_addr, .global_addr, .func_addr, .condbr, .switch, .assume {
			1
		}
		.fma, .@select, .memcpy, .memmove, .memset {
			3
		}
		.@return, .call, .call_indirect, .tailcall, .tailcall_indirect {
			-1
		}
		else {
			2
		}
	}
}

fn (mut p Printer) operands_text(m &Module, function &Function, inst &Instruction) string {
	op := inst.opcode
	count := fixed_operand_count(op)
	if count >= 0 && inst.operands.len != count {
		panic("printer: '@${function.name}' has '${op.name()}' with ${inst.operands.len} operands, and the text form gives it ${count}")
	}
	match op {
		.iconst {
			// An iconst names its type, so its immediate is the low N bits of
			// the value it holds and prints in that width.
			return '${inst.typ.str()} ${mask_int(inst.operands[0].imm, inst.typ)}'
		}
		.fconst {
			return '${inst.typ.str()} 0x${bit_pattern(inst.operands[0].imm, inst.typ)}'
		}
		.poison {
			return inst.typ.str()
		}
		.null, .unreachable {
			return ''
		}
		.iadd, .isub, .imul, .sdiv, .udiv, .srem, .urem, .smin, .smax, .umin, .umax,
		.sadd_overflow, .uadd_overflow, .ssub_overflow, .usub_overflow, .smul_overflow,
		.umul_overflow, .sadd_sat, .uadd_sat, .ssub_sat, .usub_sat, .smul_sat, .umul_sat,
		.band, .bor, .bxor, .shl, .sshr, .ushr, .rotl, .rotr, .fadd, .fsub, .fmul, .fdiv,
		.frem, .fcopysign, .fmin, .fmax, .ptradd {
			return '${p.at(function, inst, 0)}, ${p.at(function, inst, 1)}'
		}
		.fma, .@select {
			return '${p.at(function, inst, 0)}, ${p.at(function, inst, 1)}, ${p.at(function, inst, 2)}'
		}
		.ineg, .iabs, .bnot, .clz, .ctz, .popcnt, .bswap, .freeze, .fneg, .fabs, .fsqrt,
		.fceil, .ffloor, .ftrunc, .fnearest, .assume {
			return p.at(function, inst, 0)
		}
		.icmp, .fcmp {
			return '${inst.predicate} ${p.at(function, inst, 0)}, ${p.at(function, inst, 1)}'
		}
		.sext, .zext, .trunc, .bitcast, .sitofp, .uitofp, .fptosi, .fptoui, .fpext,
		.fptrunc {
			return '${p.at(function, inst, 0)} to ${inst.typ.str()}'
		}
		.ptrtoint {
			return '${p.at(function, inst, 0)}${conversion_to_text(inst.typ, int_type(m.target.pointer_width))}'
		}
		.inttoptr {
			return '${p.at(function, inst, 0)}${conversion_to_text(inst.typ, ty_ptr)}'
		}
		.load {
			return '${p.at(function, inst, 0)} : ${inst.typ.str()} align ${inst.align}'
		}
		.store {
			return '${p.at(function, inst, 0)}, ${p.at(function, inst, 1)} align ${inst.align}'
		}
		.memcpy, .memmove {
			return '${p.at(function, inst, 0)}, ${p.at(function, inst, 1)}, ${p.at(function, inst, 2)} align dst ${inst.align_dst} align src ${inst.align_src}'
		}
		.memset {
			return '${p.at(function, inst, 0)}, ${p.at(function, inst, 1)}, ${p.at(function, inst, 2)} align ${inst.align}'
		}
		.stack_addr {
			return p.operand_text(function, inst.operands[0])
		}
		.global_addr, .func_addr {
			return p.operand_text(function, inst.operands[0])
		}
		.call, .tailcall {
			return '${p.operand_text(function, inst.operands[0])}(${p.join(function, inst.operands, 1)})'
		}
		.call_indirect, .tailcall_indirect {
			return '${p.at(function, inst, 0)} : ${signature_form(inst.signature)} (${p.join(function, inst.operands, 1)})'
		}
		.br {
			return p.target_text(function, inst.target)
		}
		.condbr {
			return '${p.at(function, inst, 0)}, ${p.target_text(function, inst.target)}, ${p.target_text(function, inst.else_target)}'
		}
		.switch {
			mut out := strings.new_builder(48)
			out.write_string('${p.at(function, inst, 0)}, ${p.target_text(function, inst.target)}')
			for case_ in inst.cases {
				out.write_string(', ${case_.value}: ${p.target_text(function, case_.target)}')
			}
			return out.str()
		}
		.@return {
			return p.join(function, inst.operands, 0)
		}
		.trap {
			return '${inst.trap_code}'
		}
		.inline_asm {
			return p.asm_text(function, inst)
		}
	}
}

// conversion_to_text writes `to T`, except where T is the type the text form
// defaults to: the pointer-width integer for ptrtoint, and ptr for inttoptr.
fn conversion_to_text(typ Type, default Type) string {
	if typ == default {
		return ''
	}
	return ' to ${typ.str()}'
}

fn (mut p Printer) asm_text(function &Function, inst &Instruction) string {
	mut out := strings.new_builder(96)
	out.write_string(quote_text(inst.asm.template))
	for output in inst.asm.outputs {
		out.write_string(' out(${output.typ.str()}, ${quote_text(output.constraint)})')
	}
	for input in inst.asm.inputs {
		out.write_string(' in(${p.operand_text(function, input.value)}, ${quote_text(input.constraint)})')
	}
	for clobber in inst.asm.clobbers {
		out.write_string(' clobber(${quote_text(clobber)})')
	}
	if inst.asm.volatile || inst.flags.volatile {
		out.write_string(' volatile')
	}
	if inst.asm.alignstack {
		out.write_string(' alignstack')
	}
	if inst.asm.intel {
		out.write_string(' intel')
	}
	return out.str()
}

// bit_pattern is the hex spelling of a float immediate: the low bits its type
// holds, zero padded to the width, so an f32 is eight digits and an f64 sixteen.
fn bit_pattern(bits u128, typ Type) string {
	value := mask_to(typ.bits, bits)
	text := value.hex()
	digits := int(typ.bits) / 4
	if text.len >= digits {
		return text
	}
	return strings.repeat_string('0', digits - text.len) + text
}

// quote_text writes a string with the escapes ir-text.md defines and no others,
// so a template, a constraint or a file name reads back byte for byte.
fn quote_text(text string) string {
	mut out := strings.new_builder(text.len + 2)
	out.write_u8(`"`)
	for byte in text {
		match byte {
			`\\` {
				out.write_string('\\\\')
			}
			`"` {
				out.write_string('\\"')
			}
			`\n` {
				out.write_string('\\n')
			}
			`\t` {
				out.write_string('\\t')
			}
			0 {
				out.write_string('\\0')
			}
			else {
				if byte >= 0x20 && byte < 0x7f {
					out.write_u8(byte)
				} else {
					out.write_string('\\x${byte:02x}')
				}
			}
		}
	}
	out.write_u8(`"`)
	return out.str()
}
