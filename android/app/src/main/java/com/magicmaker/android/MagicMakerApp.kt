package com.magicmaker.android

import android.app.Application
import com.magicmaker.android.data.MagicStore

class MagicMakerApp : Application() {
    lateinit var store: MagicStore
        private set

    override fun onCreate() {
        super.onCreate()
        store = MagicStore(this)
    }
}
