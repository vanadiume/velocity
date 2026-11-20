module ir

// The builder in ir-builder.md: one cursor over one function, one method per
// opcode, and the variables a frontend declares. A call that would produce IR
// the verifier refuses is a frontend bug, so the builder panics where the
// mistake was written: the method name, the value, the expected type and the
// actual type are in the message.

// ValueRef is a handle to an SSA value: its index in the function's value table
// and its type. The model's Value is the table entry; a frontend holds this
// instead. A use that is still waiting on a block boundary has no table entry
// yet, so its index is negative until sealing resolves it. The type is carried
// here so a pending value can still be type checked.
pub struct ValueRef {
pub:
	idx int
	typ Type
}

// Edge is one incoming jump to a block, and which target of the terminator it
// is: 0 br, 1 condbr then, 2 condbr else, 3 switch default, 4 and up switch
// cases in order.
struct Edge {
	block int
	which int
}

enum UseKind {
	operand
	asm_input
	jump_arg
}

// UseSite is one place an operand sits, so a pending value can be patched once
// the block that owns it is sealed. inst is -1 for the terminator.
struct UseSite {
	block int
	inst  int
	kind  UseKind
	which int
	index int
}

// PendingValue is a use of a variable before its block was sealed. The block
// boundary decides the value and the builder patches every site that names it.
struct PendingValue {
	block    int
	variable int
	typ      Type
mut:
	sites []UseSite
}

pub struct Builder {
pub mut:
	function      &Function
	current_block int // -1 until create_entry_block or switch_to_block
	current_loc   ?SourceLoc
	target        ?TargetInfo
mut:
	entry_created  bool
	finished       bool
	sealed         []bool
	defs           []map[int]int // variable id to value index, the last def in the block
	boundary       []map[int]int // variable id to the value resolved for the block boundary
	edges          [][]Edge
	pending        [][]int       // pending value indices, in creation order, per block
	pending_vars   []map[int]int // variable id to pending index, per block
	pending_values []PendingValue
	variables      []Variable
}

// Variable is a frontend handle: an id and a type. It is not an IR value and it
// never appears in the text form.
pub struct Variable {
pub:
	id  int
	typ Type
}

// new_function starts a definition with a signature and the function parameters
// in the first slots of its value table.
pub fn new_function(name string, params []Type, results []Type) Function {
	mut function := Function{
		name:    name
		defined: true
	}
	function.signature = Signature{
		params:  params
		results: results
	}
	for typ in params {
		function.values << Value{
			typ:   typ
			kind:  .function_param
			block: -1
			inst:  -1
		}
	}
	return function
}

// new_builder takes the function a frontend is building. The target is what a
// natural alignment is read from; without one, load and store need the stated
// alignment.
pub fn new_builder(mut function Function, target ?TargetInfo) Builder {
	return Builder{
		function:      &function
		current_block: -1
		target:        target
	}
}

// param is function parameter `index`, a value in the entry block.
pub fn (b &Builder) param(index int) ValueRef {
	params := b.function.signature.params
	if index < 0 || index >= params.len {
		panic('param: the function takes ${params.len} parameters, so ${index} does not exist')
	}
	return ValueRef{
		idx: index
		typ: params[index]
	}
}

// create_entry_block creates the entry block, switches to it, and refuses a
// second entry block.
pub fn (mut b Builder) create_entry_block() int {
	if b.entry_created || b.function.blocks.len > 0 {
		panic('create_entry_block: the function already has an entry block')
	}
	b.entry_created = true
	block := b.create_block()
	b.current_block = block
	return block
}

// create_block creates a block without switching to it.
pub fn (mut b Builder) create_block() int {
	index := b.function.blocks.len
	b.function.blocks << Block{
		label: 'block${index}'
	}
	b.sealed << false
	b.defs << map[int]int{}
	b.boundary << map[int]int{}
	b.edges << []Edge{}
	b.pending << []int{}
	b.pending_vars << map[int]int{}
	return index
}

