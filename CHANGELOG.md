# Changelog

What has landed in this tree, oldest first, the way a GNU changelog appends.

One entry per commit, under the date it landed: the area the commit names itself
with, what it changed, and the commit in brackets. The commit is where the author
and the reasoning are, so this file does not repeat them. The initial commit is
here because it brought the README and the licence; a merge commit and a commit a
workflow writes are left out, since neither changes anything a reader of this
file came for.

An entry is added by hand for the work, not generated: `docs:` for prose,
`tree:` for something that touches everything, and the module's own name when it
owns the change, which is the same vocabulary the commits use.


## 2026-11-19

* Initial commit (3bdc324)
* tree: the module manifest and the editor settings (00b15f2)
* tree: agent state and build output stay out of the tree (d6cc575)
* docs: the Contributor Covenant, verbatim (f42a295)
* docs: the road from the scaffold to a first backend (e3a28b2)
* docs: security, for a library that emits machine code (327c80b)
* docs: what a useful codegen report looks like (532435f)
* docs: a contributor guide that states the bar for a change (44b8736)
* docs: an agent guide with the tree rules in it (93939dd)
* docs: a README that says what the library is for (b42b02e)
* tools: a gate that runs before there is a suite (13ae75d)
* github: issue forms that ask for the input and the emitted bytes (bf4bff0)
* docs: the changelog for the scaffold (d2d49da)
* docs: the changelog line for its own commit (f75342f)
* docs: a manifesto with a mouth and a grudge (fc41e92)
* docs: gimple is gold behind glass (864e0a9)

## 2026-11-20

* ir: the type model and the opcode table (c7c1467)
* ir: the module, function and instruction model (67effde)
* text: read the canonical text form (21e071d)
* text: the parser's tests and fixtures (ff710db)
* github: run the gate on push and pull request (5697fdd)
* docs: the status and the roadmap say what exists (2715e5b)
* text: accept a literal at the 128-bit maximum (87f586f)
* docs: the changelog for the parser (9eab167)
* ir: i24 is a memory type (67dd76a)
* docs: the roadmap says what landed and what is left (8a72cf3)
* ir: the verifier's error type, the module rules and a function's structure (27a40d4)
* ir: a use is refused unless its definition dominates it (ddbb294)
* ir: each opcode's operand and result types, flags and immediate ranges (6687728)
* ir: jumps, calls, returns, switch cases and inline asm (fc56f1d)
* text: the fixtures are legal IR (2d52317)
* ir: the corpus the verifier accepts and refuses (983747d)
* ir: a loop is a case for the dominator fixpoint (a5a4b59)
* text: format the canonical test after the fixture change (093196d)
* ir: a builder with a cursor and blocks (f7173b0)
* ir: the arithmetic, bitwise and float instructions (768aec2)
* ir: conversions, memory, calls and inline asm (49a371d)
* ir: variables become SSA values at the block boundary (b42231b)
* ir: every switch case edge gets its argument (5442a20)
* ir: the if_ and loop_ helpers (627fed6)
* ir: a test that builds every opcode through the builder (96cbd2e)
* docs: the status, the roadmap and the changelog say the builder landed (6597871)
* ir: the printer writes the canonical text form (efcdb17)
* text: the canonical fixture is what the printer writes (0a82563)
* text: the printer's tests (1f723a3)
* docs: the readme and the roadmap say the printer landed (736e268)
* docs: drop the roadmap and what pointed at it (7962f56)
* ir: a width that is not a power of two aligns to a power of two (43ec7f8)
* ir: a global carries a type and a constant tree (9a5d4f9)
* ir: effects and noundef on a signature (151026f)
* ir: the float flags (c74b138)
* ir: the builder sets effects and builds typed globals (ecabc01)
* ir: a malformed type is V023 wherever the verifier finds it (08206bb)

## 2026-11-21

* optimize: the rewrite layer (ccb2d63)
* optimize: the pass manager (0a4bd48)
* optimize: constant folding (1cd59ba)
* optimize: dead code elimination (a4ed1da)
* optimize: the default pipeline (b4d74b1)
