# Roadmap

What the library has to do, in the order it is being built. A release is done
when its paragraphs are true, not when its list is checked off.

## 0.0.x: the repository and the IR model

Landed: the documents, the manifest, the gate, the IR model in `ir/` with the
parser for the canonical text form, and the verifier. Types of every width,
functions, blocks with parameters, instructions with their flags and immediates,
globals and stack slots, and a fixture that covers every opcode. The verifier
reports all twenty-two codes, names the block and the instruction a rule is
about, and is tested by a corpus it accepts and a corpus it refuses.

Left in this release: the printer, so a module cannot be written back and there
is no round trip yet; and everything below the IR. A module can be built, read
and checked, not emitted. No target yet.

## 0.1.0: a function that verifies

Landed: the builder a front end writes against. Blocks, the cursor, one method
per opcode, and source variables that become block parameters at joins:
`declare_var`, `def_var` and `use_var` with explicit sealing, single-predecessor
resolution, and the `if_` and `loop_` helpers on top. A test calls every opcode
through its method and verifies the module, so a method that disappears fails
there instead of in a front end.

Left: the evidence for this release is the round trip, a function the builder
assembles, printed and parsed again unchanged. The printer that makes that
possible is not written, so a function built through the builder verifies today
and cannot be written back yet.

## 0.2.0: one target, integer code

x86-64 first, because the machines this family is developed on are x86-64.
Legalization and instruction selection for integer arithmetic, comparisons,
branches and calls, with a frame. The evidence is a function compiled to bytes
that runs, and the bytes checked against an assembler's encoding of the same
instructions.

## 0.3.0: an object a linker can use

The emitted unit carries code, data, symbols and relocations, and
[vlk](https://github.com/vanadiume/vlk) links it into a program that runs. The
evidence is a linked program whose exit status is the one the IR promised.

## 0.4.0: a backend another compiler can live with

Register allocation with spilling, calls that follow the platform ABI, and the
first consumer compiling a real function instead of a test.

## Later

- A second machine, aarch64, added as a target module with no stage above it
  changed.
- Floating point and the vector registers.
- IR passes: constant folding, dead code, and a pass pipeline the caller can
  name.
- A textual IR reader that refuses malformed input rather than trusting it.
