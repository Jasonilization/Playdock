# Add SteamStoreInfoCache.clearMemoryCache()

Drops every in-memory store-info result so the next info(for:) re-reads disk (or, once the on-disk cache is also wiped, re-fetches from Steam). First foundation piece for Settings' "Hard Refresh Game Info".
