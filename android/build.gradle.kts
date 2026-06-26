// ルートプロジェクト Gradle 設定。
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: org.gradle.api.file.Directory =
    rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: org.gradle.api.file.Directory =
        newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// 一部の古いプラグイン（sentry_flutter 等）が Kotlin languageVersion 1.6 を指定し、
// 新しいプラグイン（device_info_plus 等）が要求する Kotlin 2.2 コンパイラ（1.8未満非対応）で
// コンパイルエラーになる。全サブプロジェクトの Kotlin コンパイルの language/api version を
// 2.0 に底上げして衝突を解消する（Flutter 既知の互換 workaround）。
subprojects {
    // configureEach は遅延評価のため afterEvaluate 不要（afterEvaluate は
    // 評価済みサブプロジェクトで例外になる）。Kotlin コンパイルタスクが追加され次第適用される。
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            languageVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_0)
            apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_0)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
