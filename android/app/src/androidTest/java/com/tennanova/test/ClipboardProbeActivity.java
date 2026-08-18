package com.tennanova.test;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.view.Gravity;
import android.widget.Button;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

/** Test-APK-only source used for real-device clipboard integration checks. */
public final class ClipboardProbeActivity extends Activity {
    private static final String MARKER =
            "TennaNova accessibility integration pass 20260817";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        boolean shareImage = getIntent().getBooleanExtra("shareImage", false);
        Button button = new Button(this);
        button.setText(shareImage ? "Share image" : "Copy");
        button.setGravity(Gravity.CENTER);
        button.setOnClickListener(view -> {
            if (shareImage) {
                try {
                    shareSyntheticImage();
                } catch (IOException error) {
                    Log.e("TennaProbe", "could not create synthetic image", error);
                }
            } else {
                Log.i("TennaProbe", "copy button clicked");
                getSystemService(ClipboardManager.class).setPrimaryClip(
                        ClipData.newPlainText("TennaNova test", MARKER));
            }
        });
        setContentView(button);
    }

    private void shareSyntheticImage() throws IOException {
        File file = new File(getCacheDir(), "tenna-probe.png");
        Bitmap bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888);
        bitmap.eraseColor(Color.rgb(45, 125, 210));
        try (FileOutputStream output = new FileOutputStream(file)) {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output);
        } finally {
            bitmap.recycle();
        }

        Uri uri = Uri.parse("content://com.tennanova.test.files/" + file.getName());
        Intent share = new Intent(Intent.ACTION_SEND)
                .setComponent(new ComponentName(
                        "com.tennanova", "com.tennanova.ui.MainActivity"))
                .setType("image/png")
                .putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        Log.i("TennaProbe", "synthetic image shared");
        startActivity(share);
    }
}
