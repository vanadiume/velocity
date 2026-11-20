# velocity

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
