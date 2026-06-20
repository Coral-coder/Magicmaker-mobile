package com.magicmaker.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.magicmaker.android.ui.AppTheme
import com.magicmaker.android.ui.MagicMakerAppRoot
import com.magicmaker.android.update.AppUpdater

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            AppTheme { MagicMakerAppRoot() }
        }
    }

    override fun onResume() {
        super.onResume()
        // OTA: check for a newer build each time the app comes to the foreground.
        AppUpdater.checkForUpdate(this)
    }
}
