plugins {
    alias(libs.plugins.kotlin.jvm)
}

dependencies {
    testImplementation(libs.junit)
}

// Targets 17 rather than requesting a 17 toolchain.
//
// Android needs 17-compatible bytecode, but asking Gradle for a *JDK 17
// installation* makes the build fail on any machine that only has a newer JDK —
// including this development environment, which has 21. Compiling with whatever
// JDK is present and emitting 17 gets the same artifact without the constraint.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

tasks.withType<JavaCompile>().configureEach {
    options.release.set(17)
}

tasks.test {
    useJUnit()
    testLogging { events("failed") }
}
