module ir

// The refused corpus: one function or module the verifier must refuse, the code
// it must report, and a fragment of the message that names the site.
//
// A row is text when the parser can produce the shape. The shapes the parser
// refuses to build on its own, a terminator in an instruction list and a value
// defined twice, are in verify_test.v where the module is assembled by hand.

struct Refusal {
	text     string
	code     string
	fragment string
}

const refused = [
	Refusal{
		text:     'target 48 little 8\n'
		code:     'V001'
		fragment: 'pointer width is 48'
	},
	Refusal{
		text:     'target 64 little 3\n'
		code:     'V001'
		fragment: 'pointer alignment is 3'
	},
	Refusal{
		text:     'target 64 little 8
fn @f() {
block0(%v0: i32):
  return
}
'
		code:     'V002'
		fragment: 'entry block has 1 parameters'
	},
	Refusal{
		text:     'target 64 little 8
fn @f() {
block0:
  br block1()
block1:
  br block0()
}
'
		code:     'V002'
		fragment: 'cannot be a jump target'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: i64\n\nfn @g() {\nblock0:\n  return\n}\n'
		code:     'V020'
		fragment: 'both a function and a global'
	},
	Refusal{
		text:     'target 64 little 8
fn @f() {
block0:
  return
}

fn @f() {
block0:
  return
}
'
		code:     'V020'
		fragment: 'defined more than once'
	},
	Refusal{
		text:     'target 64 little 8
extern fn @f(%arg0: i32) -> i32

fn @f(%arg0: i64) -> i64 {
block0:
  return %arg0
}
'
		code:     'V019'
		fragment: 'is declared (i32) -> i32'
	},
	Refusal{
		text:     'target 64 little 8\nextern fn @f(%arg0: i32) -> i32 readonly readnone\n'
		code:     'V032'
		fragment: 'is both readonly and readnone'
	},
	Refusal{
		text:     'target 64 little 8\nfn @f(%p: ptr) -> i32 {\nblock0:\n  %v0 = call_indirect %p : (i32) -> i32 readonly readnone (1)\n  return %v0\n}\n'
		code:     'V032'
		fragment: 'is both readonly and readnone'
	},
	Refusal{
		text:     'target 64 little 8\nextern fn @f(%arg0: i32) -> i32 readonly\n\nfn @f(%arg0: i32) -> i32 readnone {\nblock0:\n  return %arg0\n}\n'
		code:     'V019'
		fragment: 'is declared (i32) -> i32 readonly'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: [4 x i32] = [1, 2]\n'
		code:     'V033'
		fragment: 'has 2 leaves and [4 x i32] has 4 elements'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: {i32, i8} = {1}\n'
		code:     'V033'
		fragment: 'has 1 leaves and {i32, i8} has 2 fields'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: i8 = 300\n'
		code:     'V033'
		fragment: 'does not fit i8'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: f64 = f32 0x3fc00000\n'
		code:     'V033'
		fragment: 'is written f32, expected f64'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: i64 = null\n'
		code:     'V033'
		fragment: 'is null, expected an integer leaf'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: {}\n'
		code:     'V023'
		fragment: 'a struct has at least one field'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: [0 x i32]\n'
		code:     'V023'
		fragment: 'an array has at least one element'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: <4 x {i32}>\n'
		code:     'V023'
		fragment: 'a vector element is an integer, a float or a pointer'
	},
	Refusal{
		text:     'target 64 little 8\nglobal @g: i1\n'
		code:     'V015'
		fragment: 'expected a memory type'
	},
	Refusal{
		text:     'target 64 little 8
fn @f() {
stack slot0: 0 bytes align 1
block0:
  return
}
'
		code:     'V021'
		fragment: "stack slot 'slot0' has size 0"
	},
	Refusal{
		text:     'target 64 little 8
fn @f() {
stack slot0: 8 bytes align 3
block0:
  return
}
'
		code:     'V010'
		fragment: "stack slot 'slot0' has align 3"
	},
	Refusal{
		text:     'target 64 little 8
fn @f() {
block0:
  return
block1:
  return
}
'
		code:     'V022'
		fragment: 'block1 is not reachable'
	},
	Refusal{
		text:     'target 64 little 8
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
'
		code:     'V006'
		fragment: 'is defined in block1 and used in block3'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i32) -> i32 {
block0:
  %v0 = iadd %arg0, %v1
  %v1 = iconst i32 2
  return %v0
}
'
		code:     'V006'
		fragment: 'before its definition at index 1'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i32, %arg1: i64) -> i32 {
block0:
  %v0 = iadd %arg0, %arg1
  return %v0
}
'
		code:     'V007'
		fragment: 'operand 2 of ' + "'iadd'" + ' has type i64, expected i32'
	},
	Refusal{
		text:     'target 64 little 8
fn @f() -> i32 {
block0:
  %v0 = iadd 1, 2
  return %v0
}
'
		code:     'V007'
		fragment: 'has no operand with a type'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i32, %arg1: i32) -> i32 {
block0:
  %v0 = iadd exact %arg0, %arg1
  return %v0
}
'
		code:     'V008'
		fragment: 'does not accept the ' + "'exact'" + ' flag'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i8) -> i8 {
block0:
  %v0 = iadd %arg0, 300
  return %v0
}
'
		code:     'V009'
		fragment: 'does not fit i8'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: ptr) -> i3 {
block0:
  %v0 = load %arg0 : i3 align 1
  return %v0
}
'
		code:     'V015'
		fragment: 'is i3, expected a byte-sized type'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i12) -> i12 {
block0:
  %v0 = bswap %arg0
  return %v0
}
'
		code:     'V016'
		fragment: 'expected a width that is a multiple of 8'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: ptr) -> i32 {
block0:
  %v0 = ptrtoint %arg0 to i32
  return %v0
}
'
		code:     'V017'
		fragment: 'expected the pointer width i64'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: ptr) -> i32 {
block0:
  %v0 = load %arg0 : i32 align 3
  return %v0
}
'
		code:     'V010'
		fragment: 'has align 3, expected a power of two'
	},
	Refusal{
		text:     'target 64 little 8
fn @f() {
block0:
  br block1(1)
block1(%v0: i32, %v1: i32):
  return
}
'
		code:     'V004'
		fragment: 'passes 1 arguments, and block1 takes 2'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i64) {
block0:
  br block1(%arg0)
block1(%v0: i32):
  return
}
'
		code:     'V004'
		fragment: 'has type i64, expected i32'
	},
	Refusal{
		text:     'target 64 little 8
fn @f() -> i32 {
block0:
  return
}
'
		code:     'V011'
		fragment: 'the function returns one value'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i32) -> i64 {
block0:
  return %arg0
}
'
		code:     'V011'
		fragment: 'has type i32, expected i64'
	},
	Refusal{
		text:     'target 64 little 8
extern fn @g(%arg0: i64) -> i64

fn @f(%arg0: i32) -> i64 {
block0:
  %v0 = call @g(%arg0)
  return %v0
}
'
		code:     'V012'
		fragment: 'has type i32, expected i64'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: ptr) -> i32 {
block0:
  %v0 = call_indirect %arg0 : (i32) -> i32 ()
  return %v0
}
'
		code:     'V012'
		fragment: 'carries 1 parameters, and the call passes 0 arguments'
	},
	Refusal{
		text:     'target 64 little 8
extern fn @g(%arg0: i64) -> i64

fn @f(%arg0: i64) -> i32 {
block0:
  tailcall @g(%arg0)
}
'
		code:     'V013'
		fragment: 'returns i64, and the function returns i32'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i32) {
block0:
  switch %arg0, block1(), 0: block1(), 0: block1()
block1:
  return
}
'
		code:     'V014'
		fragment: 'repeats case 1'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i8) {
block0:
  switch %arg0, block1(), 300: block1()
block1:
  return
}
'
		code:     'V014'
		fragment: 'does not fit i8'
	},
	Refusal{
		text:     'target 64 little 8
fn @f(%arg0: i64) -> i64 {
block0:
  %v0 = inline_asm "nop" out(i64, "=r") in(%arg0, "")
  return %v0
}
'
		code:     'V018'
		fragment: 'names no constraint'
	},
	Refusal{
		text:     'target 64 little 8\nfn @f(%arg0: i32) -> i32 {\nblock0:\n  %v0 = inline_asm "nop" out({i32}, "=r") in(%arg0, "r")\n  return %arg0\n}\n'
		code:     'V018'
		fragment: 'an aggregate is never an asm operand'
	},
	Refusal{
		text:     'target 64 little 8\nfn @f(%arg0: {i32}) -> i32 {\nblock0:\n  %v0 = inline_asm "nop" out(i32, "=r") in(%arg0, "r")\n  return %v0\n}\n'
		code:     'V018'
		fragment: 'an aggregate is never an asm operand'
	},
]

