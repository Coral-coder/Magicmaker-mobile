package com.magicmaker.android

import android.app.Application
import com.magicmaker.android.core.CrashLog
import com.magicmaker.android.data.MagicStore

class MagicMakerApp : Application() {
    lateinit var store: MagicStore
        private set

    override fun onCreate() {
        super.onCreate()
        CrashLog.install(this)
        store = MagicStore(this)
    }
}