// switch_to_block moves the cursor. It refuses to leave a block without a
// terminator, and refuses a block that already has one.
pub fn (mut b Builder) switch_to_block(block int) {
	b.check_block(block, 'switch_to_block')
	if block == b.current_block {
		return
	}
	if b.current_block >= 0
		&& !b.function.blocks[b.current_block].terminator.opcode.is_terminator() {
		panic("switch_to_block: block '${b.function.blocks[b.current_block].label}' has no terminator")
	}
	if b.function.blocks[block].terminator.opcode.is_terminator() {
		panic("switch_to_block: block '${b.function.blocks[block].label}' already has its terminator")
	}
	b.current_block = block
}

// set_loc is the location the next instructions carry.
pub fn (mut b Builder) set_loc(loc SourceLoc) {
	b.current_loc = loc
}

pub fn (mut b Builder) clear_loc() {
	b.current_loc = none
}

// loc is the source location constructor ir-builder.md spells ir.loc.
pub fn loc(file string, line u32, col u32) SourceLoc {
	return SourceLoc{
		file: file
		line: line
		col:  col
	}
}

// create_stack_slot declares a slot on the function and returns its index.
pub fn (mut b Builder) create_stack_slot(size u32, align u16, name ?string) int {
	if size == 0 {
		panic('create_stack_slot: the slot has size 0')
	}
	if !is_power_of_two(int(align)) {
		panic('create_stack_slot: align ${align} is not a power of two greater than zero')
	}
	index := b.function.stack_slots.len
	b.function.stack_slots << StackSlot{
		size:  size
		align: align
		name:  name
	}
	return index
}

// finish is the end of the function. Every block has a terminator and every
// pending use is resolved, or the builder panics: an unresolved use has no
// value to hand a frontend.
pub fn (mut b Builder) finish() {
	for block in b.function.blocks {
		if !block.terminator.opcode.is_terminator() {
			panic("finish: block '${block.label}' has no terminator")
		}
	}
	for i in 0 .. b.pending.len {
		if b.pending[i].len > 0 {
			pending := b.pending_values[b.pending[i][0]]
			panic("finish: block '${b.function.blocks[i].label}' has an unresolved use of variable ${pending.variable}; seal the block first")
		}
	}
	b.finished = true
}

// Constants and values.

pub fn (mut b Builder) iconst(typ Type, imm u128) ValueRef {
	if !typ.is_int() {
		panic('iconst: ${typ.str()} is not an integer type')
	}
	mut inst := Instruction{
		opcode: .iconst
		typ:    typ
	}
	inst.operands << Operand{
		kind: .int_imm
		imm:  mask_int(imm, typ)
		idx:  -1
	}
	return b.push_inst('iconst', inst, [typ])[0]
}

pub fn (mut b Builder) fconst(typ Type, bits u128) ValueRef {
	if !typ.is_float() {
		panic('fconst: ${typ.str()} is not a float type')
	}
	mut inst := Instruction{
		opcode: .fconst
		typ:    typ
	}
	inst.operands << Operand{
		kind: .float_imm
		imm:  bits
		typ:  typ
		idx:  -1
	}
	return b.push_inst('fconst', inst, [typ])[0]
}

pub fn (mut b Builder) null() ValueRef {
	return b.push_inst('null', Instruction{ opcode: .null }, [ty_ptr])[0]
}

pub fn (mut b Builder) poison(typ Type) ValueRef {
	if !typ.is_scalar() {
		panic('poison: ${typ.str()} is not a scalar type')
	}
	mut inst := Instruction{
		opcode: .poison
		typ:    typ
	}
	return b.push_inst('poison', inst, [typ])[0]
}

pub fn (mut b Builder) freeze(value ValueRef) ValueRef {
	typ := b.value_type(value)
	mut inst := Instruction{
		opcode: .freeze
	}
	inst.operands << b.operand(value)
	return b.push_inst('freeze', inst, [typ])[0]
}

// Terminators.

pub fn (mut b Builder) br(block int, args []ValueRef) {
	mut inst := Instruction{
		opcode: .br
	}
	inst.target = b.jump_target(block, args, 'br')
	b.push_terminator('br', inst)
}

pub fn (mut b Builder) condbr(condition ValueRef, then_block int, then_args []ValueRef,
	else_block int, else_args []ValueRef) {
	b.expect(condition, ty_i1, 'condbr condition')
	mut inst := Instruction{
		opcode: .condbr
	}
	inst.operands << b.operand(condition)
	inst.target = b.jump_target(then_block, then_args, 'condbr')
	inst.else_target = b.jump_target(else_block, else_args, 'condbr')
	b.push_terminator('condbr', inst)
}

