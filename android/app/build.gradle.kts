import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取签名配置（android/key.properties）。
// 本仓库为私有，正式签名 suchmusic-release.jks 与 key.properties 直接入库，
// 保证本地与 CI 每次构建都用同一签名（升级安装不冲突）；
// **缺失时仍必须能正常构建**（例如公开 fork 场景），
// 此时 release 回退用 debug 签名，产物同样可直接安装。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists() &&
        keystorePropertiesFile.inputStream().use { stream ->
            keystoreProperties.load(stream)
            !keystoreProperties.getProperty("storeFile").isNullOrBlank()
        }

android {
    namespace = "com.such.music.such_music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.such.music.such_music"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 正式包只保留 ARM 架构（x86_64 仅模拟器需要，debug 包不受影响）
        ndk {
            abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a"))
        }
    }

    signingConfigs {
        // 仅当 key.properties 齐全时才创建 release 签名；否则不创建，避免配置期抛错
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // 无自有签名时回退 debug 签名：产物仍可安装，便于新克隆/CI 直接出包
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // 代码收缩 + 资源收缩，减小包体
            isMinifyEnabled = false // TODO: 对照实验，验证后恢复
            isShrinkResources = false // TODO: 对照实验，验证后恢复
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
