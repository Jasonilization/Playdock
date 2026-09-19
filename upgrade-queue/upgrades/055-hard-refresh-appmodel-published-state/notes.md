# AppModel: hard-refresh published state

Adds isHardRefreshingGameInfo (drives the Settings button spinner, blocks re-entry) and gameInfoGeneration (bumped when a refresh finishes; views keyed on entry id watch it to re-resolve art/description from scratch).
