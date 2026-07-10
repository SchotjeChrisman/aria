import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: env vars on CI, ~/.keys/aria-key.properties locally,
// debug keys as last resort so `flutter run --release` still works anywhere.
val keyProps = Properties()
val keyPropsFile = file("${System.getProperty("user.home")}/.keys/aria-key.properties")
if (keyPropsFile.exists()) {
    keyProps.load(FileInputStream(keyPropsFile))
}
val ksFile: String? = System.getenv("ANDROID_KEYSTORE_PATH") ?: keyProps.getProperty("storeFile")
val ksPass: String? = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: keyProps.getProperty("storePassword")
val ksAlias: String? = System.getenv("ANDROID_KEY_ALIAS") ?: keyProps.getProperty("keyAlias")

android {
    namespace = "dev.aria.aria"
    // file_picker's flutter_plugin_android_lifecycle needs compileSdk 36;
    // flutter.compileSdkVersion still defaults to 34 on the pinned stable.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.aria.aria"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (ksFile != null && ksPass != null && ksAlias != null) {
        signingConfigs.create("release") {
            storeFile = file(ksFile)
            storePassword = ksPass
            keyAlias = ksAlias
            keyPassword = ksPass
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
