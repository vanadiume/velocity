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

// Flags.

// Flag is one of the promises an instruction can carry. flags() turns a list of
// them into the set an instruction holds.
pub enum Flag {
	nsw
	nuw
	exact
	inbounds
	volatile
}

pub fn flags(list ...Flag) FlagSet {
	mut set := FlagSet{}
	for flag in list {
		match flag {
			.nsw { set.nsw = true }
			.nuw { set.nuw = true }
			.exact { set.exact = true }
			.inbounds { set.inbounds = true }
			.volatile { set.volatile = true }
		}
	}
	return set
}

fn (mut b Builder) check_flags(op Opcode, set FlagSet, site string) {
	if set.nsw && !accepts_flag(op, 'nsw') {
		panic("${site}: '${op.name()}' does not accept the nsw flag")
	}
	if set.nuw && !accepts_flag(op, 'nuw') {
		panic("${site}: '${op.name()}' does not accept the nuw flag")
	}
	if set.exact && !accepts_flag(op, 'exact') {
		panic("${site}: '${op.name()}' does not accept the exact flag")
	}
	if set.inbounds && !accepts_flag(op, 'inbounds') {
		panic("${site}: '${op.name()}' does not accept the inbounds flag")
	}
	if set.volatile && !accepts_flag(op, 'volatile') {
		panic("${site}: '${op.name()}' does not accept the volatile flag")
	}
}

// Integer arithmetic.

fn (mut b Builder) int_binop(site string, op Opcode, a ValueRef, c ValueRef, set FlagSet) ValueRef {
	b.check_flags(op, set, site)
	typ := b.value_type(a)
	if !typ.is_int() {
		panic('${site}: value ${a.idx} has type ${typ.str()}, expected an integer')
	}
	b.expect(c, typ, site)
	mut inst := Instruction{
		opcode: op
		flags:  set
	}
	inst.operands << b.operand(a)
	inst.operands << b.operand(c)
	return b.push_inst(site, inst, [typ])[0]
}

fn (mut b Builder) int_unop(site string, op Opcode, value ValueRef, set FlagSet) ValueRef {
	b.check_flags(op, set, site)
	typ := b.value_type(value)
	if !typ.is_int() {
		panic('${site}: value ${value.idx} has type ${typ.str()}, expected an integer')
	}
	mut inst := Instruction{
		opcode: op
		flags:  set
	}
	inst.operands << b.operand(value)
	return b.push_inst(site, inst, [typ])[0]
}

fn (mut b Builder) int_overflow(site string, op Opcode, a ValueRef, c ValueRef) OverflowPair {
	typ := b.value_type(a)
	if !typ.is_int() {
		panic('${site}: value ${a.idx} has type ${typ.str()}, expected an integer')
	}
	b.expect(c, typ, site)
	mut inst := Instruction{
		opcode: op
	}
	inst.operands << b.operand(a)
	inst.operands << b.operand(c)
	results := b.push_inst(site, inst, [typ, ty_i1])
	return OverflowPair{
		value: results[0]
		flag:  results[1]
	}
}

// OverflowPair is the wrapped result and the overflow flag an overflow opcode
// produces.
pub struct OverflowPair {
pub:
	value ValueRef
	flag  ValueRef
}

pub fn (mut b Builder) iadd(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('iadd', .iadd, a, c, FlagSet{})
}

pub fn (mut b Builder) iadd_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('iadd', .iadd, a, c, set)
}

pub fn (mut b Builder) isub(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('isub', .isub, a, c, FlagSet{})
}

pub fn (mut b Builder) isub_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('isub', .isub, a, c, set)
}

pub fn (mut b Builder) imul(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('imul', .imul, a, c, FlagSet{})
}

pub fn (mut b Builder) imul_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('imul', .imul, a, c, set)
}

pub fn (mut b Builder) sdiv(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('sdiv', .sdiv, a, c, FlagSet{})
}

pub fn (mut b Builder) sdiv_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('sdiv', .sdiv, a, c, set)
}