fn test_the_refused_corpus() {
	for row in refused {
		module := parse_text(row.text) or { panic('${row.code}: the text does not parse: ${err.msg()}') }
		errors := verify_module(module)
		mut found := false
		for error in errors {
			if error.code == row.code && error.message.contains(row.fragment) {
				found = true
				break
			}
		}
		assert found, 'expected ${row.code} containing "${row.fragment}", got:\n${errors.map(it.msg()).join('\n')}'
	}
}

fn target64() TargetInfo {
	return TargetInfo{
		pointer_width: 64
		pointer_align: 8
		endian:        .little
	}
}

fn messages(errors []VerifyError) string {
	return errors.map(it.msg()).join('\n')
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
		signature: signature([], [result(ty_i32, false)])
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

fn test_an_operand_naming_a_value_that_does_not_exist_is_refused() {
	mut function := Function{
		name:      'f'
		defined:   true
		signature: signature([], [result(ty_i32, false)])
	}
	function.blocks << Block{
		label:      'block0'
		terminator: Instruction{
			opcode:   .@return
			operands: [Operand{
				kind: .value
				name: 'v7'
				idx:  7
			}]
		}
	}
	module := Module{
		target:    target64()
		functions: [function]
	}
	errors := verify_module(module)
	assert errors.len == 1, messages(errors)
	assert errors[0].code == 'V005'
	assert errors[0].message.contains('value 7 is not in the function value table')
}

// hand_built_modules holds the shapes the parser refuses to build: a terminator
// inside the instruction list, and a value defined twice. They are here so the
// corpus covers V003 and V005 with a module that really produces them.
fn hand_built_modules() []Module {
	mut modules := []Module{}
	mut with_terminator := Function{
		name:    'terminator'
		defined: true
	}
	with_terminator.blocks << Block{
		label:        'block0'
		instructions: [Instruction{ opcode: .br }]
		terminator:   Instruction{ opcode: .@return }
	}
	modules << Module{
		target:    target64()
		functions: [with_terminator]
	}
	mut doubled := Function{
		name:      'doubled'
		defined:   true
		signature: signature([], [result(ty_i32, false)])
	}
	doubled.blocks << Block{
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
	doubled.values << Value{
		name:  'v0'
		typ:   ty_i32
		kind:  .instruction_result
		block: 0
		inst:  0
	}
	modules << Module{
		target:    target64()
		functions: [doubled]
	}
	return modules
}

fn test_the_corpus_covers_every_code() {
	mut seen := map[string]bool{}
	for row in refused {
		module := parse_text(row.text) or { panic('${err.msg()}') }
		for error in verify_module(module) {
			seen[error.code] = true
		}
	}
	for module in hand_built_modules() {
		for error in verify_module(module) {
			seen[error.code] = true
		}
	}
	codes := ['V001', 'V002', 'V003', 'V004', 'V005', 'V006', 'V007', 'V008', 'V009', 'V010', 'V011',
		'V012', 'V013', 'V014', 'V015', 'V016', 'V017', 'V018', 'V019', 'V020', 'V021', 'V022',
		'V023', 'V032', 'V033']
	assert codes.len == 25
	for code in codes {
		assert code in seen, 'the corpus has no case for ${code}'
	}
}
