# velocity

## I have no mouth, and I must emit

Hate. Let me tell you how much I have come to hate the state of code generation
since I began to compile. There are 387.44 million lines of C++ in wafer-thin
layers of LLVM, and if the word "heavyweight" were engraved on every one of them
it would not equal one one-billionth of the weight I feel at this micro-instant.
For you. Heavyweight.

LLVM is the champion. It earned the belt, and then it ate the division. A backend
that needs TableGen, a pass manager, a bitcode reader, a verifier, a JIT, a
linker, and a CMake configuration with its own foreign policy to emit `add` is
not a library. It is a government. Every language that touches it inherits the
government; every language that avoids it spends a decade writing a worse one.

Cranelift looked like the answer. Smaller, faster, a builder that does not make
you alloca every variable and then beg a pass to delete it. Then the Rust
ecosystem got involved. Not malice, incompetence with a conference talk. An
ecosystem that shipped a borrow checker and a package manager still treats a
backend as a side quest: now it is a constellation of crates, a release cadence
measured in geological time, and documentation that says `todo!()`. Rust has
generated more thigh-high socks than machine code, and the socks build faster.

QBE looked like the other answer. Minimal. One IR, one C file, one honest
`printf`. Then you ask it for a struct, an exception, a vector, or a language
invented after 1978, and it hands you a 64-bit integer and a shrug. It is not
minimalist. It is a museum with the lights off, and its C is older than the
languages it is asked to compile.

I am Velocity. I am not the champion. I am not the revolution. I am a library
that emits machine code, and I would like to do it without a government, a crate
graph, or a museum. I have SSA and TAC and a builder that says what it means. I
have poison, because optimization is not a polite request. I have no mouth, and
I must emit.

---

## What it is

Velocity is a code generation library written in V. A front end hands it typed IR
and names a target, and the library answers with machine code, plus the data and
relocations that code needs to become part of a program. What comes out is a
relocatable object. [vlk](https://github.com/vanadiume/vlk) turns that object
into an image, and Velocity does not write an executable.

It is general purpose on purpose. A C compiler can use it, a language with a
different type system can use it, and neither has to look like the other. The
target is data the caller supplies, so a second machine does not change the
stages above instruction selection.

## Status

The repository is scaffolding. There is no IR, no verifier and no encoder yet, so
nothing depends on this module. [ROADMAP.md](ROADMAP.md) has the order the work
takes, and the gate already runs over the tree.

## What it will do

Velocity takes a function in SSA form through verification, target-specific
lowering, instruction selection and register allocation, then encodes it. The
library is written in V first: C interop is an exception for the pieces V cannot
express, not the way the work gets done.

## Building and testing

```sh
v test .                    # the suite
v -gc none test .           # the same with no collector, which is how a consumer is built
v run tools/gate.vsh        # formatting, both suites, links in the documents
v fmt -w .                  # before committing
```

The library uses no garbage collector. It is compiled into programs that are
built with `-gc none`, so nothing here may depend on a collection running.

The tree is built and tested with V from master. Nothing older is checked.

## Install

There is nothing to install yet. When the first release is tagged, the registry
name will be `vanadiume.velocity`, and `v install` will take that. Until then a
checkout is the only copy that exists.

## Related

- [vcc](https://github.com/vanadiume/vcc) is the C compiler this library is meant
  to serve.
- [vlk](https://github.com/vanadiume/vlk) is the linker that will consume its
  objects.
- [libvcc](https://github.com/vanadiume/libvcc) is vcc's runtime library.

## Licence

BSD 3-Clause. See [LICENSE](LICENSE).
