// Moffy Android アプリモジュール（ARCHITECTURE §1 / PRD S3）。
// applicationId = com.moffy.app / PACKAGE_USAGE_STATS は Manifest で宣言。
plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter Gradle Plugin は Android/Kotlin の後に適用する。
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.moffy.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.moffy.app"
        // UsageStatsManager.unsafeCheckOpNoThrow は API 29+。
        // 利用統計自体は古くからあるが、MVPは Android 8(API26) 以上を前提。
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        getByName("release") {
            // TODO(署名): リリース署名は SETUP.md の手順で keystore を設定。
            // 現状はデバッグ署名でビルド可能な状態に留める（PoC検証用）。
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
        }
    }
}

flutter {
    source = "../.."
}
