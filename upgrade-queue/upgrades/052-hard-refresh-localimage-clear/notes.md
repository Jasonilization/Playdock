# Add LocalImageCache.clear()

Drops every decoded bitmap so re-downloaded art at the same file path isn't masked by the previous decode still sitting in memory. Foundation piece for "Hard Refresh Game Info".
