plugins {
    id("com.android.application") version "9.2.1" apply false
    // AGP 9 compiles Kotlin itself; this only picks the Kotlin version it uses
    id("org.jetbrains.kotlin.android") version "2.2.21" apply false
}
