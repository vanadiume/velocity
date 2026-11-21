module ir

import os

// The canonical text form in ir-text.md, read into the model. The parser
// reports the line and the column and never panics on malformed input. It does
// not check dominance, jump arity, block reachability or types: those are the
// verifier's rules, so a function whose operands disagree still parses.

pub struct ParseError {
pub:
	line    int
	col     int
	message string
}

pub fn (e ParseError) msg() string {
	return 'line ${e.line}, column ${e.col}: ${e.message}'
}

// code is what IError asks for; a parse error has no code of its own, so V's
// default is what every parse failure carries.
pub fn (e ParseError) code() int {
	return 1
}

// parse_text reads a whole module.
pub fn parse_text(text string) !Module {
	tokens := tokenize(text)!
	mut parser := Parser{
		tokens: tokens
	}
	return parser.parse_module()
}

pub fn parse_file(path string) !Module {
	text := os.read_file(path)!
	return parse_text(text)
}

struct Parser {
mut:
	tokens      []Token
	pos         int
	target      TargetInfo
	value_index map[string]int
	label_index map[string]int
}

fn describe(token Token) string {
	return match token.kind {
		.eof { 'the end of the file' }
		.newline { 'the end of the line' }
		.value { "'%${token.text}'" }
		.symbol { "'@${token.text}'" }
		.str { 'a string' }
		.number {
			sign := if token.negative { '-' } else { '' }
			if token.hex {
				return "'${sign}0x${token.text}'"
			}
			return "'${sign}${token.text}'"
		}
		else { "'${token.text}'" }
	}
}

fn (p &Parser) peek() Token {
	return p.tokens[p.pos]
}

fn (p &Parser) peek_at(n int) Token {
	index := p.pos + n
	if index < p.tokens.len {
		return p.tokens[index]
	}
	return p.tokens[p.tokens.len - 1]
}

fn (mut p Parser) advance() Token {
	token := p.tokens[p.pos]
	if p.pos < p.tokens.len - 1 {
		p.pos++
	}
	return token
}

fn (p &Parser) at_eol() bool {
	kind := p.peek().kind
	return kind == .newline || kind == .eof
}

fn (p &Parser) at_punct(text string) bool {
	token := p.peek()
	return token.kind == .punct && token.text == text
}

fn (p &Parser) at_ident(text string) bool {
	token := p.peek()
	return token.kind == .ident && token.text == text
}

fn (mut p Parser) skip_newlines() {
	for p.peek().kind == .newline {
		p.advance()
	}
}

fn (p &Parser) fail(token Token, message string) ParseError {
	return ParseError{
		line:    token.line
		col:     token.col
		message: message
	}
}

fn (p &Parser) fail_at(line int, col int, message string) ParseError {
	return ParseError{
		line:    line
		col:     col
		message: message
	}
}

fn (mut p Parser) expect_punct(text string) !Token {
	token := p.peek()
	if token.kind != .punct || token.text != text {
		return p.fail(token, "expected '${text}', found ${describe(token)}")
	}
	return p.advance()
}

fn (mut p Parser) expect_ident(text string) !Token {
	token := p.peek()
	if token.kind != .ident || token.text != text {
		return p.fail(token, "expected '${text}', found ${describe(token)}")
	}
	return p.advance()
}

fn (mut p Parser) expect_name() !Token {
	token := p.peek()
	if token.kind != .ident {
		return p.fail(token, 'expected a name, found ${describe(token)}')
	}
	return p.advance()
}

fn (mut p Parser) expect_value() !Token {
	token := p.peek()
	if token.kind != .value {
		return p.fail(token, 'expected a value, found ${describe(token)}')
	}
	return p.advance()
}

fn (mut p Parser) expect_symbol() !Token {
	token := p.peek()
	if token.kind != .symbol {
		return p.fail(token, 'expected a symbol, found ${describe(token)}')
	}
	return p.advance()
}

fn (mut p Parser) expect_number() !Token {
	token := p.peek()
	if token.kind != .number {
		return p.fail(token, 'expected a number, found ${describe(token)}')
	}
	return p.advance()
}

fn (mut p Parser) expect_string() !Token {
	token := p.peek()
	if token.kind != .str {
		return p.fail(token, 'expected a string, found ${describe(token)}')
	}
	return p.advance()
}

// expect_type reads one type. A scalar is one token; a struct, an array and a
// vector are the bracketed forms from ir-text.md, nested as deep as written.
fn (mut p Parser) expect_type() !Type {
	token := p.peek()
	if token.kind == .punct {
		match token.text {
			'{' { return p.parse_struct_type() }
			'[' { return p.parse_array_type() }
			'<' { return p.parse_vector_type() }
			else {}
		}
	}
	if token.kind != .ident {
		return p.fail(token, 'expected a type, found ${describe(token)}')
	}
	typ := type_from_text(token.text) or { return p.fail(token, err.msg()) }
	p.advance()
	return typ
}

fn (mut p Parser) parse_struct_type() !Type {
	p.expect_punct('{')!
	mut fields := []Type{}
	if !p.at_punct('}') {
		for {
			fields << p.expect_type()!
			if p.at_punct(',') {
				p.advance()
				continue
			}
			break
		}
	}
	p.expect_punct('}')!
	return struct_type(fields)
}

