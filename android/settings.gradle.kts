pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        // Cefrium: Chromium (CEF) built for Android, the page engine
        maven("https://maven.cefrium.com") { content { includeGroupByRegex("com\\.cefrium.*") } }
        maven("https://codeberg.org/api/packages/cefrium/maven") { content { includeGroupByRegex("com\\.cefrium.*") } }
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven("https://maven.cefrium.com") { content { includeGroupByRegex("com\\.cefrium.*") } }
        maven("https://codeberg.org/api/packages/cefrium/maven") { content { includeGroupByRegex("com\\.cefrium.*") } }
    }
}
rootProject.name = "Iris"
include(":app")
