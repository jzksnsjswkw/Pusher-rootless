# Running Shortcuts: where this came from

This project runs one of the user's Shortcuts when a notification arrives. There
is no public API for that, so the implementation in
`Sources/Core/Runtime/ShortcutRunner.m` rests on private framework behaviour that
was worked out by reading those frameworks and then testing on a device. Nothing
in it is copied from another tweak, and this project does not depend on one. This
file records what was consulted, so that a reader — and anyone with a claim to
that work — can see exactly what the relationship is.

## What was consulted

**Apple's own code.** The relevant classes and selectors are Apple's, not anybody
else's: `WFWidgetWorkflowRunnerClient`, `WFShortcutsAppRunnerClient`,
`WFWorkflowRunRequest`, `WFContentCollection`, `WFWorkflowRunDescriptor`. They
were read out of `VoiceShortcutClient.framework` and `WorkflowKit.framework` with
IDA and confirmed at runtime with Frida. The one that matters most —
`-[WFWorkflowRunRequest archivedInput]` — is a private method on an Apple class
that is intercepted so the input can reach the daemon that runs the workflow.
Anyone solving this problem finds the same method, because it is the only one that
carries the input across that boundary.

**SpringCuts** (`com.anthopak.springcuts`, by AnthoPak) was consulted as a
*reference point*: it establishes that the capability is possible at all, and that
the `archivedInput` interception is the way in, which saved a great deal of trial
and error. It is a free, closed-source jailbreak tweak distributed through
`repo.anthopak.dev`. Its package description documents its command-line interface
and states that it "also serves as a lightweight support library for tweaks that
need to run Shortcuts" — so the interface is documented by its author, and this
project did not need to reverse-engineer an interface that was already described.

A compatibility shim for iOS 17's renamed initializer was also noted, in a
published package by Hetyey. This project does **not** use that approach and does
not contain it; see the note below.

## What this project does not use

| | SpringCuts | This project |
|---|---|---|
| A separate binary or helper | CLI plus two dylibs, injected into `siriactionsd` | none |
| Communication | Darwin notifications between its own processes | direct XPC calls |
| Runtime dependency | — | **none** |
| Code | closed source | none of it here |
| Name, identifier, artwork | — | none of it here |

The two implementations differ in structure rather than in a renamed variable:
SpringCuts shells out to a command-line tool which hands the request to a runner
inside `siriactionsd` through a notification; this project calls the XPC service
directly from SpringBoard. That difference is also why a fix SpringCuts needs does
not apply here — see below.

## The iOS 17 initializer

`-[WFWidgetWorkflowRunnerClient initWithWorkflowIdentifier:]` gained a `location`
parameter in iOS 17. A published compatibility shim re-adds the old method to the
system class and forwards to the new one. This project instead tries both
spellings at the call site: on iOS 16 the first is found and nothing changes, and
on iOS 17 the second is used.

That choice was made on its merits — the call site is ours, so adapting it needs
no reasoning about `init` ownership, whereas re-adding the method to a class we do
not own does. The shim's existence is acknowledged here because it is where the
renamed selector became known.

## A failure mode that does not apply here

A published port of this capability reports that requests are silently lost when
`siriactionsd` has been stopped, because a notification cannot start a process.

This project does not have that problem: it calls the XPC service directly, and
launchd starts the daemon on demand. Confirmed on the device by killing
`siriactionsd` and watching it come back and run the Shortcut. The report is
mentioned here so that a reader comparing the two does not port a fix this
implementation does not need.

## If you are the author of SpringCuts

If you believe anything here goes beyond using your work as a reference, open an
issue and it will be changed or removed.

## Licensing note for this repository

`reverse/` — kept locally for analysis, and not tracked by git — holds binaries
that are not this project's to redistribute: the Shortcuts app, and other
people's tweak packages. See `.gitignore`.
