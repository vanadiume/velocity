# Filing an issue

The tracker is at <https://github.com/vanadiume/velocity/issues>. Bugs, feature
requests and questions all go there: a question is an issue labeled `question`,
and a missing instruction or target is one labeled `enhancement`.

## Before you file

1. Search the open and closed issues. The same wrong encoding gets found twice.
2. Reduce the input. For a wrong encoding, the smallest function that still
   produces the wrong bytes. For a crash, the line that does it.

A missing instruction or target is a feature request, not a bug. File it and say
what you would use it for.

## What a report needs

- The commit you built from. There is no release yet.
- Your OS and architecture, and the `v version` that built the library.
- The target: machine, system and ABI.
- The IR, or the V program that builds it, small enough to paste.
- What came out: the bytes, a disassembly, or the exit status.
- What you expected instead, and the document or assembler output that says so.

Three shapes of report are common enough to describe on their own.

A wrong encoding is bytes that mean a different instruction, or an instruction
that means something other than what the IR says. Paste the bytes and the
disassembly, and the assembler command that disagrees if you have one.

A verifier gap is a function the verifier accepts and should not, or refuses and
should not. Paste the function and the rule you think it gets wrong.

A crash is a panic, a hang, or a file written when the call failed. Paste the
panic output, and for a hang the input that loops.

## Out of scope

- Bugs in V.
- Bugs in the program the emitted code belongs to.
- Instructions and targets that are not implemented yet. Those are feature
  requests.
- Support for using the library in your compiler. That is a question, and it
  belongs in an issue with the `question` label.

## Security

Do not file a vulnerability as an issue. SECURITY.md says what counts and where
to send it.
