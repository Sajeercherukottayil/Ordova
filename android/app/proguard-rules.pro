# shared_preferences_android and path_provider_android call into Java/Kotlin
# through JNI (package:jni), looking classes and members up by name at
# runtime. R8 can't see those calls, so without these rules it renames or
# strips the classes and the app shows a black screen on start in release.
-keep class kotlin.** { *; }
-keep class io.flutter.embedding.engine.plugins.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-keep class com.github.dart_lang.jni_flutter.** { *; }
