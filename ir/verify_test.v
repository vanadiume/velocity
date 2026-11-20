module ir

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

fn test_a_terminator_inside_the_instruction_list_is_refused() {
	mut function := Function{
		name:    'f'
		defined: true
	}
	function.blocks << Block{
		label:        'block0'
		instructions: [Instruction{ opcode: .br }]
		terminator:   Instruction{ opcode: .@return }
	}
	module := Module{
		target:    target64()
		functions: [function]
	}
	errors := verify_module(module)
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V003'
	assert errors[0].message.contains("'br' is a terminator")
	assert errors[0].function or { '' } == 'f'
	assert errors[0].block or { 99 } == 0
	assert errors[0].inst or { 99 } == 0
}

fn test_a_block_with_no_terminator_is_refused() {
	mut function := Function{
		name:    'f'
		defined: true
	}
	function.blocks << Block{
		label:      'block0'
		terminator: Instruction{ opcode: .iconst }
	}
	module := Module{
		target:    target64()
		functions: [function]
	}
	errors := verify_module(module)
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V003'
	assert errors[0].message == 'the block has no terminator'
}

fn test_a_value_defined_twice_is_refused() {
	mut function := Function{
		name:      'f'
		defined:   true
		signature: Signature{
			results: [ty_i32]
		}
	}
	function.blocks << Block{
		label:        'block0'
		instructions: [
			Instruction{
				opcode:   .iconst
				typ:      ty_i32
				operands: [Operand{
					kind: .int_imm
					imm:  u128(1)
					idx:  -1
				}]
				results:  [0]
			},
			Instruction{
				opcode:   .iconst
				typ:      ty_i32
				operands: [Operand{
					kind: .int_imm
					imm:  u128(2)
					idx:  -1
				}]
				results:  [0]
			},
		]
		terminator:   Instruction{
			opcode:   .@return
			operands: [Operand{
				kind: .value
				name: 'v0'
				idx:  0
			}]
		}
	}
	function.values << Value{
		name:  'v0'
		typ:   ty_i32
		kind:  .instruction_result
		block: 0
		inst:  0
	}
	module := Module{
		target:    target64()
		functions: [function]
	}
	errors := verify_module(module)
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V005'
	assert errors[0].message.contains('already defined')
}

fn test_a_value_that_is_never_defined_is_refused() {
	mut function := Function{
		name:    'f'
		defined: true
	}
	function.blocks << Block{
		label:      'block0'
		terminator: Instruction{ opcode: .unreachable }
	}
	function.values << Value{
		name:  'v0'
		typ:   ty_i32
		kind:  .instruction_result
		block: 0
		inst:  0
	}
	module := Module{
		target:    target64()
		functions: [function]
	}
	errors := verify_module(module)
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V005'
	assert errors[0].message.contains('is never defined')
}

fn test_a_defined_function_with_no_blocks_is_refused() {
	mut function := Function{
		name:    'f'
		defined: true
	}
	module := Module{
		target:    target64()
		functions: [function]
	}
	errors := verify_module(module)
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V002'
	assert errors[0].message.contains('no blocks')
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
global @g: 2 bytes align 8 init 0x00112233
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
