module ir

import os

// The printer's contract: a canonical file prints back byte for byte, a file
// that parses prints text that parses to the same module, and what the builder
// assembles prints into text the parser and the verifier both accept.
//
// V compiles each test file beside the module on its own, so the helpers here
// are local rather than shared with the other suites.

fn printer_fixture(name string) string {
	path := os.join_path(@DIR, 'testdata', name)
	return os.read_file(path) or { panic('cannot read ${path}: ${err}') }
}

fn printer_canonical() Module {
	return parse_text(printer_fixture('canonical.vel')) or { panic('${err.msg()}') }
}

fn printer_target() TargetInfo {
	return TargetInfo{
		pointer_width: 64
		pointer_align: 8
		endian:        .little
	}
}

fn test_the_canonical_file_prints_back_byte_for_byte() {
	expected := printer_fixture('canonical.vel')
	printed := print_module(printer_canonical())
	assert printed == expected, 'the printer disagrees with the canonical file:\n${printed}'
}

// The other fixtures are input rather than the canonical form, so their bytes
// may change; what may not change is the text once it has been printed once.
fn test_every_fixture_prints_to_text_that_prints_the_same_again() {
	for name in ['canonical.vel', 'opcodes.vel', 'verify_accepted.vel'] {
		first := print_module(parse_text(printer_fixture(name)) or { panic('${name}: ${err.msg()}') })
		second := print_module(parse_text(first) or { panic('${name}: ${err.msg()}') })
		assert first == second, '${name} does not print stably'
	}
}