pub fn (mut b Builder) udiv(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('udiv', .udiv, a, c, FlagSet{})
}

pub fn (mut b Builder) udiv_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('udiv', .udiv, a, c, set)
}

pub fn (mut b Builder) srem(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('srem', .srem, a, c, FlagSet{})
}

pub fn (mut b Builder) srem_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('srem', .srem, a, c, set)
}

pub fn (mut b Builder) urem(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('urem', .urem, a, c, FlagSet{})
}

pub fn (mut b Builder) urem_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('urem', .urem, a, c, set)
}

pub fn (mut b Builder) ineg(value ValueRef) ValueRef {
	return b.int_unop('ineg', .ineg, value, FlagSet{})
}

pub fn (mut b Builder) ineg_flags(value ValueRef, set FlagSet) ValueRef {
	return b.int_unop('ineg', .ineg, value, set)
}

pub fn (mut b Builder) iabs(value ValueRef) ValueRef {
	return b.int_unop('iabs', .iabs, value, FlagSet{})
}

pub fn (mut b Builder) smin(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('smin', .smin, a, c, FlagSet{})
}

pub fn (mut b Builder) smax(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('smax', .smax, a, c, FlagSet{})
}

pub fn (mut b Builder) umin(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('umin', .umin, a, c, FlagSet{})
}

pub fn (mut b Builder) umax(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('umax', .umax, a, c, FlagSet{})
}

pub fn (mut b Builder) sadd_overflow(a ValueRef, c ValueRef) OverflowPair {
	return b.int_overflow('sadd_overflow', .sadd_overflow, a, c)
}

pub fn (mut b Builder) uadd_overflow(a ValueRef, c ValueRef) OverflowPair {
	return b.int_overflow('uadd_overflow', .uadd_overflow, a, c)
}

pub fn (mut b Builder) ssub_overflow(a ValueRef, c ValueRef) OverflowPair {
	return b.int_overflow('ssub_overflow', .ssub_overflow, a, c)
}

pub fn (mut b Builder) usub_overflow(a ValueRef, c ValueRef) OverflowPair {
	return b.int_overflow('usub_overflow', .usub_overflow, a, c)
}

pub fn (mut b Builder) smul_overflow(a ValueRef, c ValueRef) OverflowPair {
	return b.int_overflow('smul_overflow', .smul_overflow, a, c)
}

pub fn (mut b Builder) umul_overflow(a ValueRef, c ValueRef) OverflowPair {
	return b.int_overflow('umul_overflow', .umul_overflow, a, c)
}

pub fn (mut b Builder) sadd_sat(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('sadd_sat', .sadd_sat, a, c, FlagSet{})
}

pub fn (mut b Builder) uadd_sat(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('uadd_sat', .uadd_sat, a, c, FlagSet{})
}

pub fn (mut b Builder) ssub_sat(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('ssub_sat', .ssub_sat, a, c, FlagSet{})
}

pub fn (mut b Builder) usub_sat(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('usub_sat', .usub_sat, a, c, FlagSet{})
}

pub fn (mut b Builder) smul_sat(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('smul_sat', .smul_sat, a, c, FlagSet{})
}

pub fn (mut b Builder) umul_sat(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('umul_sat', .umul_sat, a, c, FlagSet{})
}

// Bitwise and shifts.

pub fn (mut b Builder) band(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('band', .band, a, c, FlagSet{})
}

pub fn (mut b Builder) bor(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('bor', .bor, a, c, FlagSet{})
}

pub fn (mut b Builder) bxor(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('bxor', .bxor, a, c, FlagSet{})
}

pub fn (mut b Builder) bnot(value ValueRef) ValueRef {
	return b.int_unop('bnot', .bnot, value, FlagSet{})
}

pub fn (mut b Builder) shl(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('shl', .shl, a, c, FlagSet{})
}

pub fn (mut b Builder) shl_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('shl', .shl, a, c, set)
}

pub fn (mut b Builder) sshr(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('sshr', .sshr, a, c, FlagSet{})
}

