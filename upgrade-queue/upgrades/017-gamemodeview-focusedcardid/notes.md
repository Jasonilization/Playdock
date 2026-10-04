# Repair: 2026-10-04

Regenerated together with 015 (see its notes for the full story): 015 renamed the grid's focus
contract without keeping its only call site compiling, so it could never build standalone. 015 now
carries a temporary `init(focusedIndex:)` bridge in an extension; **this upgrade removes that
bridge** now that its last caller is gone, so no dead code survives the sequence.

- GameModeView.swift hunks: unchanged from the original patch.
- SkinWebGridView.swift hunk: new, deletes the extension block added by the repaired 015.
- `files[]` gained `Sources/ExeDock/Support/SkinWebGridView.swift` to match.
- Postimage blob of SkinWebGridView.swift is byte-identical to the original 017's (`0ab8a7ed...`,
  which is also 133-favorites-ui-everywhere's preimage), so the assembled final state of the whole
  queue is unchanged.

Validated: dry-run of this upgrade (applies 015 as its one unshipped ancestor first) builds and
tests green; HEAD + 015 + 016 + 017 (its real ship-gate tree) builds and tests green; all 109
unshipped patches still apply cleanly in topo order on HEAD.
