// Two modules, split by what can be verified where.
//
// `core` is pure Kotlin with no Android dependency at all: feed parsing, topic
// classification, the API clients' request-building and response-parsing. It
// compiles and its tests run on any JVM, which means they run in this
// development environment — where there is no Android SDK — rather than only on
// CI. That is deliberate: the parsing layer is where every hard-won bug in this
// project has been, and a test you can run in two seconds is worth more than one
// you wait seven minutes for.
//
// `app` is the Compose UI and everything that touches an Android API. It needs
// the SDK, so it is only ever built on CI.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "dispatch"
include(":core")

// The app module is included only where an Android SDK exists.
//
// `core` is pure Kotlin and its tests are the ones worth running constantly, so
// they must not be blocked by a toolchain the machine does not have. Without
// this guard a checkout with no SDK cannot even *configure* the build — Gradle
// resolves the Android plugin before it runs anything — and `gradle :core:test`
// fails for reasons that have nothing to do with the code.
//
// CI sets ANDROID_HOME, so the APK still builds there.
val androidSdk = System.getenv("ANDROID_HOME")
    ?: System.getenv("ANDROID_SDK_ROOT")
    ?: file("local.properties").takeIf { it.exists() }
        ?.readLines()
        ?.firstOrNull { it.startsWith("sdk.dir=") }
        ?.removePrefix("sdk.dir=")

if (androidSdk != null) {
    include(":app")
} else {
    logger.lifecycle("No Android SDK found - building :core only. Set ANDROID_HOME for the APK.")
}