fn (mut p Parser) parse_array_type() !Type {
	p.expect_punct('[')!
	count := p.parse_type_count()!
	p.expect_ident('x')!
	elem := p.expect_type()!
	p.expect_punct(']')!
	return array_type(elem, count)
}

fn (mut p Parser) parse_vector_type() !Type {
	p.expect_punct('<')!
	count := p.parse_type_count()!
	p.expect_ident('x')!
	elem := p.expect_type()!
	p.expect_punct('>')!
	return vector_type(elem, count)
}

fn (mut p Parser) parse_type_count() !int {
	token := p.expect_number()!
	if token.negative || token.num > u128(9223372036854775807) {
		return p.fail(token, 'a count does not fit in an integer')
	}
	return int(token.num)
}

fn (mut p Parser) expect_eol(context string) ! {
	token := p.peek()
	if token.kind == .newline {
		p.advance()
		return
	}
	if token.kind == .eof {
		return
	}
	if token.kind == .punct && token.text == ',' {
		return p.fail(token, 'too many operands for ${context}')
	}
	return p.fail(token, 'expected the end of the line after ${context}, found ${describe(token)}')
}

fn (mut p Parser) parse_module() !Module {
	p.skip_newlines()
	token := p.peek()
	if token.kind != .ident || token.text != 'target' {
		return p.fail(token, "expected the 'target' line first")
	}
	p.advance()
	target := p.parse_target()!
	mut module := Module{
		target: target
	}
	p.value_index.clear()
	p.label_index.clear()
	p.skip_newlines()
	for p.peek().kind != .eof {
		mut declaration := p.peek()
		mut public := false
		if declaration.kind == .ident && declaration.text == 'pub' {
			p.advance()
			public = true
			declaration = p.peek()
		}
		if declaration.kind != .ident {
			return p.fail(declaration, 'expected a declaration, found ${describe(declaration)}')
		}
		match declaration.text {
			'global' {
				module.globals << p.parse_global(public)!
			}
			'fn' {
				module.functions << p.parse_function(public, false)!
			}
			'extern' {
				if public {
					return p.fail(declaration, "'extern' does not take 'pub'")
				}
				p.advance()
				module.functions << p.parse_function(false, true)!
			}
			else {
				return p.fail(declaration, "expected a declaration, found '${declaration.text}'")
			}
		}
		p.skip_newlines()
	}
	resolve_module(mut module)!
	return module
}

fn (mut p Parser) parse_target() !TargetInfo {
	width := p.expect_number()!
	if width.num > 65535 {
		return p.fail(width, 'pointer width does not fit in 16 bits')
	}
	endian_token := p.expect_name()!
	mut endian := Endian.little
	if endian_token.text == 'little' {
		endian = .little
	} else if endian_token.text == 'big' {
		endian = .big
	} else {
		return p.fail(endian_token, "expected 'little' or 'big', found '${endian_token.text}'")
	}
	align := p.expect_number()!
	if align.num > 65535 {
		return p.fail(align, 'pointer alignment does not fit in 16 bits')
	}
	p.expect_eol('the target line')!
	p.target = TargetInfo{
		pointer_width: u16(width.num)
		pointer_align: u16(align.num)
		endian:        endian
	}
	return p.target
}

fn (mut p Parser) parse_global(public bool) !Global {
	p.expect_ident('global')!
	name := p.expect_symbol()!
	p.expect_punct(':')!
	typ := p.expect_type()!
	mut readonly := false
	if p.at_ident('readonly') {
		p.advance()
		readonly = true
	}
	mut init := ?Const(none)
	if p.at_punct('=') {
		p.advance()
		value := p.parse_const()!
		init = value
	}
	p.expect_eol('the global')!
	return Global{
		name:     name.text
		typ:      typ
		readonly: readonly
		public:   public
		init:     init
	}
}

// parse_const reads a global's initializer: an integer, a float with its stated
// type and hex bit pattern, null, zeroinit, or a bracketed list of constants.
// It checks the leaf's syntax and not the tree's type; V033 compares the tree
// with the global's type.
fn (mut p Parser) parse_const() !Const {
	token := p.peek()
	match token.kind {
		.number {
			p.advance()
			return Const{
				kind: .int
				bits: token.num
			}
		}
		.ident {
			match token.text {
				'null' {
					p.advance()
					return Const{
						kind: .null
					}
				}
				'zeroinit' {
					p.advance()
					return Const{
						kind: .zero
					}
				}
				'f16', 'f32', 'f64', 'f128' {
					return p.parse_float_const(token)!
				}
				else {
					return p.fail(token, 'expected a constant, found ${describe(token)}')
				}
			}
		}
		.punct {
			if token.text == '{' || token.text == '[' {
				return p.parse_const_list()!
			}
		}
		else {}
	}
	return p.fail(token, 'expected a constant, found ${describe(token)}')
}

