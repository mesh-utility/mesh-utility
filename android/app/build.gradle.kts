import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Optional release credentials. Never commit key.properties or the keystore.
// Env vars win so CI can inject secrets without a properties file.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(envName: String, propName: String): String? {
    val fromEnv = System.getenv(envName)?.trim()?.takeIf { it.isNotEmpty() }
    if (fromEnv != null) return fromEnv
    return keystoreProperties.getProperty(propName)?.trim()?.takeIf { it.isNotEmpty() }
}

val releaseStorePath = signingValue("ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingValue("ANDROID_KEYSTORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("ANDROID_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("ANDROID_KEY_PASSWORD", "keyPassword")
val hasReleaseKeystore = !releaseStorePath.isNullOrEmpty() &&
    !releaseStorePassword.isNullOrEmpty() &&
    !releaseKeyAlias.isNullOrEmpty() &&
    !releaseKeyPassword.isNullOrEmpty()

// pubspec `version: 1.0.0-alpha.N+N` is the Android versionName / versionCode.
// Release tags are `Alpha-N` and have no `+build`, so N from that tag is the fallback.
// The Flutter plugin defaults versionCode to 1 when local.properties has no code.
fun readPubspecVersionRaw(): String? {
    val pubspec = rootProject.file("../pubspec.yaml")
    if (!pubspec.isFile) return null
    for (line in pubspec.readLines()) {
        val trimmed = line.trim()
        if (!trimmed.startsWith("version:")) continue
        return trimmed.removePrefix("version:")
            .substringBefore("#")
            .trim()
            .trim('"', '\'')
            .takeIf { it.isNotEmpty() }
    }
    return null
}

fun alphaReleaseNumber(text: String?): Int? {
    if (text.isNullOrBlank()) return null
    val match = Regex("(?i)alpha[^0-9]*([0-9]+)").find(text) ?: return null
    return match.groupValues[1].toIntOrNull()?.takeIf { it > 0 }
}

val pubspecVersionRaw = readPubspecVersionRaw()
val pubspecVersionName = pubspecVersionRaw?.substringBefore('+')?.takeIf { it.isNotEmpty() }
val pubspecVersionCode = pubspecVersionRaw
    ?.substringAfter('+', "")
    ?.toIntOrNull()
    ?.takeIf { it > 0 }
val releaseTagVersionCode = alphaReleaseNumber(System.getenv("RELEASE_TAG"))

android {
    namespace = "org.meshutility.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.meshutility.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = pubspecVersionCode
            ?: releaseTagVersionCode
            ?: alphaReleaseNumber(pubspecVersionName)
            ?: flutter.versionCode
        versionName = pubspecVersionName ?: flutter.versionName
    }

    if (hasReleaseKeystore) {
        val path = releaseStorePath!!
        val storePass = releaseStorePassword!!
        val alias = releaseKeyAlias!!
        val keyPass = releaseKeyPassword!!
        signingConfigs.create("release") {
            val store = File(path)
            // storeFile in key.properties is relative to the android/ project,
            // or an absolute path (CI writes the decoded keystore under RUNNER_TEMP).
            storeFile = if (store.isAbsolute) store else rootProject.file(path)
            storePassword = storePass
            keyAlias = alias
            keyPassword = keyPass
            // Keystore bytes are PKCS12 even when the filename ends in .jks.
            storeType = "PKCS12"
        }
    }

    buildTypes {
        release {
            // Debug signing keeps local and CI builds working until secrets exist.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
