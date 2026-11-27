package com.magicmaker.android

import android.app.Application
import com.magicmaker.android.core.CrashLog
import com.magicmaker.android.data.MagicStore
import com.magicmaker.android.sync.SyncDataModule
import com.magicmaker.android.sync.SyncPorts

class MagicMakerApp : Application() {
    lateinit var store: MagicStore
        private set

    override fun onCreate() {
        super.onCreate()
        CrashLog.install(this)
        store = MagicStore(this)
        // The sync data layer (identity, ledger, rows) for the sync runtime (SyncEngine).
        SyncPorts.install(SyncDataModule.create(this, store))
    }
}
