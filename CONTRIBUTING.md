# Contributing to Playdock

Thanks for considering it. This is a small, mostly solo-maintained project, so keep expectations
casual - there's no formal RFC process, just open an issue or a PR.

## Before you start

For anything more than a small fix, open an issue first describing what you want to change. Saves
everyone the disappointment of a big PR that doesn't fit the project's direction.

## Building from source

No Xcode required - this machine's own dev setup is Command Line Tools only, and the project is
built that way on purpose so anyone can build it the same way:

```sh
git clone https://github.com/Jasonilization/Playdock.git
cd Playdock
./Scripts/build_app.sh        # swift build -c release, assemble Playdock.app, codesign
```

That produces `build/Playdock.app`. To package a `.dmg` the way releases ship:

```sh
./Scripts/make_dmg.sh X.Y.Z   # -> dist/Playdock-X.Y.Z.dmg
```

The first time you run the built app, it downloads and sets up its own Wine engine and runtime
libraries automatically - nothing else to install first. If [Sikarugir
Creator](https://sikarugir.app) is already installed with an engine downloaded
(`~/Library/Application Support/Sikarugir/Engines/`), Playdock reuses that instead.

Run the test suite with:

```sh
swift test
```

## Project conventions worth knowing before you dig in

- **No `@State`.** This machine's toolchain can't compile SwiftUI's `@State` macro (the compiler
  plugin isn't available outside Xcode.app). Every view in this codebase uses the project's own
  `@LocalState` property wrapper instead (`Sources/ExeDock/Support/LocalState.swift`) - it's a
  drop-in replacement, same call sites, just without the macro. Use it anywhere you'd normally
  reach for `@State`.
- **Real evidence over guessing.** UI bugs get diagnosed by actually building and screenshotting
  the real app, not by reading the code and assuming. If you're fixing something visual, a
  before/after screenshot in the PR description goes a long way.
- **Comments explain *why*, not *what*.** The code should already say what it does; a comment
  earns its place by explaining a non-obvious reason, a real bug it's working around, or a piece
  of live user feedback that shaped the decision. Skip comments that just restate the line below
  them.
- **Never write into a wrapper app.** Anything under `~/Applications/Sikarugir/*.app` is a Sikarugir
  Creator wrapper and is treated as strictly read-only everywhere in this codebase - Playdock only
  ever reads from it. Playdock's own state lives entirely under `~/Library/Application
  Support/ExeDock/` (yes, still named `ExeDock` internally - see the README for why that's
  deliberate).
- **The six skins live in `Sources/ExeDock/Resources/SkinTemplate/`** (`skins.css` + `skins.js`),
  rendered by a real `WKWebView` for the Grid layout (`SkinWebGridView.swift`) and, for Steam-style/
  Spotlight's own card-grid sections, a lighter fragment of the same real markup
  (`SkinWebGridFragmentView.swift`) - not hand-approximated in SwiftUI. If you're adding or tweaking
  a skin's *look*, edit `skins.css`/`skins.js` directly; the three remaining native-SwiftUI layouts
  (Shelves, Sidebar, Carousel) read the same tokens back out through
  `Sources/ExeDock/Support/DesignSystem.swift` (`cardSurface()`/`tileSurface()`/
  `playdockButtonLook()`), so a real skin change belongs in the CSS/JS first and gets ported into
  that file to match, not invented there independently. Changes take effect on the next
  `./Scripts/build_app.sh` (no Xcode preview available on this toolchain, so testing means an
  actual rebuild + relaunch).

## Shipping small changes (maintainer workflow)

Real, independently-reviewable changes get prepared as small "upgrades" under `upgrade-queue/`
(each one is `meta.json` + a real `patch.diff` + `notes.md`) rather than committed straight to
`main`. `./Scripts/ship_manager.sh` launches a local dashboard (`http://127.0.0.1:8765`) to
browse/search them, dry-run one in an isolated `git worktree` (build + test, main tree untouched),
and ship one for real - a two-phase apply → build → test → review-the-diff → confirm-commit flow,
never a silent auto-commit. See `upgrade-queue/ship_manager/README.md` for the full contract.

## Pull requests

- Keep PRs focused - one fix or one feature, not a grab-bag.
- Match the existing code style (see the conventions above).
- If you touched anything visual, include a screenshot.
- Update `README.md`'s "What's new" section if the change is user-facing.

## Reporting bugs / requesting features

Use the issue templates - they ask for the specifics that actually help (macOS version, what you
expected vs. what happened, whether it's reproducible). For anything security-related, see
[SECURITY.md](SECURITY.md) instead of opening a public issue.
