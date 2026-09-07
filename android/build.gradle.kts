import com.android.build.gradle.BaseExtension

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

// Align the embedded Python native bridge with the app's Flutter NDK.
// The plugin otherwise uses AGP's older default NDK independently of the app.
subprojects {
    val pluginProject = this
    plugins.withId("com.android.library") {
        if (pluginProject.name == "serious_python_android") {
            pluginProject.extensions.configure<BaseExtension> {
                ndkVersion = "28.2.13676358"
            }
        }
    }
}

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
