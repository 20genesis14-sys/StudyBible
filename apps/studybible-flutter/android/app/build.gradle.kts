import com.android.build.gradle.internal.api.ApkVariantOutputImpl
import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val keyFile = rootProject.file("key.properties")
    if (keyFile.exists()) load(FileInputStream(keyFile))
}

android {
    namespace = "dev.studybible"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.studybible"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystoreProperties.getProperty("storeFile") != null) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        debug {
            // Debug ставится отдельным приложением рядом с release —
            // не нужно удалять одно ради другого.
            applicationIdSuffix = ".debug"
        }
        release {
            // Подпись release-ключом из android/key.properties;
            // без файла (на другой машине) — откат на debug-ключ.
            signingConfig = if (keystoreProperties.getProperty("storeFile") != null)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
        }
    }

    // F-Droid: не вшивать Dependency metadata в signing block APK
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

}

// F-Droid: схема versionCode для ABI-split (их ответ в GitLab):
// versionCode * 10 + abiCode (armeabi-v7a=1, arm64-v8a=2, x86_64=3).
// Собственный оверрайд Flutter (+1000*abi) отключён флагом
// force-version-code-ignoring-abi в gradle.properties. Сами сплиты
// включает плагин при `flutter build apk --split-per-abi`.
val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    outputs.forEach { output ->
        val abiVersionCode =
            abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride =
                variant.versionCode * 10 + abiVersionCode
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

// Reproducible builds: GNU build-id в .so зависит от каталога сборки,
// поэтому note-секция удаляется из всех нативных библиотек перед упаковкой.
val llvmPrebuilt = when {
    System.getProperty("os.name").lowercase().startsWith("windows") -> "windows-x86_64"
    System.getProperty("os.name").lowercase().startsWith("mac") -> "darwin-x86_64"
    else -> "linux-x86_64"
}
val llvmObjcopyBin = if (llvmPrebuilt == "windows-x86_64") "llvm-objcopy.exe" else "llvm-objcopy"
val llvmObjcopy = File(android.ndkDirectory, "toolchains/llvm/prebuilt/$llvmPrebuilt/bin/$llvmObjcopyBin")

tasks.matching { it.name == "stripReleaseDebugSymbols" }.configureEach {
    doLast {
        if (llvmObjcopy.exists()) {
            val outDir = layout.buildDirectory
                .dir("intermediates/stripped_native_libs/release/stripReleaseDebugSymbols/out")
                .get().asFile
            outDir.walkTopDown().filter { it.isFile && it.extension == "so" }.forEach { so ->
                ProcessBuilder(
                    llvmObjcopy.absolutePath,
                    "--remove-section", ".note.gnu.build-id",
                    so.absolutePath,
                ).inheritIO().start().waitFor()
            }
        }
    }
}
