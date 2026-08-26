package dev.aria.aria

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    // On Android 13+ a denied POST_NOTIFICATIONS keeps foreground-service
    // notifications out of the shade, which hides the media controls with
    // them. audio_service declares nothing and asks for nothing, so ask here.
    // The platform shows this at most twice, then silently declines forever.
    // The request code is arbitrary but not 0: FlutterActivity fans results
    // out to every plugin, and 0 is the value they all reach for.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4711)
        }
    }
}
