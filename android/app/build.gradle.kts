plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val llamaSources = rootProject.file("../third_party/llama.cpp/CMakeLists.txt")

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

    // «Продвинутая» (ADR-046): обёртка llama.cpp native/tridot_llama —
    // libtridot_llama.so для arm64-v8a, Dart грузит её через dart:ffi.
    // Исходники llama.cpp — tool/fetch_llama.sh; без них APK собирается без
    // «Продвинутой» (раздел в настройках честно скажет, что модель не
    // запустилась).
    if (llamaSources.exists()) {
        externalNativeBuild {
            cmake {
                path = file("../../native/tridot_llama/CMakeLists.txt")
                version = "3.22.1"
            }
        }
        defaultConfig {
            externalNativeBuild {
                cmake {
                    arguments += listOf(
                        "-DANDROID_STL=c++_static",
                        "-DGGML_NATIVE=OFF",
                        // ARMv8.2 с dotprod и fp16: у всех телефонов от 8 ГБ.
                        "-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16",
                    )
                    targets += "tridot_llama"
                }
            }
            ndk {
                abiFilters += "arm64-v8a"
            }
        }
    } else {
        logger.warn("tridot: нет third_party/llama.cpp (tool/fetch_llama.sh) — APK без «Продвинутой»")
    }

    // Тесты виджетов рабочего стола (ADR-034) на Robolectric: ресурсы
    // приложения нужны, чтобы рисовать настоящие макеты.
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Методы Mp3Native регистрирует JNI_OnLoad библиотеки
            // libtridot_mp3 по имени класса: R8 не должен его переименовать.
            proguardFiles("proguard-rules.pro")
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

dependencies {
    // Видео → MP4 на телефоне (ADR-026): androidx.media3 Transformer
    // (Apache-2.0) сам ведёт MediaCodec и MediaMuxer, поворот и масштаб.
    // Версии закреплены точно.
    implementation("androidx.media3:media3-transformer:1.11.1")
    implementation("androidx.media3:media3-effect:1.11.1")
    implementation("androidx.media3:media3-common:1.11.1")
}

dependencies {
    // Тесты виджетов рабочего стола (ADR-034): только для
    // `./gradlew :app:testDebugUnitTest`, в APK не попадают.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.18")
    testImplementation("androidx.test:core:1.7.0")
}

// Модульные тесты берут ресурсы из сборки Flutter (copyFlutterAssets*), а
// Gradle требует явного порядка между этими задачами.
tasks.matching { it.name.startsWith("package") && it.name.endsWith("UnitTestForUnitTest") }
    .configureEach {
        mustRunAfter("copyFlutterAssets" + name.removePrefix("package").removeSuffix("UnitTestForUnitTest"))
    }

tasks.withType<Test>().configureEach {
    maxHeapSize = "2g"
    // Снимки виджетов в PNG: `-Ptridot.shots=<папка>` (без него не пишутся).
    (project.findProperty("tridot.shots") as String?)?.let { systemProperty("tridot.shots", it) }
}
