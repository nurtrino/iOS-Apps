// One buildscript classpath for the whole build, with the Android plugin on it
// only when there is an SDK to use it.
//
// The plugins DSL cannot express that, and trying to cost two CI runs. Declaring
// the Android plugin in a root `plugins {}` block — even `apply false` — makes
// Gradle resolve it from Google's Maven repository before configuring anything,
// which fails on a machine without access and takes :core's tests down with it.
// Declaring only the *Kotlin* plugins there instead loads them in the root's
// classloader while the app module loads the Android plugin in its own, and the
// Kotlin Android plugin then cannot see AGP's classes at all: it fails applying
// itself with a missing `com/android/build/gradle/api/BaseVariant`.
//
// A buildscript block is ordinary Kotlin, so it can hold the condition, and
// everything it puts on the classpath is shared by every module. Both halves of
// the problem go away.
buildscript {
    val hasAndroidSdk = System.getenv("ANDROID_HOME") != null ||
        System.getenv("ANDROID_SDK_ROOT") != null

    repositories {
        if (hasAndroidSdk) google()
        mavenCentral()
    }

    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.0.21")
        classpath("org.jetbrains.kotlin:compose-compiler-gradle-plugin:2.0.21")
        if (hasAndroidSdk) {
            classpath("com.android.tools.build:gradle:8.7.3")
        }
    }
}