pub fn (mut b Builder) sshr_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('sshr', .sshr, a, c, set)
}

pub fn (mut b Builder) ushr(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('ushr', .ushr, a, c, FlagSet{})
}

pub fn (mut b Builder) ushr_flags(a ValueRef, c ValueRef, set FlagSet) ValueRef {
	return b.int_binop('ushr', .ushr, a, c, set)
}

pub fn (mut b Builder) rotl(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('rotl', .rotl, a, c, FlagSet{})
}

pub fn (mut b Builder) rotr(a ValueRef, c ValueRef) ValueRef {
	return b.int_binop('rotr', .rotr, a, c, FlagSet{})
}

pub fn (mut b Builder) clz(value ValueRef) ValueRef {
	return b.int_unop('clz', .clz, value, FlagSet{})
}

pub fn (mut b Builder) ctz(value ValueRef) ValueRef {
	return b.int_unop('ctz', .ctz, value, FlagSet{})
}

pub fn (mut b Builder) popcnt(value ValueRef) ValueRef {
	return b.int_unop('popcnt', .popcnt, value, FlagSet{})
}

pub fn (mut b Builder) bswap(value ValueRef) ValueRef {
	typ := b.value_type(value)
	if typ.is_int() && typ.bits % 8 != 0 {
		panic("bswap: 'bswap' operates on ${typ.str()}, expected a width that is a multiple of 8")
	}
	return b.int_unop('bswap', .bswap, value, FlagSet{})
}

// Comparisons.

pub enum IntPredicate {
	eq
	ne
	slt
	sle
	sgt
	sge
	ult
	ule
	ugt
	uge
}

pub enum FloatPredicate {
	oeq
	one
	olt
	ole
	ogt
	oge
	ueq
	une
	ult
	ule
	ugt
	uge
	ord
	uno
}

pub fn (mut b Builder) icmp(predicate IntPredicate, a ValueRef, c ValueRef) ValueRef {
	typ := b.value_type(a)
	if !typ.is_int() && !typ.is_ptr() {
		panic('icmp: value ${a.idx} has type ${typ.str()}, expected an integer or a pointer')
	}
	b.expect(c, typ, 'icmp')
	if typ.is_ptr() && predicate !in [.eq, .ne, .ult, .ule, .ugt, .uge] {
		panic("icmp: 'icmp ${predicate.str()}' is not defined on pointers; only eq, ne, ult, ule, ugt and uge are")
	}
	mut inst := Instruction{
		opcode:    .icmp
		predicate: predicate.str()
	}
	inst.operands << b.operand(a)
	inst.operands << b.operand(c)
	return b.push_inst('icmp', inst, [ty_i1])[0]
}

pub fn (mut b Builder) fcmp(predicate FloatPredicate, a ValueRef, c ValueRef) ValueRef {
	typ := b.value_type(a)
	if !typ.is_float() {
		panic('fcmp: value ${a.idx} has type ${typ.str()}, expected a float')
	}
	b.expect(c, typ, 'fcmp')
	mut inst := Instruction{
		opcode:    .fcmp
		predicate: predicate.str()
	}
	inst.operands << b.operand(a)
	inst.operands << b.operand(c)
	return b.push_inst('fcmp', inst, [ty_i1])[0]
}

// Floating point.

fn (mut b Builder) float_binop(site string, op Opcode, a ValueRef, c ValueRef) ValueRef {
	typ := b.value_type(a)
	if !typ.is_float() {
		panic('${site}: value ${a.idx} has type ${typ.str()}, expected a float')
	}
	b.expect(c, typ, site)
	mut inst := Instruction{
		opcode: op
	}
	inst.operands << b.operand(a)
	inst.operands << b.operand(c)
	return b.push_inst(site, inst, [typ])[0]
}

fn (mut b Builder) float_unop(site string, op Opcode, value ValueRef) ValueRef {
	typ := b.value_type(value)
	if !typ.is_float() {
		panic('${site}: value ${value.idx} has type ${typ.str()}, expected a float')
	}
	mut inst := Instruction{
		opcode: op
	}
	inst.operands << b.operand(value)
	return b.push_inst(site, inst, [typ])[0]
}

