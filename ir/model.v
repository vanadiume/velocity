module ir

// The model in ir-model.md. A module is a target, functions and globals. A
// function is blocks, and a block is typed parameters plus straight-line
// instructions plus one terminator, stored apart from the instruction list.

pub enum Endian {
	little
	big
}

pub struct TargetInfo {
pub:
	pointer_width u16 // bits
	pointer_align u16 // bytes
	endian        Endian
}

pub struct Module {
pub mut:
	target    TargetInfo
	functions []Function
	globals   []Global
}

pub struct Signature {
pub:
	params  []Type
	results []Type
}

pub struct Function {
pub mut:
	name        string // the symbol, spelled @name in text
	signature   Signature
	blocks      []Block
	stack_slots []StackSlot
	public      bool
	defined     bool // false for an extern declaration
	// values is the function's value table: function parameters, then each
	// block's parameters, then instruction results, in definition order. An
	// operand or a result names a value by its index here, because a value id
	// is not meaningful outside the function.
	values []Value
}

pub struct Block {
pub mut:
	label        string // the label as written; block order is the numbering
	params       []int  // value indices
	instructions []Instruction
	terminator   Instruction
}

pub enum ValueKind {
	function_param
	block_param
	instruction_result
}

pub struct Value {
pub mut:
	name  string
	typ   Type
	kind  ValueKind
	block int // block index, -1 for a function parameter
	inst  int // instruction index in the block, -1 otherwise
}

pub enum OperandKind {
	value
	int_imm
	float_imm
	symbol
	stack_slot
}

pub enum SymbolKind {
	none
	function
	global
}

// Operand is a value or an immediate. The line and column are where the parser
// read it, so a diagnostic can point at the operand rather than at the line.
pub struct Operand {
pub mut:
	kind OperandKind
	name string     // value, symbol or stack slot name, without the sigil
	idx  int        // the resolved index, or -1 when the text did not resolve
	sym  SymbolKind // what a symbol operand named, once it is resolved
	imm  u128       // an integer immediate, or a float bit pattern
	typ  Type       // the stated type of a float immediate
	line int
	col  int
}

pub struct FlagSet {
pub mut:
	nsw      bool
	nuw      bool
	exact    bool
	inbounds bool
	volatile bool
}

pub struct SourceLoc {
pub:
	file string
	line u32
	col  u32
}

pub struct BlockTarget {
pub mut:
	label string
	block int // resolved block index, -1 until the labels are resolved
	args  []Operand
	line  int
	col   int
}

pub struct SwitchCase {
pub mut:
	value  u128 // the case constant, as the text wrote it
	target BlockTarget
}

pub struct InlineAsmOutput {
pub:
	typ        Type
	constraint string
}

pub struct InlineAsmInput {
pub mut:
	value      Operand
	constraint string
}

pub struct InlineAsm {
pub mut:
	template   string
	outputs    []InlineAsmOutput
	inputs     []InlineAsmInput
	clobbers   []string
	volatile   bool
	alignstack bool
	intel      bool
}

// Instruction is one opcode, with the operand and clause shapes the opcode
// takes. A field that the opcode does not use keeps its zero value: the text
// says which of them are present, so the struct carries them all.
pub struct Instruction {
pub mut:
	opcode      Opcode
	flags       FlagSet
	operands    []Operand
	results     []int // value indices, in result order
	typ         Type  // the type the text states: the constant, the load, the conversion
	align       u16
	align_dst   u16
	align_src   u16
	predicate   string
	signature   Signature
	target      BlockTarget
	else_target BlockTarget
	cases       []SwitchCase
	trap_code   u32
	asm         InlineAsm
	loc         ?SourceLoc
}

pub struct StackSlot {
pub:
	size  u32
	align u16
	name  ?string
}

pub struct Global {
pub:
	name     string
	size     u64
	align    u16
	readonly bool
	public   bool
	init     []u8 // shorter than size means zero fill
}

// find_function_index returns the first declaration or definition of a symbol.
pub fn (m &Module) find_function_index(name string) ?int {
	for i, f in m.functions {
		if f.name == name {
			return i
		}
	}
	return none
}

pub fn (m &Module) find_global_index(name string) ?int {
	for i, g in m.globals {
		if g.name == name {
			return i
		}
	}
	return none
}

// symbol_kind says what a name in the module names. A name is either a function
// or a global; a name that is neither is not declared at all.
pub fn (m &Module) symbol_kind(name string) SymbolKind {
	if _ := m.find_function_index(name) {
		return .function
	}
	if _ := m.find_global_index(name) {
		return .global
	}
	return .none
}
