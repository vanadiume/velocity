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
		text:     'target 64 little 8
global @g: 8 bytes align 8

fn @g() {
block0:
  return
}
'
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
		text:     'target 64 little 8
global @g: 2 bytes align 8 init 0x00112233
'
		code:     'V021'
		fragment: 'the global is 2 bytes'
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
global @g: 8 bytes align 3
'
		code:     'V010'
		fragment: "global '@g' has align 3"
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
