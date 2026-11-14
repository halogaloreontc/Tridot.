plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.local_assistant"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.local_assistant"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Голосовой ввод (ADR-023): из AAR Vosk нужен только libvosk.so для
    // arm64-v8a — остальные ABI не попадают в APK (~10 МБ вместо ~40).
    packaging {
        jniLibs {
            excludes += listOf(
                "lib/armeabi-v7a/libvosk.so",
                "lib/x86/libvosk.so",
                "lib/x86_64/libvosk.so",
            )
            // Сборка под выбранные ABI (--target-platform): библиотеки
            // других ABI (например, libdartjni.so пакета record) в APK не
            // кладём. Иначе Android выберет ABI без libflutter.so, и на x86_64
            // или 32-битном ARM приложение упадёт при запуске.
            val abiByPlatform = mapOf(
                "android-arm" to "armeabi-v7a",
                "android-arm64" to "arm64-v8a",
                "android-x86" to "x86",
                "android-x64" to "x86_64",
            )
            val targetAbis = (project.findProperty("target-platform") as String?)
                ?.split(",")
                ?.mapNotNull { abiByPlatform[it.trim()] }
                ?.toSet()
            if (!targetAbis.isNullOrEmpty()) {
                abiByPlatform.values
                    .filter { it !in targetAbis }
                    .forEach { excludes += "lib/$it/**" }
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // FileProvider для «Открыть» у результата архиватора (ADR-024).
    implementation("androidx.core:core:1.13.1")
}

dependencies {
    // Голосовой ввод (ADR-023): только libvosk.so (Apache-2.0), вызывается из
    // Dart через dart:ffi (lib/core/voice/vosk_ffi.dart). «@aar» — без
    // транзитивных зависимостей: JNA и Java-классы Vosk не нужны.
    implementation("com.alphacephei:vosk-android:0.3.75@aar")
}
