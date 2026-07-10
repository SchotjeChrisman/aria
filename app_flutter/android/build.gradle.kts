allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Force every Android module (app + plugins) to compileSdk 36. Flutter still
// propagates 34 to plugins, but file_picker's flutter_plugin_android_lifecycle
// requires 36. Registered BEFORE evaluationDependsOn(":app") below so the
// afterEvaluate hook is in place before any project is evaluated.
// withGroovyBuilder avoids importing AGP types at the root classpath.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.withGroovyBuilder {
            "compileSdkVersion"(36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