fn (mut p Parser) parse_float_const(type_token Token) !Const {
	typ := type_from_text(type_token.text)!
	p.advance()
	token := p.peek()
	if token.kind != .number || !token.hex || token.negative {
		return p.fail(token, "expected a hex bit pattern after '${type_token.text}', found ${describe(token)}")
	}
	if token.text.len > int(typ.bits) / 4 {
		return p.fail(token, 'the bit pattern for ${type_token.text} has more than ${int(typ.bits) / 4} hex digits')
	}
	p.advance()
	return Const{
		kind: .float
		bits: token.num
		typ:  typ
	}
}

fn (mut p Parser) parse_const_list() !Const {
	open := p.peek().text
	close := if open == '{' { '}' } else { ']' }
	p.advance()
	mut elems := []Const{}
	if !p.at_punct(close) {
		for {
			elems << p.parse_const()!
			if p.at_punct(',') {
				p.advance()
				continue
			}
			break
		}
	}
	p.expect_punct(close)!
	return Const{
		kind:  .seq
		elems: elems
	}
}

fn (mut p Parser) parse_function(public bool, external bool) !Function {
	p.expect_ident('fn')!
	name := p.expect_symbol()!
	p.expect_punct('(')!
	mut param_names := []Token{}
	mut params := []Param{}
	if !p.at_punct(')') {
		for {
			param_names << p.expect_value()!
			p.expect_punct(':')!
			typ := p.expect_type()!
			params << param(typ, p.parse_noundef())
			if p.at_punct(',') {
				p.advance()
				continue
			}
			break
		}
	}
	p.expect_punct(')')!
	mut results := []Result{}
	if p.at_punct('->') {
		p.advance()
		results = p.parse_result_types()!
	}
	effect_set := p.parse_effects()
	mut function := Function{
		name:      name.text
		signature: Signature{
			params:  params
			results: results
			effects: effect_set
		}
		public:    public
		defined:   !external
	}
	p.value_index.clear()
	p.label_index.clear()
	for i in 0 .. param_names.len {
		p.define_value(mut function, param_names[i], params[i].typ, .function_param, -1, -1)!
	}
	if external {
		p.expect_eol('the declaration')!
		return function
	}
	p.expect_punct('{')!
	p.expect_eol('the function header')!
	mut seen_block := false
	for {
		p.skip_newlines()
		token := p.peek()
		if token.kind == .eof {
			return p.fail(token, "unexpected end of the file inside the function '@${function.name}': missing '}'")
		}
		if p.at_punct('}') {
			break
		}
		if token.kind == .ident && token.text == 'stack' && p.peek_at(1).kind == .ident
			&& p.peek_at(1).text.starts_with('slot') {
			if seen_block {
				return p.fail(token, 'stack slots are declared before the blocks')
			}
			function.stack_slots << p.parse_stack_slot()!
			continue
		}
		seen_block = true
		function.blocks << p.parse_block(mut function)!
	}
	p.expect_punct('}')!
	p.expect_eol('the function')!
	p.resolve_values(mut function)!
	return function
}

fn (mut p Parser) parse_result_types() ![]Result {
	if p.at_punct('(') {
		p.advance()
		mut results := []Result{}
		if !p.at_punct(')') {
			for {
				typ := p.expect_type()!
				results << result(typ, p.parse_noundef())
				if p.at_punct(',') {
					p.advance()
					continue
				}
				break
			}
		}
		p.expect_punct(')')!
		return results
	}
	mut results := []Result{cap: 1}
	typ := p.expect_type()!
	results << result(typ, p.parse_noundef())
	return results
}

// parse_noundef reads the promise after a parameter or a result's type.
fn (mut p Parser) parse_noundef() bool {
	if p.at_ident('noundef') {
		p.advance()
		return true
	}
	return false
}

// parse_effects reads the call effects after the results. They are a set, so a
// file may write them in any order; the printer writes the canonical one.
fn (mut p Parser) parse_effects() EffectSet {
	mut set := EffectSet{}
	for {
		token := p.peek()
		if token.kind != .ident {
			return set
		}
		match token.text {
			'readonly' { set.readonly = true }
			'readnone' { set.readnone = true }
			'argmemonly' { set.argmemonly = true }
			'nounwind' { set.nounwind = true }
			else { return set }
		}
		p.advance()
	}
	return set
}

fn (mut p Parser) parse_stack_slot() !StackSlot {
	p.expect_ident('stack')!
	name := p.expect_name()!
	p.expect_punct(':')!
	size := p.expect_number()!
	if size.num > 4294967295 {
		return p.fail(size, 'stack slot size does not fit in 32 bits')
	}
	p.expect_ident('bytes')!
	p.expect_ident('align')!
	align := p.expect_number()!
	if align.num > 65535 {
		return p.fail(align, 'stack slot alignment does not fit in 16 bits')
	}
	p.expect_eol('the stack slot')!
	return StackSlot{
		size:  u32(size.num)
		align: u16(align.num)
		name:  name.text
	}
}

fn (mut p Parser) define_value(mut function Function, token Token, typ Type, kind ValueKind, block int, inst int) !int {
	if token.text in p.value_index {
		return p.fail(token, "duplicate value '%${token.text}'")
	}
	index := function.values.len
	function.values << Value{
		name:  token.text
		typ:   typ
		kind:  kind
		block: block
		inst:  inst
	}
	p.value_index[token.text] = index
	return index
}