pub fn (mut b Builder) fadd(a ValueRef, c ValueRef) ValueRef {
	return b.float_binop('fadd', .fadd, a, c)
}

pub fn (mut b Builder) fsub(a ValueRef, c ValueRef) ValueRef {
	return b.float_binop('fsub', .fsub, a, c)
}

pub fn (mut b Builder) fmul(a ValueRef, c ValueRef) ValueRef {
	return b.float_binop('fmul', .fmul, a, c)
}

pub fn (mut b Builder) fdiv(a ValueRef, c ValueRef) ValueRef {
	return b.float_binop('fdiv', .fdiv, a, c)
}

pub fn (mut b Builder) frem(a ValueRef, c ValueRef) ValueRef {
	return b.float_binop('frem', .frem, a, c)
}

pub fn (mut b Builder) fcopysign(a ValueRef, c ValueRef) ValueRef {
	return b.float_binop('fcopysign', .fcopysign, a, c)
}

pub fn (mut b Builder) fmin(a ValueRef, c ValueRef) ValueRef {
	return b.float_binop('fmin', .fmin, a, c)
}

pub fn (mut b Builder) fmax(a ValueRef, c ValueRef) ValueRef {
	return b.float_binop('fmax', .fmax, a, c)
}

pub fn (mut b Builder) fma(a ValueRef, c ValueRef, d ValueRef) ValueRef {
	typ := b.value_type(a)
	if !typ.is_float() {
		panic('fma: value ${a.idx} has type ${typ.str()}, expected a float')
	}
	b.expect(c, typ, 'fma')
	b.expect(d, typ, 'fma')
	mut inst := Instruction{
		opcode: .fma
	}
	inst.operands << b.operand(a)
	inst.operands << b.operand(c)
	inst.operands << b.operand(d)
	return b.push_inst('fma', inst, [typ])[0]
}

pub fn (mut b Builder) fneg(value ValueRef) ValueRef {
	return b.float_unop('fneg', .fneg, value)
}

pub fn (mut b Builder) fabs(value ValueRef) ValueRef {
	return b.float_unop('fabs', .fabs, value)
}

pub fn (mut b Builder) fsqrt(value ValueRef) ValueRef {
	return b.float_unop('fsqrt', .fsqrt, value)
}

pub fn (mut b Builder) fceil(value ValueRef) ValueRef {
	return b.float_unop('fceil', .fceil, value)
}

pub fn (mut b Builder) ffloor(value ValueRef) ValueRef {
	return b.float_unop('ffloor', .ffloor, value)
}

pub fn (mut b Builder) ftrunc(value ValueRef) ValueRef {
	return b.float_unop('ftrunc', .ftrunc, value)
}

pub fn (mut b Builder) fnearest(value ValueRef) ValueRef {
	return b.float_unop('fnearest', .fnearest, value)
}

// Conversions.

fn (b &Builder) pointer_width(site string) u16 {
	target := b.target or {
		panic('${site}: the builder has no target, so it does not know the pointer width')
	}
	return target.pointer_width
}

fn (mut b Builder) convert(site string, op Opcode, value ValueRef, to Type) ValueRef {
	mut inst := Instruction{
		opcode: op
		typ:    to
	}
	inst.operands << b.operand(value)
	return b.push_inst(site, inst, [to])[0]
}

pub fn (mut b Builder) sext(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_int() || !to.is_int() {
		panic('sext: from ${from.str()} to ${to.str()}, expected integers')
	}
	if to.bits <= from.bits {
		panic('sext: from ${from.str()} to ${to.str()}, expected a wider result')
	}
	return b.convert('sext', .sext, value, to)
}

pub fn (mut b Builder) zext(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_int() || !to.is_int() {
		panic('zext: from ${from.str()} to ${to.str()}, expected integers')
	}
	if to.bits <= from.bits {
		panic('zext: from ${from.str()} to ${to.str()}, expected a wider result')
	}
	return b.convert('zext', .zext, value, to)
}

