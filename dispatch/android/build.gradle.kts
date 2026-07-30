// Deliberately empty of the Android plugin.
//
// Declaring `com.android.application` here — even with `apply false` — makes
// Gradle resolve it before it configures anything, which fails in any
// environment without access to Google's Maven repository and takes `:core`'s
// tests down with it. The app module declares its own plugins instead, and is
// only included when there is an SDK to build it against. See settings.gradle.kts.
plugins {
    alias(libs.plugins.kotlin.jvm) apply false
}