fn (mut p Parser) parse_block(mut function Function) !Block {
	label := p.expect_name()!
	if label.text in p.label_index {
		return p.fail(label, "duplicate block label '${label.text}'")
	}
	block_index := function.blocks.len
	p.label_index[label.text] = block_index
	mut block := Block{
		label: label.text
	}
	if p.at_punct('(') {
		p.advance()
		if !p.at_punct(')') {
			for {
				value := p.expect_value()!
				p.expect_punct(':')!
				typ := p.expect_type()!
				index := p.define_value(mut function, value, typ, .block_param, block_index, -1)!
				block.params << index
				if p.at_punct(',') {
					p.advance()
					continue
				}
				break
			}
		}
		p.expect_punct(')')!
	}
	p.expect_punct(':')!
	p.expect_eol('the block label')!
	for {
		p.skip_newlines()
		token := p.peek()
		if token.kind == .eof {
			return p.fail(token, "unexpected end of the file: block '${label.text}' has no terminator")
		}
		if p.at_punct('}') {
			return p.fail(token, "block '${label.text}' has no terminator")
		}
		if token.kind == .ident && p.peek_at(1).kind == .punct
			&& (p.peek_at(1).text == ':' || p.peek_at(1).text == '(') {
			return p.fail(token, "block '${label.text}' has no terminator")
		}
		inst := p.parse_instruction(mut function, block_index, block.instructions.len)!
		if inst.opcode.is_terminator() {
			block.terminator = inst
			break
		}
		block.instructions << inst
	}
	return block
}

fn (mut p Parser) parse_instruction(mut function Function, block_index int, inst_index int) !Instruction {
	mut result_tokens := []Token{}
	if p.peek().kind == .value {
		for {
			result_tokens << p.advance()
			if p.at_punct(',') {
				p.advance()
				continue
			}
			break
		}
		p.expect_punct('=')!
	}
	op_token := p.peek()
	if op_token.kind != .ident {
		return p.fail(op_token, 'expected an opcode, found ${describe(op_token)}')
	}
	op := opcode_from_name(op_token.text) or {
		if op_token.text == 'stack' {
			return p.fail(op_token, 'a stack slot is declared before the blocks, not inside one')
		}
		return p.fail(op_token, "unknown opcode '${op_token.text}'")
	}
	p.advance()
	mut inst := Instruction{
		opcode: op
	}
	p.parse_flags(mut inst)!
	p.parse_opcode_operands(mut inst, &function)!
	p.parse_loc(mut inst)!
	p.expect_eol("'${op.name()}'")!
	expected := op.fixed_result_count()
	if expected >= 0 && result_tokens.len != expected {
		at := if result_tokens.len > expected { result_tokens[expected] } else { op_token }
		return p.fail(at, "'${op.name()}' takes ${result_count_text(expected)}, found ${result_tokens.len}")
	}
	if op == .call_indirect && result_tokens.len != inst.signature.results.len {
		return p.fail(op_token, "'call_indirect' carries ${inst.signature.results.len} results, ${result_tokens.len} names given")
	}
	if op == .inline_asm && result_tokens.len != inst.asm.outputs.len {
		return p.fail(op_token, "'inline_asm' has ${inst.asm.outputs.len} outputs, ${result_tokens.len} names given")
	}
	for name in result_tokens {
		index := p.define_value(mut function, name, ty_unknown, .instruction_result, block_index,
			inst_index)!
		inst.results << index
	}
	return inst
}

fn result_count_text(count int) string {
	return match count {
		0 { 'no results' }
		1 { 'one result' }
		2 { 'two results' }
		else { '${count} results' }
	}
}

