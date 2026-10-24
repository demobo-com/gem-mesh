plugins {
    id("com.android.application") version "8.13.2" apply false
    // litertlm-android 0.18.1 ships kotlin-stdlib 2.4.0, so the compiler must be 2.4 or newer.
    id("org.jetbrains.kotlin.android") version "2.4.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21" apply false
}
