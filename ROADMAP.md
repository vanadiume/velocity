# Roadmap

What the library has to do, in the order it is being built. A release is done
when its paragraphs are true, not when its list is checked off.

## 0.0.x: the repository and the IR model

Done. The documents, the manifest, the gate, and the IR: types, values, blocks,
instructions, and a function that can be printed and read back. No target yet.

## 0.1.0: a function that verifies

The builder a front end writes against, and the verifier that refuses a function
which is not well formed. The evidence is a corpus of functions the verifier
accepts, a corpus it refuses by name, and a round trip through the textual form
that changes nothing.

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
