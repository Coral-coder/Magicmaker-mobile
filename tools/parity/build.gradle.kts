// Writes ios/ParityCheck/vectors.json: the Android core's answers for a fixed set of packets,
// which the Swift core is then checked against (ios/ParityCheck/main.swift).
//
// The Android core is compiled from where it lives, not copied. Regenerate with
//   cd tools/parity && ../../android/gradlew --no-daemon -q run
// Any Gradle 8.x works in place of the wrapper (its Gradle 8.2 needs JDK 17 to 20; on a newer
// JDK use a newer Gradle: `gradle --no-daemon -q run`).

plugins {
    kotlin("jvm") version "1.9.22"
    application
}

repositories {
    mavenCentral()
}

kotlin {
    sourceSets.named("main") {
        kotlin.srcDir("../../android/app/src/main/java/com/magicmaker/android/core")
        // These need the Android SDK or the app's service / BLE layers.
        kotlin.exclude("**/CrashLog.kt", "**/LivePacketSort.kt", "**/MagicTransmitter.kt")
    }
}

application {
    mainClass.set("MainKt")
}

tasks.named<JavaExec>("run") {
    // The generator takes the repository root, so it never depends on the working directory.
    args(projectDir.resolve("../..").canonicalPath)
}
