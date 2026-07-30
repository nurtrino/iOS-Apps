// Applied by id rather than through the plugins DSL: the Kotlin plugin is
// already on the shared buildscript classpath from the root build, which is what
// lets the app module's Kotlin and Android plugins see each other. The cost is
// that the generated `kotlin { }` and `java { }` accessors do not exist here, so
// the extensions are configured by name.
apply(plugin = "org.jetbrains.kotlin.jvm")

repositories { mavenCentral() }

dependencies {
    "testImplementation"("junit:junit:4.13.2")
}

// Targets 17 rather than requesting a 17 toolchain. Android needs 17-compatible
// bytecode, but asking Gradle for a *JDK 17 installation* makes the build fail on
// any machine that only has a newer one — this environment has 21. Compiling with
// whatever is present and emitting 17 produces the same artifact.
extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinJvmProjectExtension>("kotlin") {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

extensions.configure<JavaPluginExtension>("java") {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

tasks.withType<JavaCompile>().configureEach { options.release.set(17) }

tasks.withType<Test>().configureEach {
    useJUnit()
    testLogging { events("failed") }
}
