# AGENTS.md

Instructions for coding agents working in this repository. They are the rules a
person follows, written where a tool will read them. `CONTRIBUTING.md` is the
human-facing version.

## What this repository is

Velocity is a code generation library written in V. A front end hands it typed IR
and names a target, and it answers with machine code, plus the data and
relocations that code needs to become part of a program. The output is a
relocatable object. Linking is vlk's job, and this library does not write an
executable.

A library, not a program: there is no `main`, the root package is `module
velocity`, and the command line tools that drive it are separate projects. It is
published to vpm with a `v.mod` at the root, so the module layout is not free:
`velocity` at the root, one directory per module, each declaring the directory's
own name. The registry entry is `vanadiume.velocity`, imported as
`vanadiume.velocity`, and a module in a directory is imported by its full path
(`vanadiume.velocity.<module>`). Every file imports by that path, because a bare
`import ir` is resolved by its last segment against every module in the build and
a consumer that already holds a module of that name would have its own called
instead. The checkout therefore has to be reachable at
`~/.vmodules/vanadiume/velocity`, which `CONTRIBUTING.md` says how to arrange.

## The constraints

1. **V first.** The library is written in V, and V is the default answer for
   every piece: the IR, the verifier, selection, allocation, the encoders, and
   the driver. C interop is allowed where V cannot express the piece or the
   platform interface is the C one. It is an exception, kept to the file that
   needs it, with the reason in the commit body. It is not a shortcut around a
   piece of V that is merely unwritten.

2. **The emitted bytes are the product, and they are checked against something
   outside this tree.** An instruction is checked against the architecture manual
   or an assembler's encoding; a function against a program that runs. A second
   copy of the encoder in V proves only that the copy agrees. Never claim an
   encoding is correct from the shape of the code.

3. **No garbage collector.** The library is compiled into compilers that are
   built with `-gc none`, so nothing here may depend on a collection running. A
   buffer belongs to whoever allocated it and is handed on. The gate runs the
   suite both ways, so leaning on the collector fails a step here instead of
   failing a consumer's build later.

4. **Cross-platform is a property of the model.** Every machine fact comes from
   the target description: register numbers, page size, relocation kinds, the
   ABI, the pointer width. A stage that names one target is a design problem,
   even when that target is the only one implemented.

5. **Determinism.** The same IR and the same target produce the same bytes on
   every run. Nothing iterates a map where the order can reach the output.

## Commands

```sh
v test .                  # the suite; a test sits beside the module it tests
v -gc none test .         # the same, with no collector: the way a consumer is built
v run tools/gate.vsh      # formatting, both suites, links between documents
v fmt -w .                # format before committing
```

The gate is what a pull request has to pass. Run it before claiming a change is
done rather than after CI says otherwise. Compiling or testing a tree you did not
just write: cap the compiler, so a parse loop cannot take the machine down.

```sh
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 v test .
```

## Where things go

| Where | Rule |
|---|---|
| the root package | the entry a caller is written against: the types and the call that runs the pipeline. Nothing else belongs here, because this is the file a caller's code is compiled against. |
| one module per stage | a stage reads the form the previous stage answers and writes the next one. A stage that imports a later one is a design problem, not an import to add. |
| target descriptions | machine and system facts as data, one module per target. No stage above selection names a register, a page size or a relocation kind. |
| `tools/` | the gate. Not part of the library and not imported by it. |
| tests | beside the module as `*_test.v`. A test that needs an object or a listing writes it at test time, so the repository holds no binary fixture. |

## What this is working toward

One front end can build IR, verify it, and get machine code that runs on one
target, with the object linked by vlk. The model has to be right for a second
target before that target is written, so a change is judged by whether it moves
the first program closer, or makes a stage honest for a machine nobody has added
yet.

## Verification

- Run the artifact, do not infer it. An encoder is verified by disassembling its
  bytes with a tool that did not come from this tree, and by running the program
  they belong to.
- Build IR the way a front end would. A test that hand-builds a function no
  caller could produce tests a path that does not exist.
- An error is part of the interface. IR the library cannot lower exits with the
  function, the instruction and the reason. A silently emitted near-neighbour
  instruction is the worst outcome available and is treated as a bug.
- V caches aggressively. `-nocache` on a probe run, and remember that a binary
  built before an edit reports the previous source's problems.
- Long and malformed input are both test cases. A value out of range for its
  type, a block that does not exist, an empty function, and a function with ten
  thousand blocks are all things the stages have to answer without crashing.
- Run the same input twice and compare the bytes. Determinism is cheap to check
  and expensive to notice later.

## Agent working state

Anything written for one agent run lives in `.omh/`, which is git-ignored: plans,
probes, captured matrices, review notes and scratch. None of it is committed, and
no harness, lane checklist or golden generator written to check a single change
belongs in this tree. A repository keeps the tests its maintainers will run.

## Prose

Comments, commit bodies, pull request text and the markdown here are read by
people. Write them the way you would say them out loud: plain sentences,
specific claims. This binds text an agent writes as much as text a person
writes.

- No em dashes. A comma, a colon, or a full stop is usually what was meant.
- No "serves as", "stands as", or the vocabulary that inflates what code does
  into what it means.
- No three-item list assembled to sound thorough, and no synonym carousel where
  one thing is first a layer, then a stage, then a component.
- No bolded label at the start of every bullet, no signposting before the
  point, and no upbeat close.
- When the claim is a measurement, print the number and the command that
  produced it. An adjective is not evidence.

## Commits

`area: what changed`, lowercase, no trailing period, and a body that says why.
One logical change per commit, each one building on its own. Areas in use:
`tree`, `docs`, `tools`, `github`, and the name of the module a change lands in.

## Do not

- Add a dependency to `v.mod` without raising it first. Empty dependencies is
  the default here.
- Reformat or refactor files the change does not touch.
- Weaken a test, an assertion, or a diagnostic to make a change land.
- Commit a binary fixture, or a generator written to check one change.
- Let a stage read a target's constants directly, or reach for an outside
  assembler at run time when the library is the thing that should encode.
- Add C interop where V can do the job.
