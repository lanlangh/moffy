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

    // リリース署名（upload key / PKCS12）。CI が GitHub Secret から環境変数経由で渡す。
    // ローカルや Secret 未設定の環境では storeFile=null のままで、buildTypes 側が
    // デバッグ署名にフォールバックする（誰でもビルドは通る / 信頼境界: 鍵はコミットしない）。
    signingConfigs {
        create("release") {
            val ksPath = System.getenv("ANDROID_KEYSTORE_PATH")
            if (ksPath != null && file(ksPath).exists()) {
                storeFile = file(ksPath)
                storeType = "PKCS12"
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                // PKCS12 は keyPassword = storePassword（生成時に同一にしている）。
                keyPassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        getByName("release") {
            // 署名鍵が渡されていれば release 署名、無ければデバッグ署名（PoC/ローカル用）。
            val hasUploadKey = System.getenv("ANDROID_KEYSTORE_PATH") != null
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 初回/MVPは圧縮なし（R8/proguard 起因の不具合を避ける）。
            // コード圧縮offなのでリソース圧縮も明示off（両者の不整合エラー回避）。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
