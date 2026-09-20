# Playdock

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Wiki](https://img.shields.io/badge/docs-wiki-informational.svg)](https://github.com/Jasonilization/Playdock/wiki)

A Mac dashboard for the Windows games (and programs you might want to run) you're already running through Wine - built
on top of the Sikarugir engine.

Steam is the main feature here: install it once, and Playdock shows your library as a proper grid -
box art, a short description, your account's name and avatar - with a big icon you double-click to
open Steam itself, same as you would on the desktop. Drag-and-drop `.exe` support is still in here
too, tucked under "Exe Loader" in the sidebar for when you just need to run something once.

## NOTICE: Due to skool reasons, Playdock would have a much slower rate of development. Playdock is still actively being worked on, but updates will be more irregular and shipped long-term through Ship Manager rather than on a regular schedule. Thanks to everyone who’s liked, used, or followed this lil side project ❤️

## Screenshots

<img src="docs/screenshots/terminal-grid.png" alt="Playdock's Grid layout in the Terminal skin, showing a mixed library with Mac and Custom badges" width="800">

<details>
<summary>More screenshots (Steam-style, Carousel)</summary>
<br>

<img src="docs/screenshots/soft-steam-style.png" alt="Steam-style layout in the Soft skin" width="800">

<img src="docs/screenshots/minimal-carousel.png" alt="Carousel layout in the Minimal skin" width="800">

</details>

## Installing

**Homebrew:**

```sh
brew install --cask jasonilization/playdock/playdock
```

**Manual:** grab the `.dmg` from [Releases](../../releases) and drag the app into `/Applications`.

Either way, it's signed with a free Apple Development identity rather than a paid Developer ID, so
it's not notarized - Gatekeeper will call it out as being from an unidentified developer on first
launch. Right-click the app → **Open**, or go to settings, and under privacy and security, click *open anyways*. 
You can also do this in the terminal via:

```sh
xattr -dr com.apple.quarantine "/Applications/Playdock.app"
```

Nothing else to install - Playdock downloads and sets up its own Wine engine and runtime libraries
automatically on first launch. If Sikarugir Creator is already installed with an engine downloaded
(`~/Library/Application Support/Sikarugir/Engines/`), Playdock reuses that instead.

## Contact & Support

**thesuperjasonprocoolisplay@hotmail.com**

Found a bug or want a feature? Open an [issue](../../issues) - that's the fastest way to get it
seen and tracked.

## Why this exists

Wine wrapper tools are great once you've built a wrapper. But "I just installed a game in Steam,
why do I need to build anything" is a real gap, and that's what this fills - point it at a Steam
bottle and it just works, no per-game setup. This means you won't have to do all the messy configuration
steps in sikarugir.

## How it fits with Sikarugir

Playdock doesn't reimplement Windows compatibility - it reuses whatever Wine engine Sikarugir
Creator has already downloaded to `~/Library/Application Support/Sikarugir/Engines/`, extracting
its own private copy of it. Everything Playdock touches under `~/Library/Application
Support/ExeDock/` is its own - a separate bottle for Steam, a separate default bottle for
everything else - so it never writes to, or otherwise disturbs, Sikarugir Creator or any wrapper
app it's already built. (Yes, the folder's still called `ExeDock` internally - that's what this
project used to be called before the Steam-first rework, and renaming it on disk would silently
orphan anyone's existing bottles. Not worth it for a folder name nobody sees.)

If you need per-app engine builds, a specific DXVK/MoltenVK combo, or want to hand someone a
distributable wrapper for one program, that's still Sikarugir Creator's job - Playdock is the
"just let me play my games" layer on top, not a replacement for it.

Sikarugir Creator itself has to be installed by you - there's no real download URL for it baked
into this app on purpose. Guessing at one and silently fetching it felt like a bad idea, so if it's
missing, Playdock just tells you and waits.


## What it does

- **Steam dashboard** - your installed games as cards (art + description pulled from Steam's public
  store API, cached locally), your account name/avatar read straight out of Steam's own local
  config, double-click the Steam icon to launch it. Games installed through the real, separate
  macOS Steam client show up right alongside your Windows-via-Wine library too.
- **Custom Game Library** - import any Windows game folder (or a lone `.exe`) that isn't on Steam.
  Import moves it into Playdock's own managed bottle automatically, so it launches through the same
  engine as everything else - no per-game setup.
- **Advanced Mode** (off by default) - per-game engine/graphics/sync overrides, for the handful of
  games that actually need something different from your defaults.
- **Exe Loader** - drag an `.exe` onto the window, or browse any bottle's C: drive Finder-style
  under the C: Drive tab.
- **Controller support** - a full D-pad/A/B focus loop across the dashboard, detail pages, and a
  dedicated Controller Mode carousel - not just one screen.
- **Setup that gets out of your way** - on first launch it finds/extracts an engine and sets up its
  own bottle automatically; if Sikarugir Creator has more than one engine downloaded, it asks which
  one to use (with a recommended pick) instead of silently guessing.

## Building from source

No Xcode required, just Swift + Command Line Tools:

```sh
./Scripts/build_app.sh        # swift build -c release, assemble Playdock.app, codesign
./Scripts/make_dmg.sh X.Y.Z   # package dist/Playdock-X.Y.Z.dmg
```

## What's new

**Real per-skin visual identity + library layouts (1.2.0)** - the dashboard's "Library Look" setting
(Settings → Library Look) now has real teeth: 6 structurally different layouts (Grid, Shelves,
Sidebar, Steam-style, Carousel, Spotlight) and 6 real visual skins (Luxury, Brutalist, Terminal,
Soft, Pixel, Minimal), each rendering the actual mockup HTML/CSS it was designed from rather than an
approximation - genuinely different worlds, not the same cards recolored. Grid is rendered by a real
embedded browser view running the original mockup markup directly; every other layout ports each
skin's own card shape, shadow language, button recipe, and art treatment (down to Terminal's
scanning CRT overlay) so nothing looks like "just a wallpaper and a font" next to Grid. Every card,
in every layout, shows a real per-skin action button with genuine raised, tactile depth - not a flat
color fill - matching Grid's own real cards. Cards and buttons can also pick up a subtle tint from
each game's own artwork. Every skin supports both light and dark appearance and follows the system
setting. Also in this release: a first-launch setup wizard for
picking a look, a working search bar and sticky top bar, real Steam box art support, custom games'
small icons showing real art instead of placeholder colors, zero-manual-setup installs (Playdock
downloads its own Wine engine and runtime libraries automatically), and the old redundant "Library"
tab (superseded by Game Mode's own dashboard) is gone.

**Custom Game Library + native macOS Steam games (1.1.0)** - a Custom Game Library for anything
that isn't on Steam, native macOS Steam games showing up alongside your Wine library, a visible
"launching…" screen for every game (not just Steam ones), and full controller navigation across
the whole app.

**Steam-first rework** - the app used to be a generic exe launcher first, with Steam bolted on as
one feature (back when it was still called ExeDock). This flips that: Steam's dashboard is now the
default screen, with real account/game data pulled locally, per-game settings for anyone who wants
them, and a launch flow that no longer occasionally starts Steam twice (a real bug from an earlier
build - a retry heuristic was misreading Steam's normal "already running, handing off" exit as a
failure and launching a second copy on top of it).
