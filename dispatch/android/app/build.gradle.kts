// Applied by id, without versions: every plugin is already on the shared
// buildscript classpath the root build put there, which is what lets the Kotlin
// Android plugin see AGP's classes. Order matters — the Kotlin plugin inspects
// the Android extension as it applies itself.
apply(plugin = "com.android.application")
apply(plugin = "org.jetbrains.kotlin.android")
apply(plugin = "org.jetbrains.kotlin.plugin.compose")

repositories {
    google()
    mavenCentral()
}

// `ApplicationExtension` is AGP's public DSL interface. The concrete class the
// `android { }` accessor would give is in an `internal` package that has moved
// between AGP versions, and this file cannot be compiled anywhere but CI — so it
// uses the type that is actually promised to be stable.
extensions.configure<com.android.build.api.dsl.ApplicationExtension>("android") {
    namespace = "com.nurtrino.dispatch"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nurtrino.dispatch"
        // 26 rather than lower: the app leans on java.time, and desugaring it for
        // the few installs below Oreo is not a trade worth making here.
        minSdk = 26
        targetSdk = 35
        // Stamped by CI with the workflow run number. Hardcoding this is the
        // mistake the iOS side already paid for: every build called itself
        // "1.0 (1)", so "is the fix on your phone" had no answer and days of
        // debugging went past an install nobody could date. A local build with
        // no property set is build 0, which reads as "not from CI".
        versionCode = (findProperty("dispatchBuild") as String? ?: "0").toInt()
        versionName = "1.0." + (findProperty("dispatchBuild") as String? ?: "0")
    }

    buildTypes {
        // Debug only. The APK CI publishes is signed with the standard debug
        // key, because that is the only key that exists in a public repository:
        // it installs from a file manager with "unknown sources" allowed, and it
        // is not a Play Store artifact.
        getByName("debug") {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        // Off by default since AGP 8. The top bar reads VERSION_NAME from it,
        // which is the only way the running app can say which build it is.
        buildConfig = true
    }

    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }

    sourceSets.getByName("main") {
        kotlin.srcDir("src/main/kotlin")
    }
}

// Set on the compile tasks rather than through `android.kotlinOptions`, which is
// an extension-on-an-extension and needs an ExtensionAware cast to reach from
// here.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    "implementation"(project(":core"))
    "implementation"("androidx.core:core-ktx:1.15.0")
    "implementation"("androidx.activity:activity-compose:1.9.3")
    "implementation"("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    "implementation"("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    "implementation"(platform("androidx.compose:compose-bom:2024.12.01"))
    "implementation"("androidx.compose.ui:ui")
    "implementation"("androidx.compose.ui:ui-graphics")
    "implementation"("androidx.compose.ui:ui-tooling-preview")
    "implementation"("androidx.compose.material3:material3")
    "implementation"("androidx.compose.material:material-icons-extended")
}