fn (mut p Parser) parse_opcode_operands(mut inst Instruction, function &Function) ! {
	match inst.opcode {
		.iconst {
			inst.typ = p.expect_type()!
			token := p.expect_number()!
			inst.operands << Operand{
				kind: .int_imm
				imm:  mask_int(token.num, inst.typ)
				idx:  -1
				line: token.line
				col:  token.col
			}
		}
		.fconst {
			inst.typ = p.expect_type()!
			token := p.expect_number()!
			inst.operands << Operand{
				kind: .float_imm
				imm:  token.num
				typ:  inst.typ
				idx:  -1
				line: token.line
				col:  token.col
			}
		}
		.poison {
			inst.typ = p.expect_type()!
		}
		.null {}
		.iadd, .isub, .imul, .sdiv, .udiv, .srem, .urem, .smin, .smax, .umin, .umax,
		.sadd_overflow, .uadd_overflow, .ssub_overflow, .usub_overflow, .smul_overflow,
		.umul_overflow, .sadd_sat, .uadd_sat, .ssub_sat, .usub_sat, .smul_sat, .umul_sat,
		.band, .bor, .bxor, .shl, .sshr, .ushr, .rotl, .rotr, .fadd, .fsub, .fmul, .fdiv,
		.frem, .fcopysign, .fmin, .fmax {
			p.parse_fixed_operands(mut inst, 2)!
		}
		.fma, .@select {
			p.parse_fixed_operands(mut inst, 3)!
		}
		.ineg, .iabs, .bnot, .clz, .ctz, .popcnt, .bswap, .freeze, .fneg, .fabs, .fsqrt,
		.fceil, .ffloor, .ftrunc, .fnearest {
			p.parse_fixed_operands(mut inst, 1)!
		}
		.icmp, .fcmp {
			token := p.expect_name()!
			if !is_predicate(token.text) {
				return p.fail(token, "unknown predicate '${token.text}'")
			}
			inst.predicate = token.text
			inst.operands << p.parse_value_or_imm("'${inst.opcode.name()}'")!
			p.expect_punct(',')!
			inst.operands << p.parse_value_or_imm("'${inst.opcode.name()}'")!
		}
		.sext, .zext, .trunc, .bitcast, .sitofp, .uitofp, .fptosi, .fptoui, .fpext,
		.fptrunc {
			inst.operands << p.parse_value_or_imm("'${inst.opcode.name()}'")!
			p.expect_ident('to')!
			inst.typ = p.expect_type()!
		}
		.ptrtoint {
			inst.operands << p.parse_value_or_imm("'${inst.opcode.name()}'")!
			if p.at_ident('to') {
				p.advance()
				inst.typ = p.expect_type()!
			} else {
				inst.typ = int_type(p.target.pointer_width)
			}
		}
		.inttoptr {
			inst.operands << p.parse_value_or_imm("'${inst.opcode.name()}'")!
			if p.at_ident('to') {
				p.advance()
				inst.typ = p.expect_type()!
			} else {
				inst.typ = ty_ptr
			}
		}
		.load {
			inst.operands << p.parse_value_or_imm("'${inst.opcode.name()}'")!
			p.expect_punct(':')!
			inst.typ = p.expect_type()!
			inst.align = p.parse_align()!
		}
		.store {
			p.parse_fixed_operands(mut inst, 2)!
			inst.align = p.parse_align()!
		}
		.ptradd {
			p.parse_fixed_operands(mut inst, 2)!
		}
		.memcpy, .memmove {
			p.parse_fixed_operands(mut inst, 3)!
			mut have_dst := false
			mut have_src := false
			for _ in 0 .. 2 {
				p.expect_ident('align')!
				side := p.expect_name()!
				value := p.expect_number()!
				if value.num > 65535 {
					return p.fail(value, 'alignment does not fit in 16 bits')
				}
				if side.text == 'dst' {
					if have_dst {
						return p.fail(side, "duplicate 'align dst'")
					}
					have_dst = true
					inst.align_dst = u16(value.num)
				} else if side.text == 'src' {
					if have_src {
						return p.fail(side, "duplicate 'align src'")
					}
					have_src = true
					inst.align_src = u16(value.num)
				} else {
					return p.fail(side, "expected 'dst' or 'src' after 'align', found '${side.text}'")
				}
			}
			if !have_dst {
				return p.fail(p.peek(), "'${inst.opcode.name()}' needs 'align dst'")
			}
			if !have_src {
				return p.fail(p.peek(), "'${inst.opcode.name()}' needs 'align src'")
			}
		}
		.memset {
			p.parse_fixed_operands(mut inst, 3)!
			inst.align = p.parse_align()!
		}
		.stack_addr {
			token := p.peek()
			if token.kind != .ident {
				return p.fail(token, "expected a stack slot after 'stack_addr', found ${describe(token)}")
			}
			mut index := -1
			for i in 0 .. function.stack_slots.len {
				if function.stack_slots[i].name or { '' } == token.text {
					index = i
				}
			}
			if index < 0 {
				return p.fail(token, "unknown stack slot '${token.text}'")
			}
			p.advance()
			inst.operands << Operand{
				kind: .stack_slot
				name: token.text
				idx:  index
				line: token.line
				col:  token.col
			}
		}
		.global_addr, .func_addr {
			token := p.expect_symbol()!
			inst.operands << Operand{
				kind: .symbol
				name: token.text
				idx:  -1
				line: token.line
				col:  token.col
			}
		}
		.br {
			inst.target = p.parse_block_target()!
		}
		.condbr {
			inst.operands << p.parse_value_or_imm("'condbr'")!
			p.expect_punct(',')!
			inst.target = p.parse_block_target()!
			p.expect_punct(',')!
			inst.else_target = p.parse_block_target()!
		}
		.switch {
			inst.operands << p.parse_value_or_imm("'switch'")!
			p.expect_punct(',')!
			inst.target = p.parse_block_target()!
			for p.at_punct(',') && p.peek_at(1).kind == .number {
				p.advance()
				value := p.advance()
				p.expect_punct(':')!
				target := p.parse_block_target()!
				inst.cases << SwitchCase{
					value:  value.num
					target: target
				}
			}
		}
		.@return {
			if !p.at_eol() {
				for {
					inst.operands << p.parse_value_or_imm("'return'")!
					if p.at_punct(',') {
						p.advance()
						continue
					}
					break
				}
			}
		}
		.unreachable {}
		.trap {
			token := p.expect_number()!
			if token.num > 4294967295 {
				return p.fail(token, 'trap code does not fit in 32 bits')
			}
			inst.trap_code = u32(token.num)
		}
		.assume {
			p.parse_fixed_operands(mut inst, 1)!
		}
		.call, .tailcall {
			token := p.expect_symbol()!
			inst.operands << Operand{
				kind: .symbol
				name: token.text
				idx:  -1
				line: token.line
				col:  token.col
			}
			p.expect_punct('(')!
			p.parse_call_arguments(mut inst)!
			p.expect_punct(')')!
		}
		.call_indirect, .tailcall_indirect {
			inst.operands << p.parse_value_or_imm("'${inst.opcode.name()}'")!
			p.expect_punct(':')!
			inst.signature = p.parse_signature()!
			p.expect_punct('(')!
			p.parse_call_arguments(mut inst)!
			p.expect_punct(')')!
		}
		.inline_asm {
			template := p.expect_string()!
			inst.asm.template = template.text
			inst.asm.volatile = inst.flags.volatile
			p.parse_asm_inputs(mut inst)!
		}
		else {}
	}
}

