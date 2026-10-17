import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Chave de upload da Play Store, fora do git (android/key.properties + o .jks). Ver README.
val chaveDeAssinatura = Properties().apply {
    val arquivo = rootProject.file("key.properties")
    if (arquivo.exists()) arquivo.inputStream().use { load(it) }
}

android {
    namespace = "br.com.catvirtual.entregador_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    signingConfigs {
        create("release") {
            if (!chaveDeAssinatura.isEmpty) {
                keyAlias = chaveDeAssinatura.getProperty("keyAlias")
                keyPassword = chaveDeAssinatura.getProperty("keyPassword")
                storeFile = file(chaveDeAssinatura.getProperty("storeFile"))
                storePassword = chaveDeAssinatura.getProperty("storePassword")
            }
        }
    }

    defaultConfig {
        applicationId = "br.com.catvirtual.entregador_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Nunca com a chave de debug: a Play Store recusa, e um APK assim pode ser trocado por
            // qualquer um que tenha a chave pública de debug do Android.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

// Build de release sem a chave configurada para com uma mensagem clara (em vez de gerar um app
// sem assinatura ou com a chave de debug).
gradle.taskGraph.whenReady {
    val releaseSemChave = chaveDeAssinatura.isEmpty && allTasks.any {
        it.name.endsWith("Release") && (it.name.startsWith("assemble") || it.name.startsWith("bundle"))
    }
    if (releaseSemChave) {
        throw GradleException(
            "Falta android/key.properties com a chave de upload. Veja \"Build de producao\" no README."
        )
    }
}

