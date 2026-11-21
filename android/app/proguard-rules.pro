# Iris itself uses no reflection. The page engine (Cefrium's Chromium) calls
# into its Java classes from native code, so those keep their names.
-keep class com.cefrium.** { *; }
-keep class org.chromium.** { *; }
-dontwarn com.cefrium.**
-dontwarn org.chromium.**
