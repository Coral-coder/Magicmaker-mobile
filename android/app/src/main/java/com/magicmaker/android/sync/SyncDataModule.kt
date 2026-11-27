package com.magicmaker.android.sync

import android.content.Context
import com.magicmaker.android.data.MagicStore

/**
 * Part 1's [SyncData] (plan §4.10): the identity MagicStore loaded, the store's [LibrarySync], and
 * factories for the per-service-start models. Installed by `MagicMakerApp.onCreate` through
 * [SyncPorts.install].
 */
class SyncDataModule(private val identityFile: SyncIdentityFile, override val library: SyncLibraryPort) : SyncData {
    override val identity: SyncIdentityPort get() = identityFile

    override fun startEventOrigin(nowMs: Long, ringCap: Int): EventOriginPort {
        val epoch = identityFile.startEpoch(nowMs)
        return EventOrigin(identityFile.deviceId, epoch, ringCap)
    }

    override fun newRuntimeEstimator(): RuntimeEstimatorPort = RuntimeEstimator()

    override fun newRoster(): DeviceRosterPort = DeviceRoster()

    companion object {
        @Suppress("UNUSED_PARAMETER")
        fun create(context: Context, store: MagicStore): SyncDataModule = SyncDataModule(store.syncIdentity, store.sync)
    }
}