// build_print_module is a module the way a front end assembles one: block
// parameters the builder creates when it seals a join, a loop header that takes
// the counter back, a stack slot with no name, and instructions whose operands
// carry an index and no name at all.
fn build_print_module() Module {
	mut module := Module{
		target: printer_target()
	}
	callee := signature([param(ty_i32, false)], [result(ty_i32, false)])

	mut count := new_function('count', [ty_i32], [ty_i32])
	mut cb := new_builder(mut count, printer_target())
	entry := cb.create_entry_block()
	cb.switch_to_block(entry)
	limit := cb.param(0)
	i := cb.declare_var(ty_i32)
	cb.def_var(i, cb.iconst(ty_i32, 0))
	loop := cb.loop_()
	step := cb.iadd(cb.use_var(i), cb.iconst(ty_i32, 1))
	cb.def_var(i, step)
	done := cb.icmp(.sge, cb.use_var(i), limit)
	leave := cb.create_block()
	again := cb.create_block()
	cb.condbr(done, leave, [], again, [])
	cb.switch_to_block(leave)
	cb.loop_break(loop)
	cb.switch_to_block(again)
	cb.loop_continue(loop)
	cb.switch_to_block(loop.after)
	cb.return_([cb.use_var(i)])
	cb.seal_all()
	cb.finish()
	module.functions << count

	mut work := new_function('work', [ty_ptr, ty_ptr, ty_i32], [ty_i32])
	mut wb := new_builder(mut work, printer_target())
	work_entry := wb.create_entry_block()
	wb.switch_to_block(work_entry)
	dst := wb.param(0)
	src := wb.param(1)
	n := wb.param(2)
	slot := wb.create_stack_slot(8, 8, none)
	wb.memset(dst, wb.iconst(ty_i8, 0), n, 4)
	wb.memcpy(dst, src, n, 4, 4)
	loaded := wb.load_aligned(src, ty_i32, 4)
	wb.store_aligned(dst, loaded, 4)
	address := wb.stack_addr(slot)
	wb.store_aligned(address, loaded, 4)
	pointer := wb.inttoptr(wb.ptrtoint(address, ty_i64), ty_ptr)
	wb.global_addr('data')
	wb.func_addr('callee')
	forwarded := wb.call('callee', callee, [loaded])
	indirect := wb.call_indirect(pointer, callee, [forwarded[0]])
	assembled := wb.inline_asm(Asm{
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
		clobbers: ['cc']
		volatile: true
	})
	wb.ptradd(dst, wb.iconst(ty_i64, 4))
	wb.return_([assembled[0]])
	wb.finish()
	module.functions << work

	mut last := new_function('last', [ty_i32], [ty_i32])
	mut lb := new_builder(mut last, printer_target())
	last_entry := lb.create_entry_block()
	lb.switch_to_block(last_entry)
	lb.tailcall('callee', callee, [lb.param(0)])
	lb.finish()
	module.functions << last

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

// The round trip the release is measured by: a module the builder assembles,
// printed, read again, and handed to the verifier, which accepts it.
fn test_a_module_the_builder_assembles_prints_into_one_the_verifier_accepts() {
	built := build_print_module()
	text := print_module(built)
	parsed := parse_text(text) or { panic('the printer wrote text that does not parse:\n${text}\n${err.msg()}') }
	assert parsed.functions.len == built.functions.len
	assert parsed.globals.len == built.globals.len
	errors := verify_module(&parsed)
	assert errors.len == 0, '${errors.map(it.msg()).join(', ')}\n${text}'
	assert print_module(parsed) == text, 'printing the parsed module changed the text:\n${print_module(parsed)}'
}

fn test_a_function_the_builder_assembles_prints_what_a_person_would_write() {
	mut function := new_function('max', [ty_i32, ty_i32], [ty_i32])
	mut builder := new_builder(mut function, printer_target())
	entry := builder.create_entry_block()
	builder.switch_to_block(entry)
	first := builder.param(0)
	second := builder.param(1)
	condition := builder.icmp(.sgt, first, second)
	chosen := builder.select(condition, first, second)
	builder.return_([chosen])
	builder.finish()

	module := Module{
		target:    printer_target()
		functions: [function]
	}
	expected := 'target 64 little 8

fn @max(%arg0: i32, %arg1: i32) -> i32 {
block0:
  %v0 = icmp sgt %arg0, %arg1
  %v1 = select %v0, %arg0, %arg1
  return %v1
}
'
	assert print_module(module) == expected
}

fn test_a_join_prints_its_parameter_and_both_jumps_pass_their_value() {
	mut function := new_function('branchy', [ty_i1], [ty_i32])
	mut builder := new_builder(mut function, printer_target())
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
	builder.return_([builder.use_var(x)])
	builder.finish()

	module := Module{
		target:    printer_target()
		functions: [function]
	}
	expected := 'target 64 little 8

fn @branchy(%arg0: i1) -> i32 {
block0:
  %v0 = iconst i32 0
  condbr %arg0, block1(), block2()
block1:
  %v1 = iconst i32 1
  br block3(%v1)
block2:
  %v2 = iconst i32 2
  br block3(%v2)
block3(%v3: i32):
  return %v3
}
'
	assert print_module(module) == expected
}

// Names are not semantic, so the printer renumbers: the two values a file calls
// %n and %w are %arg0 and %v0 in the text it prints, and the block labels and
// the stack slot are numbered by position.
fn test_values_blocks_and_stack_slots_are_renumbered() {
	text := 'target 64 little 8
fn @f(%n: i32) -> i32 {
stack slot7: 8 bytes align 8
prologue:
  br body(%n)
body(%w: i32):
  %sum = iadd %n, %w
  %where = stack_addr slot7
  store %where, %sum align 4
  %back = load %where : i32 align 4
  return %back
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	expected := 'target 64 little 8

fn @f(%arg0: i32) -> i32 {
stack slot0: 8 bytes align 8
block0:
  br block1(%arg0)
block1(%v0: i32):
  %v1 = iadd %arg0, %v0
  %v2 = stack_addr slot0
  store %v2, %v1 align 4
  %v3 = load %v2 : i32 align 4
  return %v3
}
'
	assert printed == expected
}

fn test_flags_print_in_the_canonical_order() {
	text := 'target 64 little 8
fn @f(%a: i32, %b: i32) -> i32 {
block0:
  %v0 = iadd nuw nsw %a, %b
  %v1 = shl exact %v0, %b
  return %v1
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('  %v0 = iadd nsw nuw %arg0, %arg1\n'), printed
	assert printed.contains('  %v1 = shl exact %v0, %arg1\n'), printed
}

// The float group follows the integer and volatile group, in the order
// nnan ninf nsz arcp contract reassoc afn.
fn test_the_float_flags_print_after_the_integer_group() {
	text := 'target 64 little 8
fn @f(%a: f64, %b: f64) -> f64 {
block0:
  %v0 = fadd reassoc contract nnan %a, %b
  %v1 = frem afn nsz %v0, %b
  %v2 = fcmp ninf olt %v1, %a
  %v3 = select %v2, %v1, %a
  return %v3
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('  %v0 = fadd nnan contract reassoc %arg0, %arg1\n'), printed
	assert printed.contains('  %v1 = frem nsz afn %v0, %arg1\n'), printed
	assert printed.contains('  %v2 = fcmp ninf olt %v1, %arg0\n'), printed
}

fn test_an_iconst_prints_its_immediate_in_the_width_of_its_type() {
	text := 'target 64 little 8
fn @f() -> i32 {
block0:
  %v0 = iconst i32 -1
  %v1 = iconst i64 0xFFFFFFFF
  return %v0
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('  %v0 = iconst i32 4294967295\n'), printed
	assert printed.contains('  %v1 = iconst i64 4294967295\n'), printed
}

// A literal in an operand position is stored as the 128-bit pattern the lexer
// produced, because the parser does not type the position. The printer writes
// what the module holds, and reading it back gives the same module.
fn test_an_operand_immediate_prints_the_pattern_the_module_holds() {
	text := 'target 64 little 8
fn @f(%a: i32) -> i32 {
block0:
  %v0 = iadd %a, -1
  return %v0
}
'
	first := parse_text(text) or { panic('${err.msg()}') }
	printed := print_module(first)
	assert printed.contains('  %v0 = iadd %arg0, 340282366920938463463374607431768211455\n'), printed
	second := parse_text(printed) or { panic('${err.msg()}') }
	assert second.functions[0].blocks[0].instructions[0].operands[1].imm == first.functions[0].blocks[0].instructions[0].operands[1].imm
}

fn test_a_float_constant_prints_as_a_type_and_a_padded_bit_pattern() {
	text := 'target 64 little 8
fn @f() -> f64 {
block0:
  %v0 = fconst f64 0x3ff
  %v1 = fconst f32 0x3fc00000
  %v2 = fconst f16 0x3c00
  return %v0
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('  %v0 = fconst f64 0x00000000000003ff\n'), printed
	assert printed.contains('  %v1 = fconst f32 0x3fc00000\n'), printed
	assert printed.contains('  %v2 = fconst f16 0x3c00\n'), printed
}

fn test_a_conversion_prints_to_only_when_the_result_is_not_the_default() {
	text := 'target 64 little 8
fn @f(%p: ptr) -> i64 {
block0:
  %v0 = ptrtoint %p
  %v1 = inttoptr %v0
  %v2 = ptrtoint %p to i32
  %v3 = inttoptr %v2 to ptr
  return %v0
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('  %v0 = ptrtoint %arg0\n'), printed
	assert printed.contains('  %v1 = inttoptr %v0\n'), printed
	assert printed.contains('  %v2 = ptrtoint %arg0 to i32\n'), printed
	assert printed.contains('  %v3 = inttoptr %v2\n'), printed
}

fn test_a_location_prints_after_every_other_clause() {
	text := 'target 64 little 8
fn @f(%p: ptr) -> i32 {
block0:
  %v0 = load volatile %p : i32 align 4 @loc("main.c", 12, 5)
  return %v0
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('  %v0 = load volatile %arg0 : i32 align 4 @loc("main.c", 12, 5)\n'), printed
}

fn test_an_instruction_with_two_results_prints_both_names() {
	text := 'target 64 little 8
fn @f(%a: i32, %b: i32) -> i32 {
block0:
  %v0, %v1 = sadd_overflow %a, %b
  return %v0
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('  %v0, %v1 = sadd_overflow %arg0, %arg1\n'), printed
}

// The template, the constraints and a location are strings, and the printer
// writes them with the escapes the lexer reads and no others.
fn test_strings_use_the_documented_escapes() {
	text := 'target 64 little 8
fn @f() -> i64 {
block0:
  %v0 = inline_asm "q\\"b\\\\n\\t\\0\\x01\\xc3\\xa9" out(i64, "=r") @loc("dir/x.vel", 3, 4)
  return %v0
}
'
	first := parse_text(text) or { panic('${err.msg()}') }
	printed := print_module(first)
	assert printed.contains('q\\"b\\\\n\\t\\0\\x01\\xc3\\xa9'), printed
	second := parse_text(printed) or { panic('${err.msg()}') }
	assert second.functions[0].blocks[0].instructions[0].asm.template == first.functions[0].blocks[0].instructions[0].asm.template
}

// The volatile bit is an inline asm clause in the text, so it is written with
// the clauses and never in the flag position, which is where a file may also
// have put it.
fn test_an_inline_asm_writes_volatile_as_a_clause() {
	text := 'target 64 little 8
fn @f(%a: i64) -> i64 {
block0:
  %v0 = inline_asm "nop" out(i64, "=r") in(%a, "0") clobber("cc") alignstack intel volatile
  return %v0
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('inline_asm "nop" out(i64, "=r") in(%arg0, "0") clobber("cc") volatile alignstack intel\n'), printed
	assert !printed.contains('inline_asm volatile'), printed

	flag_spelling := 'target 64 little 8
fn @f(%a: i64) -> i64 {
block0:
  %v0 = inline_asm volatile "nop" out(i64, "=r") in(%a, "0")
  return %v0
}
'
	normalized := print_module(parse_text(flag_spelling) or { panic('${err.msg()}') })
	assert normalized.contains('inline_asm "nop" out(i64, "=r") in(%arg0, "0") volatile\n'), normalized
}

// A global prints its type and its constant tree on one line, and a tree that a
// person wrote in the canonical form reads back byte for byte.
fn test_a_global_prints_its_type_and_its_constant_tree() {
	text := 'target 32 big 4

pub global @origin: {i32, [2 x i8]} = {4294967295, [7, 255]}

global @weights: <2 x f64> = [f64 0x3ff0000000000000, f64 0x0000000000000000]

global @nothing: ptr = null

global @blank: [1000000 x i32] = zeroinit

global @big: i128 = 340282366920938463463374607431768211455

global @plain: i24
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed == text, printed
}

// A global's type may nest the three aggregate forms, and the text form writes
// the structure out in full.
fn test_a_global_type_parses_and_prints_back() {
	text := 'target 64 little 8

global @nested: {ptr, [4 x <8 x i16>]} = zeroinit
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed == text, printed
}

// noundef follows the type it applies to, and the effects follow the results in
// the canonical order whatever order the file wrote them in.
fn test_effects_and_noundef_print_after_the_results() {
	text := 'target 64 little 8

extern fn @f(%arg0: i32 noundef) -> (i32 noundef, i64) nounwind argmemonly readonly

fn @g(%p: ptr noundef, %x: i32 noundef) -> i32 noundef {
block0:
  %v0 = call_indirect %p : (i32 noundef) -> i32 noundef nounwind readonly (1)
  return %v0
}
'
	printed := print_module(parse_text(text) or { panic('${err.msg()}') })
	assert printed.contains('extern fn @f(%arg0: i32 noundef) -> (i32 noundef, i64) readonly argmemonly nounwind\n'), printed
	assert printed.contains('fn @g(%arg0: ptr noundef, %arg1: i32 noundef) -> i32 noundef {\n'), printed
	assert printed.contains('call_indirect %arg0 : (i32 noundef) -> i32 noundef readonly nounwind (1)'), printed
}

fn test_declarations_are_separated_by_one_blank_line_and_the_file_ends_once() {
	printed := print_module(printer_canonical())
	assert printed.ends_with('}\n'), printed
	assert !printed.ends_with('\n\n'), 'the file ends with more than one newline'
	assert !printed.contains('\n\n\n'), 'more than one blank line between declarations'
	assert !printed.contains('\r'), 'the file is not LF'
	for line in printed.split_into_lines() {
		assert !line.ends_with(' ') && !line.ends_with('\t'), 'a line ends in whitespace: ${line}'
	}
}

fn test_print_file_writes_text_that_parses_to_the_same_module() {
	path := os.join_path(os.temp_dir(), 'velocity_printer_test.vel')
	print_file(printer_canonical(), path) or { panic('${err.msg()}') }
	written := os.read_file(path) or { panic('${err.msg()}') }
	assert written == printer_fixture('canonical.vel')
	again := parse_file(path) or { panic('${err.msg()}') }
	assert again.functions.len == printer_canonical().functions.len
	os.rm(path) or {}
}
