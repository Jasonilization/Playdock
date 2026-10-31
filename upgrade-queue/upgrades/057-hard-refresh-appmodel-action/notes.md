# AppModel: hardRefreshGameInfo() action

The user-facing action: guards against re-entry, runs GameInfoCacheReset, stamps the timestamp, bumps gameInfoGeneration, then re-scans the library and profile so every card and detail view re-fetches straight from Steam.

Applies on top of: 054-hard-refresh-cache-reset-engine, 056-hard-refresh-appmodel-last-refresh-accessor