fn (mut p Parser) parse_align() !u16 {
	p.expect_ident('align')!
	token := p.expect_number()!
	if token.num > 65535 {
		return p.fail(token, 'alignment does not fit in 16 bits')
	}
	return u16(token.num)
}

fn (mut p Parser) parse_call_arguments(mut inst Instruction) ! {
	if p.at_punct(')') {
		return
	}
	for {
		inst.operands << p.parse_value_or_imm('a call argument')!
		if p.at_punct(',') {
			p.advance()
			continue
		}
		break
	}
}

fn (mut p Parser) parse_flags(mut inst Instruction) ! {
	for {
		token := p.peek()
		if token.kind != .ident {
			return
		}
		match token.text {
			'nsw' {
				inst.flags.nsw = true
			}
			'nuw' {
				inst.flags.nuw = true
			}
			'exact' {
				inst.flags.exact = true
			}
			'inbounds' {
				inst.flags.inbounds = true
			}
			'volatile' {
				inst.flags.volatile = true
			}
			'nnan' {
				inst.flags.nnan = true
			}
			'ninf' {
				inst.flags.ninf = true
			}
			'nsz' {
				inst.flags.nsz = true
			}
			'arcp' {
				inst.flags.arcp = true
			}
			'contract' {
				inst.flags.contract = true
			}
			'reassoc' {
				inst.flags.reassoc = true
			}
			'afn' {
				inst.flags.afn = true
			}
			else {
				return
			}
		}
		p.advance()
	}
}

fn (mut p Parser) parse_loc(mut inst Instruction) ! {
	token := p.peek()
	if token.kind != .symbol || token.text != 'loc' {
		return
	}
	next := p.peek_at(1)
	if next.kind != .punct || next.text != '(' {
		return
	}
	p.advance()
	p.expect_punct('(')!
	file := p.expect_string()!
	p.expect_punct(',')!
	line := p.expect_number()!
	if line.num > 4294967295 {
		return p.fail(line, 'location line does not fit in 32 bits')
	}
	p.expect_punct(',')!
	column := p.expect_number()!
	if column.num > 4294967295 {
		return p.fail(column, 'location column does not fit in 32 bits')
	}
	p.expect_punct(')')!
	inst.loc = SourceLoc{
		file: file.text
		line: u32(line.num)
		col:  u32(column.num)
	}
}

fn (mut p Parser) parse_value_or_imm(context string) !Operand {
	token := p.peek()
	match token.kind {
		.value {
			p.advance()
			return Operand{
				kind: .value
				name: token.text
				idx:  -1
				line: token.line
				col:  token.col
			}
		}
		.number {
			p.advance()
			return Operand{
				kind: .int_imm
				imm:  token.num
				idx:  -1
				line: token.line
				col:  token.col
			}
		}
		else {
			if token.kind == .ident {
				return p.fail(token, "unknown flag '${token.text}'")
			}
			return p.fail(token, 'expected an operand for ${context}, found ${describe(token)}')
		}
	}
}

fn (mut p Parser) parse_fixed_operands(mut inst Instruction, count int) ! {
	for i in 0 .. count {
		if p.at_eol() {
			token := p.peek()
			return p.fail(token, "expected an operand for '${inst.opcode.name()}', found ${describe(token)}")
		}
		if i > 0 {
			p.expect_punct(',')!
		}
		inst.operands << p.parse_value_or_imm("'${inst.opcode.name()}'")!
	}
}

fn (mut p Parser) parse_block_target() !BlockTarget {
	token := p.peek()
	if token.kind != .ident {
		return p.fail(token, 'expected a block label, found ${describe(token)}')
	}
	p.advance()
	mut target := BlockTarget{
		label: token.text
		block: -1
		line:  token.line
		col:   token.col
	}
	p.expect_punct('(')!
	if !p.at_punct(')') {
		for {
			target.args << p.parse_value_or_imm('a block argument')!
			if p.at_punct(',') {
				p.advance()
				continue
			}
			break
		}
	}
	p.expect_punct(')')!
	return target
}

fn (mut p Parser) parse_signature() !Signature {
	p.expect_punct('(')!
	mut params := []Param{}
	if !p.at_punct(')') {
		for {
			typ := p.expect_type()!
			params << param(typ, p.parse_noundef())
			if p.at_punct(',') {
				p.advance()
				continue
			}
			break
		}
	}
	p.expect_punct(')')!
	mut results := []Result{}
	if p.at_punct('->') {
		p.advance()
		results = p.parse_result_types()!
	}
	effect_set := p.parse_effects()
	return Signature{
		params:  params
		results: results
		effects: effect_set
	}
}

