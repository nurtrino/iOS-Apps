// Conservative, mutually compatible versions. Every bleeding-edge dependency is
// a build failure that cannot be reproduced locally in this environment, so
// stable-and-slightly-behind beats current.
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
}