pub fn (mut b Builder) trunc(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_int() || !to.is_int() {
		panic('trunc: from ${from.str()} to ${to.str()}, expected integers')
	}
	if to.bits >= from.bits {
		panic('trunc: from ${from.str()} to ${to.str()}, expected a narrower result')
	}
	return b.convert('trunc', .trunc, value, to)
}

pub fn (mut b Builder) bitcast(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if from.is_ptr() {
		panic('bitcast: the operand has type ptr; use ptrtoint')
	}
	if to.is_ptr() {
		panic('bitcast: the result is ptr; use inttoptr')
	}
	if from.bit_size(0) != to.bit_size(0) {
		panic('bitcast: from ${from.str()} to ${to.str()}, expected equal bit widths')
	}
	return b.convert('bitcast', .bitcast, value, to)
}

pub fn (mut b Builder) ptrtoint(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_ptr() {
		panic('ptrtoint: the operand has type ${from.str()}, expected ptr')
	}
	width := b.pointer_width('ptrtoint')
	if !to.is_int() {
		panic('ptrtoint: the result is ${to.str()}, expected an integer')
	}
	if to.bits != width {
		panic('ptrtoint: the result is ${to.str()}, expected the pointer width i${width}')
	}
	return b.convert('ptrtoint', .ptrtoint, value, to)
}

pub fn (mut b Builder) inttoptr(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_int() {
		panic('inttoptr: the operand has type ${from.str()}, expected an integer')
	}
	width := b.pointer_width('inttoptr')
	if from.bits != width {
		panic('inttoptr: the operand is ${from.str()}, expected the pointer width i${width}')
	}
	if !to.is_ptr() {
		panic('inttoptr: the result is ${to.str()}, expected ptr')
	}
	return b.convert('inttoptr', .inttoptr, value, to)
}

pub fn (mut b Builder) sitofp(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_int() || !to.is_float() {
		panic('sitofp: from ${from.str()} to ${to.str()}, expected an integer to a float')
	}
	return b.convert('sitofp', .sitofp, value, to)
}

pub fn (mut b Builder) uitofp(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_int() || !to.is_float() {
		panic('uitofp: from ${from.str()} to ${to.str()}, expected an integer to a float')
	}
	return b.convert('uitofp', .uitofp, value, to)
}

pub fn (mut b Builder) fptosi(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_float() || !to.is_int() {
		panic('fptosi: from ${from.str()} to ${to.str()}, expected a float to an integer')
	}
	return b.convert('fptosi', .fptosi, value, to)
}

pub fn (mut b Builder) fptoui(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_float() || !to.is_int() {
		panic('fptoui: from ${from.str()} to ${to.str()}, expected a float to an integer')
	}
	return b.convert('fptoui', .fptoui, value, to)
}

pub fn (mut b Builder) fpext(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_float() || !to.is_float() {
		panic('fpext: from ${from.str()} to ${to.str()}, expected floats')
	}
	if to.bits <= from.bits {
		panic('fpext: from ${from.str()} to ${to.str()}, expected a wider result')
	}
	return b.convert('fpext', .fpext, value, to)
}

pub fn (mut b Builder) fptrunc(value ValueRef, to Type) ValueRef {
	from := b.value_type(value)
	if !from.is_float() || !to.is_float() {
		panic('fptrunc: from ${from.str()} to ${to.str()}, expected floats')
	}
	if to.bits >= from.bits {
		panic('fptrunc: from ${from.str()} to ${to.str()}, expected a narrower result')
	}
	return b.convert('fptrunc', .fptrunc, value, to)
}

// Selection.

pub fn (mut b Builder) select(condition ValueRef, a ValueRef, c ValueRef) ValueRef {
	b.expect(condition, ty_i1, 'select condition')
	typ := b.value_type(a)
	if !typ.is_scalar() {
		panic('select: value ${a.idx} has type ${typ.str()}, expected a scalar')
	}
	b.expect(c, typ, 'select')
	mut inst := Instruction{
		opcode: .@select
	}
	inst.operands << b.operand(condition)
	inst.operands << b.operand(a)
	inst.operands << b.operand(c)
	return b.push_inst('select', inst, [typ])[0]
}

