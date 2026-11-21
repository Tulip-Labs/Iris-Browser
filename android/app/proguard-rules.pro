# GeckoView calls into its Java classes from native code and from its own
# JavaScript bridge, so they keep their names.
-keep class org.mozilla.geckoview.** { *; }
-keep class org.mozilla.gecko.** { *; }
-dontwarn org.mozilla.**
