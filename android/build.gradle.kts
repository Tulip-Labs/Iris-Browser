plugins {
    id("com.android.application") version "9.2.1" apply false
    // AGP 9 compiles Kotlin itself; this picks the Kotlin version it uses
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.21" apply false
}
