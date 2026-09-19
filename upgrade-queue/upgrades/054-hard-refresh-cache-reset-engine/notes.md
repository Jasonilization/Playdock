# Add GameInfoCacheReset engine

The engine behind "Hard Refresh Game Info": wipes Playdock's own downloadable game metadata + art (in memory via the three new clear() calls, on disk by removing its two cache folders). Deliberately never touches Steam's own appcache/librarycache.

Applies on top of: 051-hard-refresh-steamstoreinfo-clear-memory, 052-hard-refresh-localimage-clear, 053-hard-refresh-gameartcolor-clear-cache
