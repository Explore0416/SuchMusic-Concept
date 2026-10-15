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
    // 二改标识：与上游原版（com.such.music.such_music）彻底区分，
    // 由「闪电科技团队（Lightning Team）」二次开发维护，可与原版并存安装。
    namespace = "com.lightningteam.suchmusic"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // 二改包名（Lightning Team 维护），区别于上游原版
        applicationId = "com.lightningteam.suchmusic"
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

// ── 手环桥接：官方 SDK（可选依赖）──────────────────────────────
// 小米官方 `xms-wearable-lib` AAR 因**专有许可不能随仓库分发**，因此：
// **仅当 android/app/libs/xms-wearable-lib*.aar 存在时**才把它加入依赖；
// 没有该 AAR 时构建必须正常通过（桥接层用薄适配层 + 反射访问，无编译期硬依赖）。
// 用户把 `xms-wearable-lib_1.4_release.aar` 放入 android/app/libs/ 后重新构建即可启用真机通信。
dependencies {
    val bandAar = fileTree("libs") { include("xms-wearable-lib*.aar") }
    if (!bandAar.isEmpty) {
        implementation(bandAar)
    }
}

flutter {
    source = "../.."
}
