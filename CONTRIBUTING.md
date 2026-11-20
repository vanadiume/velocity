# Contributing to Velocity

Thanks for wanting to help. This file says what a change has to bring with it,
how the tree is written, and the rules that come before the rest.

- The library is written in V first. V is the answer to every question the tree
  asks, and C interop is the exception: `#include`, `C.` and `#flag` are allowed
  where V cannot express the piece or the platform interface is the C one, with
  the reason in the commit body and the use kept to the file that needs it. A
  test that needs an object or a listing writes it at test time; nothing binary
  is committed.
- The emitted bytes are the product. A change that produces instructions is
  checked against something that did not come from this tree: an assembler's
  encoding, the architecture manual, or a program that runs.
- No garbage collector. The library is compiled into compilers built with
  `-gc none`, so nothing here may depend on a collection running.

## Getting set up

You need V from master. The tests are the toolchain: there is no build script,
because a library has nothing to build until something imports it.

```sh
git clone https://github.com/vanadiume/velocity
cd velocity
v test .
v run tools/gate.vsh
```

The module is not published yet. When it is, `v install vanadiume.velocity` will
put a copy under `~/.vmodules`, imported as `vanadiume.velocity`. While you work
on the library against a front end in the same checkout, point that path at your
clone:

```sh
mkdir -p ~/.vmodules/vanadiume
ln -sfn "$PWD" ~/.vmodules/vanadiume/velocity
```

## The gate

`v run tools/gate.vsh` is what a pull request has to pass: the formatting check,
the suite, the same suite with no collector, and the links between the documents
at the root. A partial run is not the gate. Run the whole thing before asking
for review, rather than after someone tells you it is red.

## Adding a target

A target is a description of a machine and a system, plus the encoders that turn
its instructions into bytes. It goes in its own module, and no stage above
instruction selection learns its name or its register numbers.

1. Read the architecture manual for the encodings, and say in the commit body
   which revision you followed.
2. Add the target description first, with the registers, the ABI and the
   relocations. An encoder that hard-codes what the description should answer is
   a second place for the same fact, and the two drift.
3. Test the encoding against an assembler that did not come from this tree, for
   every instruction the target claims. A round trip through your own decoder
   proves only that the decoder agrees.
4. Test a function end to end: compile it, link it with vlk, run it, and compare
   what it does with what the IR said.

## Adding an instruction

An instruction touches four places: the IR, the verifier's rule for it, the
selection that chooses it, and the encoder for each target that has it. A change
that lands three of the four is a function that compiles and does the wrong
thing, so the test belongs with the first of them. If a target has no encoding
for an instruction, selection refuses it by name rather than choosing a near
neighbour.

## Adding a test

Tests sit beside the module as `*_test.v`. A test has to fail when the code is
wrong: compare against something that did not come from this tree, meaning an
assembler, the manual, or a program that was written before it. A second copy of
the algorithm proves only that the copy agrees.

Never weaken a test, an assertion, or a diagnostic to make a change land. If the
behaviour change was intended, say so in the commit body and change the
expectation there.

## Prose and commits

`area: what changed`, lowercase, no trailing period, and a body that says why.
One logical change per commit, each one building on its own. Areas in use:
`tree`, `docs`, `tools`, `github`, and the name of the module a change lands in.

Comments, commit bodies, pull request text and the markdown here are read by
people. Write plain sentences with specific claims. No em dashes, no "serves
as", no bolded label at the start of every bullet, and no close that tells the
reader how to feel. When the claim is a measurement, print the number and the
command that produced it.
