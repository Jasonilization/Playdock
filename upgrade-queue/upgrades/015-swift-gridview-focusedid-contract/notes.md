# Repair: 2026-10-04

## Symptom

Every dry-run and ship of this upgrade failed at the `swift build -c release` gate with
`GameModeView.swift:270: the compiler is unable to type-check this expression in reasonable time`.
The dashboard showed only index-path spam (the engine keeps the last 4000 chars of output,
which for Swift build failures is the tail of the compile commands, not the error).

## Root cause

This patch renamed `SkinWebGridView.focusedIndex` to `focusedID` but did not touch the one
existing call site (`GameModeView.swift`, `SkinWebGridView(... focusedIndex: focusedCardIndex ...)`).
Applied alone on HEAD, no initializer matched the call, and instead of a clean "extra argument"
diagnostic the type-checker ground to a halt inside the large `GeometryReader` expression and timed
out. The upgrade that fixes the call site properly (017) sits *behind* this one in the DAG, so
nothing could ever ship: 015 failed its own gate, and 121 upgrades queued behind it were stuck.

## Fix

Added a temporary `init(skin:entries:userName:isDark:focusedIndex:onOpen:)` in an **extension**
(extensions don't suppress the memberwise init), translating the positional index to the focused
entry's real id via `focusedIndex.flatMap { entries[safe: $0]?.id }` - so the ring lands on the
right card with 014's by-id JS, and the call site is untouched textually (017's GameModeView hunks
apply cleanly later). 017 deletes the bridge when its by-id call site lands; the queue's final state
is byte-for-byte unchanged (this 015 + new 017 postimage blob == 133's preimage blob).

## Validation

- dry-run of this upgrade on HEAD: applies, `swift build -c release` + `swift test` green.
- dry-run of 017 (applies this upgrade as its one unshipped ancestor first): green.
- HEAD + this + 016 (016's real ship-gate tree): `swift build` + `swift test` green.
- HEAD + this + 016 + 017 (017's real ship-gate tree): `swift build` + `swift test` green.
- All 109 unshipped patches (015-135) still apply cleanly in topo order on HEAD.