// Case is one arm of a switch: the constant, the block, and the arguments the
// jump passes.
pub struct Case {
pub:
	value u128
	block int
	args  []ValueRef
}

pub fn (mut b Builder) switch_(value ValueRef, default_block int, default_args []ValueRef,
	cases []Case) {
	typ := b.value_type(value)
	if !typ.is_int() {
		panic('switch_: the value has type ${typ.str()}, expected an integer')
	}
	mut inst := Instruction{
		opcode: .switch
	}
	inst.operands << b.operand(value)
	inst.target = b.jump_target(default_block, default_args, 'switch_')
	mut seen := []u128{}
	mut first := []int{}
	for i, case_ in cases {
		if !immediate_fits(case_.value, typ.bits) {
			panic('switch_: case ${i + 1} does not fit ${typ.str()}')
		}
		masked := mask_to(typ.bits, case_.value)
		for j, earlier in seen {
			if earlier == masked {
				panic('switch_: case ${i + 1} repeats case ${first[j] + 1}')
			}
		}
		seen << masked
		first << i
		inst.cases << SwitchCase{
			value:  case_.value
			target: b.jump_target(case_.block, case_.args, 'switch_')
		}
	}
	b.push_terminator('switch_', inst)
}

pub fn (mut b Builder) return_(values []ValueRef) {
	results := b.function.signature.results
	if values.len != results.len {
		panic("return_: 'return' passes ${values.len} values, and the function returns ${results.len}")
	}
	mut inst := Instruction{
		opcode: .@return
	}
	for i, value in values {
		b.expect(value, results[i], 'return_ value ${i + 1}')
		inst.operands << b.operand(value)
	}
	b.push_terminator('return_', inst)
}

pub fn (mut b Builder) unreachable() {
	b.push_terminator('unreachable', Instruction{ opcode: .unreachable })
}

pub fn (mut b Builder) trap(code u32) {
	mut inst := Instruction{
		opcode:    .trap
		trap_code: code
	}
	b.push_terminator('trap', inst)
}

// The instruction core.

fn (b &Builder) check_block(block int, site string) {
	if block < 0 || block >= b.function.blocks.len {
		panic('${site}: the function has ${b.function.blocks.len} blocks, so block ${block} does not exist')
	}
}

fn (mut b Builder) check_can_emit(site string) {
	if b.current_block < 0 {
		panic('${site}: the builder has no current block; call create_entry_block or switch_to_block first')
	}
	if b.function.blocks[b.current_block].terminator.opcode.is_terminator() {
		panic("${site}: block '${b.function.blocks[b.current_block].label}' already has its terminator")
	}
}

fn (mut b Builder) push_value(typ Type, kind ValueKind, block int, inst int) int {
	index := b.function.values.len
	b.function.values << Value{
		typ:   typ
		kind:  kind
		block: block
		inst:  inst
	}
	return index
}

// push_inst appends an instruction to the current block, with one value per
// result, and returns the handles in result order.
fn (mut b Builder) push_inst(site string, inst Instruction, results []Type) []ValueRef {
	b.check_can_emit(site)
	block := b.current_block
	mut built := inst
	built.loc = b.current_loc
	built.results = []int{cap: results.len}
	mut handles := []ValueRef{cap: results.len}
	for typ in results {
		index := b.push_value(typ, .instruction_result, block,
			b.function.blocks[block].instructions.len)
		built.results << index
		handles << ValueRef{
			idx: index
			typ: typ
		}
	}
	b.record_uses(block, b.function.blocks[block].instructions.len, built)
	b.function.blocks[block].instructions << built
	return handles
}

fn (mut b Builder) push_terminator(site string, inst Instruction) {
	b.check_can_emit(site)
	block := b.current_block
	mut built := inst
	built.loc = b.current_loc
	b.record_uses(block, -1, built)
	b.record_edges(block, built)
	b.function.blocks[block].terminator = built
}