// Memory.

fn (b &Builder) check_align(align u16, site string) {
	if !is_power_of_two(int(align)) {
		panic('${site}: align ${align} is not a power of two greater than zero')
	}
}

fn (mut b Builder) load_with(site string, pointer ValueRef, typ Type, align u16, set FlagSet) ValueRef {
	b.expect(pointer, ty_ptr, site)
	if !typ.is_memory() {
		panic('${site}: the result is ${typ.str()}, expected a byte-sized type')
	}
	b.check_align(align, site)
	b.check_flags(.load, set, site)
	mut inst := Instruction{
		opcode: .load
		typ:    typ
		align:  align
		flags:  set
	}
	inst.operands << b.operand(pointer)
	return b.push_inst(site, inst, [typ])[0]
}

pub fn (mut b Builder) load(pointer ValueRef, typ Type) ValueRef {
	return b.load_with('load', pointer, typ, b.natural_align(typ, 'load'), FlagSet{})
}

pub fn (mut b Builder) load_aligned(pointer ValueRef, typ Type, align u16) ValueRef {
	return b.load_with('load_aligned', pointer, typ, align, FlagSet{})
}

pub fn (mut b Builder) load_volatile(pointer ValueRef, typ Type) ValueRef {
	return b.load_with('load_volatile', pointer, typ, b.natural_align(typ, 'load_volatile'),
		flags(.volatile))
}

pub fn (mut b Builder) load_volatile_aligned(pointer ValueRef, typ Type, align u16) ValueRef {
	return b.load_with('load_volatile_aligned', pointer, typ, align, flags(.volatile))
}

fn (mut b Builder) store_with(site string, pointer ValueRef, value ValueRef, align u16,
	set FlagSet) {
	b.expect(pointer, ty_ptr, site)
	typ := b.value_type(value)
	if !typ.is_memory() {
		panic('${site}: the value has type ${typ.str()}, expected a byte-sized type')
	}
	b.check_align(align, site)
	b.check_flags(.store, set, site)
	mut inst := Instruction{
		opcode: .store
		align:  align
		flags:  set
	}
	inst.operands << b.operand(pointer)
	inst.operands << b.operand(value)
	b.push_inst(site, inst, [])
}

pub fn (mut b Builder) store(pointer ValueRef, value ValueRef) {
	typ := b.value_type(value)
	b.store_with('store', pointer, value, b.natural_align(typ, 'store'), FlagSet{})
}

pub fn (mut b Builder) store_aligned(pointer ValueRef, value ValueRef, align u16) {
	b.store_with('store_aligned', pointer, value, align, FlagSet{})
}

pub fn (mut b Builder) store_volatile(pointer ValueRef, value ValueRef) {
	typ := b.value_type(value)
	b.store_with('store_volatile', pointer, value, b.natural_align(typ, 'store_volatile'),
		flags(.volatile))
}

pub fn (mut b Builder) store_volatile_aligned(pointer ValueRef, value ValueRef, align u16) {
	b.store_with('store_volatile_aligned', pointer, value, align, flags(.volatile))
}

fn (mut b Builder) ptradd_with(site string, pointer ValueRef, offset ValueRef, set FlagSet) ValueRef {
	b.expect(pointer, ty_ptr, site)
	typ := b.value_type(offset)
	if !typ.is_int() {
		panic('${site}: the offset has type ${typ.str()}, expected an integer')
	}
	b.check_flags(.ptradd, set, site)
	mut inst := Instruction{
		opcode: .ptradd
		flags:  set
	}
	inst.operands << b.operand(pointer)
	inst.operands << b.operand(offset)
	return b.push_inst(site, inst, [ty_ptr])[0]
}

pub fn (mut b Builder) ptradd(pointer ValueRef, offset ValueRef) ValueRef {
	return b.ptradd_with('ptradd', pointer, offset, FlagSet{})
}

