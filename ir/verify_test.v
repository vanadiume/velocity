module ir

import os

// What the verifier accepts, and the shapes that only a hand-built module can
// have. The text cases the verifier refuses are in verify_refused_test.v.

fn verify_text(text string) []VerifyError {
	module := parse_text(text) or { panic('${err.msg()}') }
	return verify_module(module)
}

fn messages(errors []VerifyError) string {
	return errors.map(it.msg()).join('\n')
}

fn assert_verified(text string) {
	errors := verify_text(text)
	assert errors.len == 0, messages(errors)
}

fn target64() TargetInfo {
	return TargetInfo{
		pointer_width: 64
		pointer_align: 8
		endian:        .little
	}
}

fn test_an_empty_module_verifies() {
	assert_verified('target 64 little 8\n')
}

fn test_a_small_function_verifies() {
	assert_verified('target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iadd %arg0, 1
  return %v0
}
')
}

// A global's initializer is a constant tree of its type: every leaf form, a
// nested aggregate, and zeroinit at any depth.
fn test_every_global_initializer_form_verifies() {
	assert_verified('target 64 little 8
pub global @counter: i64 = 1
global @negative: i32 = -1
global @zero: i32 = 0
global @pi: f32 = f32 0x40490fdb
global @nowhere: ptr = null
global @zeroed: [4 x i32] = zeroinit
global @pair: {i32, i64} = {7, 8}
global @nested: {i32, [2 x i8]} = {1, [2, 3]}
global @weights: <4 x f32> = [f32 0x3f800000, f32 0x40000000, f32 0x40400000, f32 0x40800000]
global @bytes: [4 x i8] = [1, 2, 3, 255]
global @plain: [2 x i16]
')
}

// A signature carries its effects and the noundef promise on each parameter
// and result. A direct call reads them from the declaration; an indirect call
// carries them in its own signature.
fn test_effects_and_noundef_verify() {
	assert_verified('target 64 little 8
extern fn @printf_like(%fmt: ptr noundef) -> i32 readonly nounwind

extern fn @checked(%x: i32 noundef) -> i32 noundef readnone

extern fn @g(%arg0: i32 noundef) -> i32 noundef readonly

fn @g(%arg0: i32 noundef) -> i32 noundef readonly {
block0:
  return %arg0
}

fn @use(%x: i32 noundef) -> i32 {
block0:
  %v0 = call @checked(%x)
  return %v0
}

fn @caller(%p: ptr noundef) -> i32 noundef {
block0:
  %v0 = call_indirect %p : (i32 noundef) -> i32 noundef readonly nounwind (1)
  return %v0
}
')
}

// The float flags are one opt-in group. They are accepted on the arithmetic,
// fsqrt and fma, and nnan and ninf also on fcmp.
fn test_the_float_flags_are_accepted_where_the_table_lists_them() {
	assert_verified('target 64 little 8
fn @f(%arg0: f64, %arg1: f64) -> f64 {
block0:
  %v0 = fadd nnan ninf nsz arcp contract reassoc afn %arg0, %arg1
  %v1 = fsub contract %v0, %arg1
  %v2 = fmul reassoc %v1, %arg1
  %v3 = fdiv arcp %v2, %arg1
  %v4 = frem nsz %v3, %arg1
  %v5 = fsqrt nnan %v4
  %v6 = fma reassoc %arg0, %arg1, %v5
  %v7 = fcmp nnan olt %v6, %arg0
  %v8 = select %v7, %v6, %arg0
  return %v8
}
')
}

// A declaration alone verifies.
fn test_a_declaration_alone_verifies() {
	assert_verified('target 32 big 4
extern fn @puts(%arg0: ptr) -> i32
')
}

fn test_a_declaration_and_a_definition_that_agree_verify() {
	assert_verified('target 64 little 8
extern fn @f(%arg0: i64) -> i64
fn @f(%arg0: i64) -> i64 {
block0:
  return %arg0
}
')
}

fn test_a_function_can_be_checked_on_its_own() {
	module := parse_text('target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iadd %arg0, 1
  return %v0
}
') or { panic('${err.msg()}') }
	assert verify_function(module, module.functions[0]).len == 0
}

fn test_two_runs_report_the_same_list() {
	module := parse_text('target 48 little 3
global @g: i8 = 300
fn @f(%arg0: i32) -> i64 {
block0:
  return %arg0
}
') or { panic('${err.msg()}') }
	first := verify_module(module).map(it.msg())
	second := verify_module(module).map(it.msg())
	assert first == second
	assert first.len > 0
}

fn test_a_join_reads_its_block_parameters() {
	assert_verified('target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
  br block1(%arg0)
block1(%v0: i32):
  %v1 = iadd %v0, 1
  br block2()
block2:
  %v2 = icmp sgt %v1, 0
  br block3(%v2)
block3(%v3: i1):
  %v4 = select %v3, %v1, %v0
  return %v4
}
')
}

fn test_a_branch_value_used_at_a_join_is_refused() {
	errors := verify_text('target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = icmp sgt %arg0, 0
  condbr %v0, block1(), block2()
block1:
  %v1 = iconst i32 7
  br block3()
block2:
  br block3()
block3:
  %v2 = iadd %v1, 1
  return %v2
}
')
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V006'
	assert errors[0].message.contains('%v1 is defined in block1 and used in block3')
}

fn test_a_value_used_before_its_definition_is_refused() {
	errors := verify_text('target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iadd %arg0, %v1
  %v1 = iconst i32 2
  return %v0
}
')
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V006'
	assert errors[0].message.contains('%v1 is used at index 0 of block0, before its definition at index 1')
}

fn test_a_value_used_by_its_own_instruction_is_refused() {
	errors := verify_text('target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iadd %arg0, %v0
  return %v0
}
')
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V006'
	assert errors[0].message.contains('%v0 is used by the instruction that defines it')
}

fn test_every_flag_is_accepted_where_the_table_lists_it() {
	assert_verified('target 64 little 8
fn @f(%arg0: i32, %arg1: i32, %arg2: ptr) -> i32 {
block0:
  %v0 = iadd nsw nuw %arg0, %arg1
  %v1 = isub nsw %v0, %arg1
  %v2 = imul nuw %v1, %arg1
  %v3 = sdiv exact %v2, %arg1
  %v4 = udiv exact %v3, %arg1
  %v5 = srem exact %v4, %arg1
  %v6 = urem exact %v5, %arg1
  %v7 = ineg nsw %v6
  %v8 = shl nuw nsw %v7, %arg1
  %v9 = sshr exact %v8, %arg1
  %v10 = ushr exact %v9, %arg1
  %v11 = ptradd inbounds %arg2, 4
  %v12 = load volatile %v11 : i32 align 4
  store volatile %arg2, %v12 align 4
  %v13, %v14 = inline_asm "nop" out(i32, "=r") out(i32, "=r") in(%v12, "r") volatile
  return %v13
}
')
}

fn test_widths_the_target_does_not_have_verify() {
	assert_verified('target 64 little 8
fn @narrow(%arg0: i3, %arg1: i3) -> i3 {
block0:
  %v0 = iadd %arg0, %arg1
  %v1 = icmp slt %v0, %arg0
  %v2 = select %v1, %v0, %arg1
  return %v2
}

fn @wide(%arg0: i128, %arg1: i128) -> (i128, i1) {
block0:
  %v0, %v1 = sadd_overflow %arg0, %arg1
  %v2 = bswap %v0
  %v3 = popcnt %v2
  %v4 = icmp eq %v3, 0
  return %v2, %v4
}

fn @halves(%arg0: f16, %arg1: f128) -> f128 {
block0:
  %v0 = fpext %arg0 to f128
  %v1 = fadd %v0, %arg1
  %v2 = fcmp olt %v1, %arg1
  %v3 = select %v2, %v1, %arg1
  return %v3
}

fn @bytes(%arg0: ptr, %arg1: i24) -> i24 {
block0:
  %v0 = load %arg0 : i24 align 1
  %v1 = iadd %v0, %arg1
  %v2 = bswap %v1
  store %arg0, %v2 align 2
  return %v2
}
')
}

fn test_pointer_comparisons_and_casts_verify() {
	assert_verified('target 64 little 8
fn @f(%arg0: ptr, %arg1: ptr) -> i64 {
block0:
  %v0 = icmp ugt %arg0, %arg1
  %v1 = select %v0, %arg0, %arg1
  %v2 = ptrtoint %v1 to i64
  %v3 = bitcast %v2 to f64
  return %v2
}
')
}

fn test_a_float_predicate_on_an_integer_comparison_is_refused() {
	errors := verify_text('target 64 little 8
fn @f(%arg0: f32, %arg1: f32) -> i1 {
block0:
  %v0 = fcmp slt %arg0, %arg1
  return %v0
}
')
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V007'
	assert errors[0].message.contains("'fcmp slt' is not a float predicate")
}

fn test_an_ordered_pointer_comparison_is_refused() {
	errors := verify_text('target 64 little 8
fn @f(%arg0: ptr, %arg1: ptr) -> i1 {
block0:
  %v0 = icmp slt %arg0, %arg1
  return %v0
}
')
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V007'
	assert errors[0].message.contains('is not defined on pointers')
}

fn test_a_store_of_an_untyped_immediate_is_refused() {
	errors := verify_text('target 64 little 8
fn @f(%arg0: ptr) {
block0:
  store %arg0, 0 align 4
  return
}
')
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V007'
	assert errors[0].message.contains('write an iconst for it')
}

fn test_a_switch_with_negative_cases_verifies() {
	assert_verified('target 64 little 8
fn @f(%arg0: i8) -> i8 {
block0:
  switch %arg0, block1(-1), -1: block1(0), 127: block1(-128)
block1(%v0: i8):
  return %v0
}
')
}

fn test_a_tail_call_and_an_indirect_call_verify() {
	assert_verified('target 64 little 8
extern fn @identity(%arg0: i64) -> i64

fn @forward(%arg0: i64) -> i64 {
block0:
  tailcall @identity(%arg0)
}

fn @indirect(%arg0: ptr) -> i32 {
block0:
  %v0 = call_indirect %arg0 : (i32) -> i32 (5)
  %v1 = call_indirect %arg0 : () -> i32 ()
  return %v1
}
')
}

fn test_inline_asm_with_an_output_verifies() {
	assert_verified('target 64 little 8
fn @read_tsc() -> i64 {
block0:
  %v0 = inline_asm "rdtsc" out(i64, "=A")
  return %v0
}
')
}

// A vector is a register-sized operand; an aggregate is not, because a
// constraint cannot name one.
fn test_inline_asm_accepts_a_vector_output() {
	assert_verified('target 64 little 8
fn @vec_asm(%arg0: <2 x i32>) -> <2 x i32> {
block0:
  %v0 = inline_asm "nop" out(<2 x i32>, "=x") in(%arg0, "x")
  return %v0
}
')
}

fn test_a_call_to_a_function_declared_later_verifies() {
	assert_verified('target 64 little 8
fn @caller(%arg0: i64) -> i64 {
block0:
  %v0 = call @later(%arg0)
  return %v0
}

fn @later(%arg0: i64) -> i64 {
block0:
  return %arg0
}
')
}

fn read_fixture(name string) string {
	path := os.join_path(@DIR, 'testdata', name)
	return os.read_file(path) or { panic('cannot read ${path}: ${err}') }
}

fn verify_fixture(name string) []VerifyError {
	module := parse_text(read_fixture(name)) or { panic('${name}: ${err.msg()}') }
	return verify_module(module)
}

// The canonical fixture is the parser's reference file. It is also a legal
// module, so the verifier has to accept every shape it covers.
fn test_the_canonical_fixture_verifies() {
	errors := verify_fixture('canonical.vel')
	assert errors.len == 0, messages(errors)
}

// The opcode fixture names every opcode at least once, so it is the breadth
// half of the accepted corpus.
fn test_the_opcode_fixture_verifies() {
	errors := verify_fixture('opcodes.vel')
	assert errors.len == 0, messages(errors)
}

// Every width class, a join with block parameters, two results, a tail call and
// an indirect call with an immediate argument.
fn test_the_width_fixture_verifies() {
	errors := verify_fixture('verify_accepted.vel')
	assert errors.len == 0, messages(errors)
}

// A long function is a test case: reachability, the dominator tree and the error
// list all have to stay linear enough that ten thousand blocks are a second's
// work rather than a stack overflow.
fn test_a_function_with_ten_thousand_blocks_verifies() {
	count := 10000
	mut function := Function{
		name:    'big'
		defined: true
	}
	for i in 0 .. count {
		mut terminator := Instruction{ opcode: .unreachable }
		if i + 1 < count {
			terminator = Instruction{
				opcode: .br
				target: BlockTarget{
					label: 'block${i + 1}'
					block: i + 1
				}
			}
		}
		function.blocks << Block{
			label:      'block${i}'
			terminator: terminator
		}
	}
	module := Module{
		target:    target64()
		functions: [function]
	}
	errors := verify_module(module)
	assert errors.len == 0, messages(errors)
}

// A loop header has two predecessors once the back edge exists, so this is the
// case where the dominator fixpoint has to settle rather than take the first
// predecessor it sees.
fn test_a_loop_verifies() {
	assert_verified('target 64 little 8
fn @loop(%arg0: i32) -> i32 {
block0:
  br block1(%arg0)
block1(%v0: i32):
  %v1 = icmp sgt %v0, 10
  condbr %v1, block3(%v0), block2()
block2:
  %v2 = iadd %v0, 1
  br block1(%v2)
block3(%v3: i32):
  return %v3
}
')
}

fn test_a_value_from_a_loop_body_is_not_available_in_the_header() {
	errors := verify_text('target 64 little 8
fn @loop(%arg0: i32) -> i32 {
block0:
  br block1(%arg0)
block1(%v0: i32):
  %v1 = iadd %arg0, %v2
  br block2()
block2:
  %v2 = iconst i32 1
  %v3 = icmp eq %v0, 0
  condbr %v3, block1(%v2), block3(%v0)
block3(%v4: i32):
  return %v4
}
')
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V006'
	assert errors[0].message.contains('is defined in block2 and used in block1')
}