fn (mut p Parser) parse_asm_inputs(mut inst Instruction) ! {
	for {
		if p.peek().kind == .newline {
			next := p.peek_at(1)
			if next.kind == .ident && is_asm_clause(next.text) {
				p.advance()
				continue
			}
		}
		token := p.peek()
		if token.kind != .ident || !is_asm_clause(token.text) {
			return
		}
		p.advance()
		match token.text {
			'out' {
				p.expect_punct('(')!
				typ := p.expect_type()!
				p.expect_punct(',')!
				constraint := p.expect_string()!
				p.expect_punct(')')!
				inst.asm.outputs << InlineAsmOutput{
					typ:        typ
					constraint: constraint.text
				}
			}
			'in' {
				p.expect_punct('(')!
				value := p.parse_value_or_imm('an inline asm input')!
				p.expect_punct(',')!
				constraint := p.expect_string()!
				p.expect_punct(')')!
				inst.asm.inputs << InlineAsmInput{
					value:      value
					constraint: constraint.text
				}
			}
			'clobber' {
				p.expect_punct('(')!
				name := p.expect_string()!
				p.expect_punct(')')!
				inst.asm.clobbers << name.text
			}
			'volatile' {
				inst.asm.volatile = true
			}
			'alignstack' {
				inst.asm.alignstack = true
			}
			'intel' {
				inst.asm.intel = true
			}
			else {}
		}
	}
}

fn is_asm_clause(text string) bool {
	return text == 'out' || text == 'in' || text == 'clobber' || text == 'volatile'
		|| text == 'alignstack' || text == 'intel'
}

fn is_predicate(text string) bool {
	return text in ['eq', 'ne', 'slt', 'sle', 'sgt', 'sge', 'ult', 'ule', 'ugt', 'uge', 'oeq',
		'one', 'olt', 'ole', 'ogt', 'oge', 'ueq', 'une', 'ord', 'uno']
}

// mask_int keeps the low bits of an immediate that has a width, so `iconst ty_i32
// -1` holds 4294967295 rather than a 128-bit pattern.
fn mask_int(value u128, typ Type) u128 {
	if typ.kind != .int || typ.bits == 0 || typ.bits >= 128 {
		return value
	}
	mask := (u128(1) << u16(typ.bits)) - 1
	return value & mask
}

// operand_type is the type an operand contributes to the opcode rules. A value
// takes its type from the value table, a float immediate carries the type the
// text wrote, and an integer immediate is typed by its position, which the
// parser does not work out.
fn operand_type(operands []Operand, index int, function Function) Type {
	if index < 0 || index >= operands.len {
		return ty_unknown
	}
	operand := operands[index]
	match operand.kind {
		.value {
			if operand.idx >= 0 && operand.idx < function.values.len {
				return function.values[operand.idx].typ
			}
			return ty_unknown
		}
		.float_imm {
			return operand.typ
		}
		else {
			return ty_unknown
		}
	}
}

// instruction_result_types is what ir-instructions.md says each opcode returns:
// the first operand's type for an arithmetic or bitwise instruction, ty_i1 for a
// comparison, the stated type for a constant or a conversion, the arms' type
// for a select, and the signature's results for a call.
fn instruction_result_types(inst Instruction, function Function, pointer_width u16) []Type {
	match inst.opcode {
		.iconst, .fconst, .poison, .load {
			return [inst.typ]
		}
		.sext, .zext, .trunc, .bitcast, .sitofp, .uitofp, .fptosi, .fptoui, .fpext, .fptrunc {
			return [inst.typ]
		}
		.ptrtoint, .inttoptr {
			if inst.typ.is_unknown() {
				return [int_type(pointer_width)]
			}
			return [inst.typ]
		}
		.null {
			return [ty_ptr]
		}
		.icmp, .fcmp {
			return [ty_i1]
		}
		.sadd_overflow, .uadd_overflow, .ssub_overflow, .usub_overflow, .smul_overflow,
		.umul_overflow {
			return [operand_type(inst.operands, 0, function), ty_i1]
		}
		.@select {
			arm := operand_type(inst.operands, 1, function)
			if !arm.is_unknown() {
				return [arm]
			}
			return [operand_type(inst.operands, 2, function)]
		}
		.ptradd, .stack_addr, .global_addr, .func_addr {
			return [ty_ptr]
		}
		.call, .call_indirect {
			return inst.signature.result_types()
		}
		.inline_asm {
			mut types := []Type{cap: inst.asm.outputs.len}
			for output in inst.asm.outputs {
				types << output.typ
			}
			return types
		}
		.freeze, .ineg, .iabs, .bnot, .clz, .ctz, .popcnt, .bswap, .fneg, .fabs, .fsqrt,
		.fceil, .ffloor, .ftrunc, .fnearest, .iadd, .isub, .imul, .sdiv, .udiv, .srem,
		.urem, .smin, .smax, .umin, .umax, .sadd_sat, .uadd_sat, .ssub_sat, .usub_sat,
		.smul_sat, .umul_sat, .band, .bor, .bxor, .shl, .sshr, .ushr, .rotl, .rotr,
		.fadd, .fsub, .fmul, .fdiv, .frem, .fcopysign, .fma, .fmin, .fmax {
			return [operand_type(inst.operands, 0, function)]
		}
		else {
			return []
		}
	}
}

