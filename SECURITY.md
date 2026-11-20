# Security policy

## Supported versions

There is no release yet. `main` is the development tree and the only version
that gets fixes.

| Version | Supported |
|---|---|
| `main` (unreleased) | Development. Fixes land here. |
| Tagged releases | None yet. |

## What counts as a vulnerability here

Velocity turns IR into machine code. Its threat surface is the caller's input and
the bytes it writes, which is shorter than an application's.

- A silent miscompilation: IR the library accepts, with no diagnostic, that
  produces instructions doing something other than what the IR says. This is
  the worst outcome available, because it puts a wrong program behind a build
  that looked fine. It stays this when the wrong code shows on only one input.
- A verifier that passes a function it should refuse. The verifier is the only
  stage between a front end's bug and an encoder reading a value that is not
  there.
- Memory unsafety in the library: an integer overflow in an offset or a
  displacement, a write past a buffer in an encoder, or a length from the
  caller used as an index. The encoder writes raw bytes and computes field
  widths by hand, which is where this lives.
- Code execution or file access driven by the caller's input: IR, a target
  description, or, once there is a textual form, a file that makes the library
  run a program or write outside the path it was given.
- Reproducibility failures with a security consequence: the same IR and target
  emitting different bytes in a way that lets one build differ from the build
  someone reviewed.

## What does not count

- Bugs in the program the emitted code belongs to. A code generator is not a
  sandbox; it emits what it is asked to emit.
- Bugs in V, in the assembler or linker used to check the output, or in the
  architecture's own documentation.
- Resource exhaustion from IR you chose to hand a library that does not claim to
  be hardened.
- An instruction or a target that is not implemented yet. That is a feature
  request, and ROADMAP.md says what is coming.

## Reporting

Privately, through GitHub's private vulnerability reporting:

<https://github.com/vanadiume/velocity/security/advisories/new>

Use it rather than a public issue for anything in the list above. If you cannot
use GitHub, email huntedbyth3irs@gmail.com, the address this repository's
commits carry.

A useful report has the IR or the V program that builds it, the target, the
bytes that came out, and a sentence about what those bytes do differently from
what the IR says. A disassembly of the wrong instruction is worth more than a
description of it.

What to expect: an acknowledgment within a few days, an assessment of whether it
is in scope and how severe it looks, and a fix on `main` with the advisory
published once it is out.

## Scope

The library is a model and a set of stages, and only some of them exist. A
report about a stage that is still a paragraph in ROADMAP.md is welcome, and
better written down before the code that makes it true exists.
