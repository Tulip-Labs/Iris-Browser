pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // GeckoView, Firefox's engine for Android
        maven("https://maven.mozilla.org/maven2/") { content { includeGroupByRegex("org\\.mozilla.*") } }
    }
}
rootProject.name = "Iris"
include(":app")
