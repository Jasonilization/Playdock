# SettingsPanelView: Hide Library Badges toggle

Adds a 'Hide Library Badges' toggle to the Personalization tab, bound to GameModeView.hideBadgesKey.

Applies on top of: 110-settings-panel-personalization-tab, peer:011-hide-badges-setting-ui

Binds `@AppStorage(GameModeView.hideBadgesKey)`. That key is defined by the peer's unit 011-hide-badges-setting-ui. This unit does NOT compile standalone on 8ceb2c2 - it needs peer 011 (or any unit that introduces `GameModeView.hideBadgesKey`) shipped first. Ship order: peer 011 -> the Personalization-tab unit -> this one. If 011's key name/type changes, rebase this one-line `@AppStorage` + the SettingsCard block at ship time.
