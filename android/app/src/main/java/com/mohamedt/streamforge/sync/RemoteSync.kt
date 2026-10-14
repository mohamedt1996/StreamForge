package com.mohamedt.streamforge.sync

/**
 * Called by every store (Library, Addons, DispatcharrRepo, Settings) after it saves a change.
 * ServerSync diffs the local records against what it last synced, so callers never need to say
 * what changed; deletions become tombstones automatically.
 */
object RemoteSync {
    fun changed() = ServerSync.noteChange()
}
