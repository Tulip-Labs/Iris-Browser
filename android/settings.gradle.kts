pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        // Cefrium: Chromium (CEF) for Android, the page engine
        maven("https://maven.cefrium.com") { content { includeGroupByRegex("com\\.cefrium.*") } }
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven("https://maven.cefrium.com") { content { includeGroupByRegex("com\\.cefrium.*") } }
    }
}
rootProject.name = "Iris"
include(":app")
