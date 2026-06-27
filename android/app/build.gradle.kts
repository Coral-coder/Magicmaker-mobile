plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.magicmaker.android"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.magicmaker.android"
        minSdk = 26
        targetSdk = 34
        // OTA: version is overridable from CI so each cloud build is a new,
        // higher version that the in-app updater can detect.
        //   ./gradlew assembleRelease -PmmVersionCode=42 -PmmVersionName=1.0.42
        versionCode = (project.findProperty("mmVersionCode") as String?)?.toInt() ?: 1
        versionName = (project.findProperty("mmVersionName") as String?) ?: "1.0.0"

        // OTA: GitHub-Releases updater. Token is injected at build time (CI secret or
        // local gradle property) and embedded in BuildConfig — never committed. Empty
        // token => updater is dormant (local/debug builds).
        val updateToken = (project.findProperty("mmUpdateToken") as String?) ?: ""
        val updateRepo = (project.findProperty("mmUpdateRepo") as String?) ?: "Coral-coder/Magicmaker-mobile"
        buildConfigField("String", "UPDATE_TOKEN", "\"$updateToken\"")
        buildConfigField("String", "UPDATE_REPO", "\"$updateRepo\"")

        // Cloud packet dictionary: write-scoped token + dedicated repo for the shared
        // packets.csv. Injected at build time, never committed. Empty token => dormant.
        val backupToken = (project.findProperty("mmBackupToken") as String?) ?: ""
        val backupRepo = (project.findProperty("mmBackupRepo") as String?) ?: "Coral-coder/magicmaker-backups"
        buildConfigField("String", "BACKUP_TOKEN", "\"$backupToken\"")
        buildConfigField("String", "BACKUP_REPO", "\"$backupRepo\"")
    }

    // OTA: a stable release signing key is REQUIRED — Android rejects an update
    // whose signature differs from the installed build. The key never lives in
    // the repo; it is supplied via env vars (CI secrets / local.properties).
    signingConfigs {
        create("release") {
            val storePath = System.getenv("MM_KEYSTORE_FILE")
            if (!storePath.isNullOrBlank() && file(storePath).exists()) {
                storeFile = file(storePath)
                storePassword = System.getenv("MM_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("MM_KEY_ALIAS")
                keyPassword = System.getenv("MM_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Only attach the release signing config when a keystore is provided,
            // so unsigned/local builds still succeed without secrets.
            if (!System.getenv("MM_KEYSTORE_FILE").isNullOrBlank()) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.8"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("androidx.lifecycle:lifecycle-service:2.7.0")
    implementation("androidx.activity:activity-compose:1.8.2")
    implementation(platform("androidx.compose:compose-bom:2024.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    implementation("com.google.code.gson:gson:2.10.1")
    implementation("com.google.zxing:core:3.5.3")
    // OpenStreetMap map view for the capture map (no API key required).
    implementation("org.osmdroid:osmdroid-android:6.1.20")
    debugImplementation("androidx.compose.ui:ui-tooling")
    // OTA uses the GitHub Releases API via HttpURLConnection + org.json — no extra deps.
}