fn (mut p Parser) resolve_operand(mut operand Operand) ! {
	if operand.kind != .value {
		return
	}
	if operand.name in p.value_index {
		operand.idx = p.value_index[operand.name]
		return
	}
	return p.fail_at(operand.line, operand.col, "value '%${operand.name}' is used but never defined")
}

fn (mut p Parser) resolve_target(mut target BlockTarget) ! {
	if target.label in p.label_index {
		target.block = p.label_index[target.label]
	} else {
		return p.fail_at(target.line, target.col, "unknown block '${target.label}'")
	}
	for i in 0 .. target.args.len {
		p.resolve_operand(mut target.args[i])!
	}
}

fn (mut p Parser) resolve_instruction_values(mut inst Instruction) ! {
	for i in 0 .. inst.operands.len {
		p.resolve_operand(mut inst.operands[i])!
	}
	for i in 0 .. inst.asm.inputs.len {
		p.resolve_operand(mut inst.asm.inputs[i].value)!
	}
	if inst.opcode == .br || inst.opcode == .condbr || inst.opcode == .switch {
		mut target := inst.target
		p.resolve_target(mut target)!
		inst.target = target
	}
	if inst.opcode == .condbr {
		mut else_target := inst.else_target
		p.resolve_target(mut else_target)!
		inst.else_target = else_target
	}
	if inst.opcode == .switch {
		for i in 0 .. inst.cases.len {
			mut case_target := inst.cases[i].target
			p.resolve_target(mut case_target)!
			inst.cases[i].target = case_target
		}
	}
}

fn (mut p Parser) resolve_values(mut function Function) ! {
	for bi in 0 .. function.blocks.len {
		for ii in 0 .. function.blocks[bi].instructions.len {
			mut inst := function.blocks[bi].instructions[ii]
			p.resolve_instruction_values(mut inst)!
			function.blocks[bi].instructions[ii] = inst
		}
		mut terminator := function.blocks[bi].terminator
		p.resolve_instruction_values(mut terminator)!
		function.blocks[bi].terminator = terminator
	}
}

fn resolve_module(mut module Module) ! {
	resolve_symbols(mut module)!
	for fi in 0 .. module.functions.len {
		apply_result_types(mut module, fi)
	}
}

fn resolve_symbols(mut module Module) ! {
	for fi in 0 .. module.functions.len {
		for bi in 0 .. module.functions[fi].blocks.len {
			for ii in 0 .. module.functions[fi].blocks[bi].instructions.len {
				resolve_instruction_symbol(mut module, fi, bi, ii, false)!
			}
			resolve_instruction_symbol(mut module, fi, bi, 0, true)!
		}
	}
}

fn resolve_instruction_symbol(mut module Module, fi int, bi int, ii int, terminator bool) ! {
	inst := if terminator {
		module.functions[fi].blocks[bi].terminator
	} else {
		module.functions[fi].blocks[bi].instructions[ii]
	}
	op := inst.opcode
	if op != .call && op != .tailcall && op != .global_addr && op != .func_addr {
		return
	}
	if inst.operands.len == 0 || inst.operands[0].kind != .symbol {
		return
	}
	operand := inst.operands[0]
	kind := module.symbol_kind(operand.name)
	if kind == .none {
		return ParseError{
			line:    operand.line
			col:     operand.col
			message: "unknown symbol '@${operand.name}'"
		}
	}
	mut index := -1
	mut callee_signature := Signature{}
	if kind == .function {
		index = module.find_function_index(operand.name) or { -1 }
		callee_signature = module.functions[index].signature
		if op == .call && inst.results.len != callee_signature.results.len {
			return ParseError{
				line:    operand.line
				col:     operand.col
				message: "'@${operand.name}' returns ${callee_signature.results.len} results, found ${inst.results.len}"
			}
		}
	} else {
		index = module.find_global_index(operand.name) or { -1 }
	}
	mut resolved := inst
	resolved.operands[0].sym = kind
	resolved.operands[0].idx = index
	if kind == .function && (op == .call || op == .tailcall) {
		resolved.signature = callee_signature
	}
	if terminator {
		module.functions[fi].blocks[bi].terminator = resolved
	} else {
		module.functions[fi].blocks[bi].instructions[ii] = resolved
	}
}

fn apply_result_types(mut module Module, fi int) {
	pointer_width := module.target.pointer_width
	function := module.functions[fi]
	for bi in 0 .. module.functions[fi].blocks.len {
		for ii in 0 .. module.functions[fi].blocks[bi].instructions.len {
			inst := module.functions[fi].blocks[bi].instructions[ii]
			types := instruction_result_types(inst, function, pointer_width)
			for k in 0 .. types.len {
				if k < inst.results.len {
					module.functions[fi].values[inst.results[k]].typ = types[k]
				}
			}
		}
	}
}
