# Curated rebase resolution for 119-gamemodeview-remove-legacy-settings-sheet

File: `Sources/ExeDock/Views/GameModeView.swift`

Conflict character: 119 deletes the legacy `DefaultSettingsSheet` (and the `SettingsRow`
enum) wholesale; the stacked queue state at that point additionally contained 011's
"Hide Library Badges" section INSIDE that sheet. Deleting the whole sheet therefore also
removes 011's in-sheet additions. This is the intended semantic: the toggle is re-provided
inside the new SettingsPanelView by 111-settings-panel-hide-badges-toggle (which already
depends on 011, since it binds the same `GameModeView.hideBadgesKey` that 011 created and
which stays). 011's own contribution (the storage key + `@AppStorage`) sits outside the
sheet and survives untouched.

Resolution: conflict region resolved to THEIRS (119's complete deletion of the legacy
sheet block, replaced by the `// MARK: - Per-game settings popover` boundary).
