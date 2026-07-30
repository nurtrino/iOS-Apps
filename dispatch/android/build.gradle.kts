// The Kotlin plugins are declared here with `apply false`, and the Android
// plugin deliberately is not.
//
// Both halves of that matter. Declaring the Kotlin plugins once at the root is
// what stops the app module's request for `kotlin.android` failing with "already
// on the classpath with an unknown version" — a subproject may not name a
// version for a plugin the root has already loaded. Declaring the *Android*
// plugin here would make Gradle resolve it from Google's Maven repository before
// configuring anything, which fails on any machine without access to it and takes
// :core's tests down with it. So the app module declares that one, and is only
// included when there is an SDK to build against. See settings.gradle.kts.
plugins {
    alias(libs.plugins.kotlin.jvm) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.compose.compiler) apply false
}
