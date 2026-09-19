Risk: medium, and the `tests` field above is honest about why: Ship Manager's dashboard always
runs `swift build -c release` + `swift test` before letting you commit, but this change touches
zero Swift code - that check will trivially pass without actually validating anything real here.

What's actually verified: `bash -n` syntax-checked clean. What's NOT verified: I deliberately did
not run this live in this session - it mounts/ejects a real DMG volume and drives Finder via
AppleScript, and this same sandboxed environment hit a genuine 2-minute hang earlier this session
on a much simpler Finder/Chrome AppleScript query (likely an Automation-permission prompt with
nothing there to answer it). Rather than risk repeating that (or worse, leaving a stray mounted
volume), this needs a real local run before shipping:

```
./Scripts/build_app.sh
./Scripts/make_dmg.sh 0.0.0-test
open dist/Playdock-0.0.0-test.dmg   # confirm: sized window, Playdock.app and Applications
                                     # positioned side by side, no leftover mounted volume
rm dist/Playdock-0.0.0-test.dmg
```

Drop to low risk once you've done that once successfully.
