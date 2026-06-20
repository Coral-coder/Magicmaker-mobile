plugins {
    id("com.android.application") version "8.2.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
    // OTA: Google Services plugin is needed to process google-services.json for
    // Firebase App Distribution. Applied conditionally in :app (only when the
    // config file is present) so local debug builds work without Firebase setup.
    id("com.google.gms.google-services") version "4.4.1" apply false
}
