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
pub mut:
	params  []Param
	results []Result
	effects EffectSet
}

// Param is one parameter: its type and whether the caller promises it is never
// poison. Result is the same promise in the other direction.
pub struct Param {
pub:
	typ     Type
	noundef bool
}

pub struct Result {
pub:
	typ     Type
	noundef bool
}

// EffectSet is the four call effects from ir-model.md. readonly and readnone
// are never both set, which V032 enforces.
pub struct EffectSet {
pub mut:
	readonly   bool
	readnone   bool
	argmemonly bool
	nounwind   bool
}

pub enum Effect {
	readonly
	readnone
	argmemonly
	nounwind
}

pub fn param(typ Type, noundef bool) Param {
	return Param{
		typ:     typ
		noundef: noundef
	}
}

pub fn result(typ Type, noundef bool) Result {
	return Result{
		typ:     typ
		noundef: noundef
	}
}

pub fn signature(params []Param, results []Result) Signature {
	return Signature{
		params:  params
		results: results
	}
}

// signature_with_effects is the constructor a frontend uses when a declaration
// carries the effects an optimizer reads at every call.
pub fn signature_with_effects(params []Param, results []Result, effects EffectSet) Signature {
	return Signature{
		params:  params
		results: results
		effects: effects
	}
}

pub fn effects(list ...Effect) EffectSet {
	mut set := EffectSet{}
	for effect in list {
		match effect {
			.readonly { set.readonly = true }
			.readnone { set.readnone = true }
			.argmemonly { set.argmemonly = true }
			.nounwind { set.nounwind = true }
		}
	}
	return set
}

pub fn (e EffectSet) is_empty() bool {
	return !e.readonly && !e.readnone && !e.argmemonly && !e.nounwind
}

// text is the canonical order from ir-text.md.
pub fn (e EffectSet) text() string {
	mut written := []string{cap: 4}
	if e.readonly {
		written << 'readonly'
	}
	if e.readnone {
		written << 'readnone'
	}
	if e.argmemonly {
		written << 'argmemonly'
	}
	if e.nounwind {
		written << 'nounwind'
	}
	return written.join(' ')
}

pub fn (p Param) str() string {
	if p.noundef {
		return '${p.typ.str()} noundef'
	}
	return p.typ.str()
}

pub fn (r Result) str() string {
	if r.noundef {
		return '${r.typ.str()} noundef'
	}
	return r.typ.str()
}

pub fn (s Signature) param_types() []Type {
	mut types := []Type{cap: s.params.len}
	for p in s.params {
		types << p.typ
	}
	return types
}

pub fn (s Signature) result_types() []Type {
	mut types := []Type{cap: s.results.len}
	for r in s.results {
		types << r.typ
	}
	return types
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
	typ      Type // the size and the alignment come from this type
	readonly bool
	public   bool
	init     ?Const // absent means zero-filled
}

pub enum ConstKind {
	zero
	int
	float
	null
	seq
}

// Const is a global's initializer: the typed constant tree from ir-model.md.
// bits carries an integer value or a float's bit pattern, typ is the type a
// float leaf states, and elems is a struct's fields, an array's elements or a
// vector's lanes. zero stands for every zero leaf at once, at any depth.
pub struct Const {
pub:
	kind  ConstKind
	bits  u128
	typ   Type
	elems []Const
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