fn (mut b Builder) jump_target(block int, args []ValueRef, site string) BlockTarget {
	b.check_block(block, site)
	mut target := BlockTarget{
		label: b.function.blocks[block].label
		block: block
	}
	for arg in args {
		target.args << b.operand(arg)
	}
	return target
}

fn (b &Builder) operand(value ValueRef) Operand {
	return Operand{
		kind: .value
		idx:  value.idx
	}
}

fn (mut b Builder) record_edges(block int, inst Instruction) {
	match inst.opcode {
		.br {
			b.add_edge(inst.target.block, Edge{
				block: block
				which: 0
			})
		}
		.condbr {
			b.add_edge(inst.target.block, Edge{
				block: block
				which: 1
			})
			b.add_edge(inst.else_target.block, Edge{
				block: block
				which: 2
			})
		}
		.switch {
			b.add_edge(inst.target.block, Edge{
				block: block
				which: 3
			})
			for i, case_ in inst.cases {
				b.add_edge(case_.target.block, Edge{
					block: block
					which: 4 + i
				})
			}
		}
		else {}
	}
}

fn (mut b Builder) add_edge(target int, edge Edge) {
	b.edges[target] << edge
}

// target_which is the terminator target the main `target` field is: br and the
// switch default are 0 and 3, and condbr's first arm is 1.
fn target_which(op Opcode) int {
	return match op {
		.condbr { 1 }
		.switch { 3 }
		else { 0 }
	}
}

fn (mut b Builder) record_uses(block int, inst_index int, inst Instruction) {
	which := target_which(inst.opcode)
	for i, operand in inst.operands {
		b.record_use(operand, UseSite{
			block: block
			inst:  inst_index
			kind:  .operand
			which: 0
			index: i
		})
	}
	for i, input in inst.asm.inputs {
		b.record_use(input.value, UseSite{
			block: block
			inst:  inst_index
			kind:  .asm_input
			which: 0
			index: i
		})
	}
	for i, arg in inst.target.args {
		b.record_use(arg, UseSite{
			block: block
			inst:  inst_index
			kind:  .jump_arg
			which: which
			index: i
		})
	}
	for i, arg in inst.else_target.args {
		b.record_use(arg, UseSite{
			block: block
			inst:  inst_index
			kind:  .jump_arg
			which: 2
			index: i
		})
	}
	for c, case_ in inst.cases {
		for i, arg in case_.target.args {
			b.record_use(arg, UseSite{
				block: block
				inst:  inst_index
				kind:  .jump_arg
				which: 4 + c
				index: i
			})
		}
	}
}

fn (mut b Builder) record_use(operand Operand, site UseSite) {
	if operand.kind != .value || operand.idx >= 0 {
		return
	}
	index := pending_index(operand.idx)
	if index < 0 || index >= b.pending_values.len {
		panic('the operand names a value this builder never made')
	}
	b.pending_values[index].sites << site
}

// pending_index turns the negative index a pending handle carries back into its
// slot in pending_values. -1 belongs to the text form's unresolved operand, so
// pending handles start at -2.
fn pending_index(idx int) int {
	return -idx - 2
}

// value_type is the type of a handle: the table's entry when it has one, and
// the pending value's stated type when it does not.
fn (b &Builder) value_type(value ValueRef) Type {
	if value.idx >= 0 {
		if value.idx >= b.function.values.len {
			panic('the value index ${value.idx} is outside the function value table')
		}
		return b.function.values[value.idx].typ
	}
	index := pending_index(value.idx)
	if index < 0 || index >= b.pending_values.len {
		panic('the value names a pending use this builder never made')
	}
	return b.pending_values[index].typ
}

fn (mut b Builder) expect(value ValueRef, want Type, site string) {
	got := b.value_type(value)
	if got != want {
		panic('${site}: value ${value.idx} has type ${got.str()}, expected ${want.str()}')
	}
}

// natural_align is the alignment a memory operation gets when the frontend does
// not state one: the size of a scalar, and the pointer alignment of a pointer.
fn (b &Builder) natural_align(typ Type, site string) u16 {
	if typ.is_ptr() {
		target := b.target or {
			panic('${site}: the builder has no target, so it cannot choose a natural alignment for a pointer; state the alignment or pass a target to new_builder')
		}
		return target.pointer_align
	}
	return u16(typ.size(0))
}
