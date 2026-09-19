# GameModeView: remove the legacy .sheet settings and its Form views

Drops showingSettingsSheet, the .sheet(isPresented:) modifier, and the now-unused DefaultSettingsSheet / SettingsRow / EngineUpdateSection Form views (superseded by SettingsPanelView).

Applies on top of: 118-gamemodeview-redirect-settings-triggers

Deletes DefaultSettingsSheet / SettingsRow / EngineUpdateSection. If any peer unit still edits those structs, ship this one AFTER that peer unit and re-generate. Contains only deletions of code SettingsPanelView replaces - safe once the GMV launcher scaffold + the two wiring units before it are in.