pub fn (mut b Builder) ptradd_flags(pointer ValueRef, offset ValueRef, set FlagSet) ValueRef {
	return b.ptradd_with('ptradd', pointer, offset, set)
}

fn (mut b Builder) copy_memory(site string, op Opcode, dst ValueRef, src ValueRef, len ValueRef,
	align_dst u16, align_src u16) {
	b.expect(dst, ty_ptr, '${site} dst')
	b.expect(src, ty_ptr, '${site} src')
	typ := b.value_type(len)
	if !typ.is_int() {
		panic('${site}: the length has type ${typ.str()}, expected an integer')
	}
	b.check_align(align_dst, '${site} dst')
	b.check_align(align_src, '${site} src')
	mut inst := Instruction{
		opcode:    op
		align_dst: align_dst
		align_src: align_src
	}
	inst.operands << b.operand(dst)
	inst.operands << b.operand(src)
	inst.operands << b.operand(len)
	b.push_inst(site, inst, [])
}

pub fn (mut b Builder) memcpy(dst ValueRef, src ValueRef, len ValueRef, align_dst u16,
	align_src u16) {
	b.copy_memory('memcpy', .memcpy, dst, src, len, align_dst, align_src)
}

pub fn (mut b Builder) memmove(dst ValueRef, src ValueRef, len ValueRef, align_dst u16,
	align_src u16) {
	b.copy_memory('memmove', .memmove, dst, src, len, align_dst, align_src)
}

pub fn (mut b Builder) memset(dst ValueRef, value ValueRef, len ValueRef, align u16) {
	b.expect(dst, ty_ptr, 'memset dst')
	b.expect(value, ty_i8, 'memset value')
	typ := b.value_type(len)
	if !typ.is_int() {
		panic('memset: the length has type ${typ.str()}, expected an integer')
	}
	b.check_align(align, 'memset')
	mut inst := Instruction{
		opcode: .memset
		align:  align
	}
	inst.operands << b.operand(dst)
	inst.operands << b.operand(value)
	inst.operands << b.operand(len)
	b.push_inst('memset', inst, [])
}

pub fn (mut b Builder) stack_addr(slot int) ValueRef {
	if slot < 0 || slot >= b.function.stack_slots.len {
		panic('stack_addr: the function declares ${b.function.stack_slots.len} stack slots, so slot ${slot} does not exist')
	}
	mut inst := Instruction{
		opcode: .stack_addr
	}
	inst.operands << Operand{
		kind: .stack_slot
		name: b.function.stack_slots[slot].name or { '' }
		idx:  slot
	}
	return b.push_inst('stack_addr', inst, [ty_ptr])[0]
}

pub fn (mut b Builder) global_addr(name string) ValueRef {
	return b.symbol_address('global_addr', .global_addr, .global, name)
}

pub fn (mut b Builder) func_addr(name string) ValueRef {
	return b.symbol_address('func_addr', .func_addr, .function, name)
}

fn (mut b Builder) symbol_address(site string, op Opcode, kind SymbolKind, name string) ValueRef {
	if name == '' {
		panic('${site}: the symbol has no name')
	}
	mut inst := Instruction{
		opcode: op
	}
	inst.operands << Operand{
		kind: .symbol
		name: name
		sym:  kind
		idx:  -1
	}
	return b.push_inst(site, inst, [ty_ptr])[0]
}

// Calls.

fn (mut b Builder) check_arguments(site string, signature Signature, args []ValueRef) {
	if args.len != signature.params.len {
		panic('${site}: the call passes ${args.len} arguments, and the signature takes ${signature.params.len}')
	}
	for i, arg in args {
		b.expect(arg, signature.params[i], '${site} argument ${i + 1}')
	}
}

pub fn (mut b Builder) call(callee string, signature Signature, args []ValueRef) []ValueRef {
	b.check_arguments('call', signature, args)
	mut inst := Instruction{
		opcode: .call
	}
	inst.operands << Operand{
		kind: .symbol
		name: callee
		sym:  .function
		idx:  -1
	}
	for arg in args {
		inst.operands << b.operand(arg)
	}
	return b.push_inst('call', inst, signature.results)
}

pub fn (mut b Builder) call_indirect(pointer ValueRef, signature Signature, args []ValueRef) []ValueRef {
	b.expect(pointer, ty_ptr, 'call_indirect pointer')
	b.check_arguments('call_indirect', signature, args)
	mut inst := Instruction{
		opcode:    .call_indirect
		signature: signature
	}
	inst.operands << b.operand(pointer)
	for arg in args {
		inst.operands << b.operand(arg)
	}
	return b.push_inst('call_indirect', inst, signature.results)
}

fn (mut b Builder) check_tail_signature(site string, signature Signature) {
	if signature.results != b.function.signature.results {
		panic('${site}: the callee returns ${signature.results.len} results, and the function returns ${b.function.signature.results.len}')
	}
}

pub fn (mut b Builder) tailcall(callee string, signature Signature, args []ValueRef) {
	b.check_arguments('tailcall', signature, args)
	b.check_tail_signature('tailcall', signature)
	mut inst := Instruction{
		opcode: .tailcall
	}
	inst.operands << Operand{
		kind: .symbol
		name: callee
		sym:  .function
		idx:  -1
	}
	for arg in args {
		inst.operands << b.operand(arg)
	}
	b.push_terminator('tailcall', inst)
}

pub fn (mut b Builder) tailcall_indirect(pointer ValueRef, signature Signature, args []ValueRef) {
	b.expect(pointer, ty_ptr, 'tailcall_indirect pointer')
	b.check_arguments('tailcall_indirect', signature, args)
	b.check_tail_signature('tailcall_indirect', signature)
	mut inst := Instruction{
		opcode:    .tailcall_indirect
		signature: signature
	}
	inst.operands << b.operand(pointer)
	for arg in args {
		inst.operands << b.operand(arg)
	}
	b.push_terminator('tailcall_indirect', inst)
}

pub fn (mut b Builder) assume(condition ValueRef) {
	b.expect(condition, ty_i1, 'assume condition')
	mut inst := Instruction{
		opcode: .assume
	}
	inst.operands << b.operand(condition)
	b.push_inst('assume', inst, [])
}

// Inline asm.

pub struct AsmOutput {
pub:
	typ        Type
	constraint string
}

pub struct AsmInput {
pub:
	value      ValueRef
	constraint string
}

// Asm is the inline asm an instruction carries: a template, its outputs and
// inputs with their constraints, and the flags the clauses name.
pub struct Asm {
pub:
	template   string
	outputs    []AsmOutput
	inputs     []AsmInput
	clobbers   []string
	volatile   bool
	alignstack bool
	intel      bool
}

pub fn (mut b Builder) inline_asm(spec Asm) []ValueRef {
	if spec.template == '' {
		panic('inline_asm: the template is empty')
	}
	mut inst := Instruction{
		opcode: .inline_asm
	}
	inst.asm = InlineAsm{
		template:   spec.template
		clobbers:   spec.clobbers
		volatile:   spec.volatile
		alignstack: spec.alignstack
		intel:      spec.intel
	}
	mut results := []Type{cap: spec.outputs.len}
	for i, output in spec.outputs {
		if !output.typ.is_scalar() {
			panic('inline_asm: output ${i + 1} has type ${output.typ.str()}, expected a scalar')
		}
		if output.constraint == '' {
			panic('inline_asm: output ${i + 1} names no constraint')
		}
		inst.asm.outputs << InlineAsmOutput{
			typ:        output.typ
			constraint: output.constraint
		}
		results << output.typ
	}
	for i, input in spec.inputs {
		if input.constraint == '' {
			panic('inline_asm: input ${i + 1} names no constraint')
		}
		_ = b.value_type(input.value)
		inst.asm.inputs << InlineAsmInput{
			value:      b.operand(input.value)
			constraint: input.constraint
		}
	}
	return b.push_inst('inline_asm', inst, results)
}
