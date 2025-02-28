package com.moffatman.chan;

import android.app.NotificationManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.UriPermission;
import android.net.Uri;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.webkit.MimeTypeMap;
import android.util.Log;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts.OpenDocumentTree;
import androidx.annotation.NonNull;
import androidx.documentfile.provider.DocumentFile;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.List;

import io.flutter.embedding.android.FlutterFragmentActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterFragmentActivity {
    private static final String STORAGE_CHANNEL = "com.moffatman.chan/storage";
    private static final String NOTIFICATIONS_CHANNEL = "com.moffatman.chan/notifications";
    private static final String CLIPBOARD_CHANNEL = "com.moffatman.chan/clipboard";
    private MethodChannel.Result folderResult;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        ActivityResultLauncher<Uri> getFolder = registerForActivityResult(new OpenDocumentTree() {
            @Override
            @NonNull
            public Intent createIntent(@NonNull Context context, Uri input) {
                Intent intent = super.createIntent(context, input);
                intent.addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION |
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION |
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION |
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                );
                return intent;
            }
        }, uri -> {
            if (uri != null) {
                getContentResolver().takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                );
                if (folderResult != null) {
                    folderResult.success(uri.toString());
                    return;
                }
            }
            folderResult.success(null);
        });
        super.configureFlutterEngine(flutterEngine);
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), STORAGE_CHANNEL).setMethodCallHandler(
                (call, result) -> {
                    if (call.method.equals("pickDirectory")) {
                        System.out.println(getContentResolver().getPersistedUriPermissions());
                        this.folderResult = result;
                        getFolder.launch(Uri.fromFile(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)));
                    }
                    else if (call.method.equals("saveFile")) {
                        try {
                            String sourcePath = call.argument("sourcePath");
                            String destinationDir = call.argument("destinationDir");
                            List<String> destinationSubfolders = call.argument("destinationSubfolders");
                            String destinationName = call.argument("destinationName");
                            Uri destination = Uri.parse(destinationDir);
                            boolean sufficientPermission = false;
                            for (UriPermission permission : getContentResolver().getPersistedUriPermissions()) {
                                if (permission.getUri().equals(destination)) {
                                    sufficientPermission = permission.isWritePermission() && (destinationSubfolders.isEmpty() || permission.isReadPermission());
                                }
                            }
                            if (!sufficientPermission) {
                                result.error("InsufficientPermission", "Permissions not enough or have expired", null);
                                return;
                            }
                            DocumentFile dir = DocumentFile.fromTreeUri(this, destination);
                            if (!dir.exists()) {
                                result.error("DirectoryNotFound", "Supplied directory does not exist", null);
                                return;
                            }
                            for (String subdirName : destinationSubfolders) {
                                DocumentFile subdir = dir.findFile(subdirName);
                                if (subdir != null && subdir.isDirectory()) {
                                    dir = subdir;
                                }
                                else {
                                    dir = dir.createDirectory(subdirName);
                                }
                            }
                            DocumentFile file = dir.createFile(MimeTypeMap.getFileExtensionFromUrl(destinationName), destinationName);
                            ParcelFileDescriptor destinationFileDescriptor = getContentResolver().openFileDescriptor(file.getUri(), "w");
                            File sourceFile = new File(sourcePath);
                            FileOutputStream destinationWriteStream = new FileOutputStream(destinationFileDescriptor.getFileDescriptor());
                            FileInputStream sourceReadStream = new FileInputStream(sourceFile);
                            byte[] buffer = new byte[4096];
                            int len;
                            while ((len = sourceReadStream.read(buffer, 0, 4096)) > 0) {
                                destinationWriteStream.write(buffer, 0, len);
                            }
                            destinationWriteStream.close();
                            destinationFileDescriptor.close();
                            sourceReadStream.close();
                            result.success(null);
                        }
                        catch (FileNotFoundException e) {
                            result.error("FileNotFound", e.getMessage(), null);
                        }
                        catch (IOException e) {
                            result.error("IOException", e.getMessage(), null);
                        }
                    }
                    else {
                        result.notImplemented();
                    }
                }
        );
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), NOTIFICATIONS_CHANNEL).setMethodCallHandler(
                (call, result) -> {
                    if (call.method.equals("clearNotificationsWithProperties")) {
                        // Seems to be no way to find the notifications after they are posted
                        // Unfortunately have to cancel everything
                        NotificationManager nm = (NotificationManager)getSystemService(Context.NOTIFICATION_SERVICE);
                        nm.cancelAll();
                        result.success(null);
                    }
                    else {
                        result.notImplemented();
                    }
                }
        );
        new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CLIPBOARD_CHANNEL).setMethodCallHandler(
                (call, result) -> {
                    try {
                        if (call.method.equals("doesClipboardContainImage")) {
                            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                            ClipData primaryClip = cm.getPrimaryClip();
                            if (primaryClip != null) {
                                ClipData.Item item = primaryClip.getItemAt(0);
                                if (item.getUri() != null) {
                                    String[] parts = item.getUri().toString().split("\\.");
                                    String ext = parts[parts.length - 1];
                                    result.success(ext.equals("jpg") || ext.equals("jpeg") || ext.equals("png") || ext.equals("gif"));
                                    return;
                                }
                            }
                            result.success(null);
                        } else if (call.method.equals("getClipboardImage")) {
                            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
                            ClipData primaryClip = cm.getPrimaryClip();
                            if (primaryClip != null) {
                                ClipData.Item item = primaryClip.getItemAt(0);
                                if (item.getUri() != null) {
                                    try {
                                        InputStream stream = getContentResolver().openInputStream(item.getUri());
                                        byte[] data = new byte[stream.available()];
                                        stream.read(data);
                                        result.success(data);
                                    } catch (IOException e) {
                                        result.error("FILE_ERROR", "Could not open file for reading", null);
                                    }
                                    return;
                                }
                            }
                            result.success(null);
                        } else {
                            result.notImplemented();
                        }
                    }
                    catch (Exception e) {
                        result.error("JAVA_EXCEPTION", e.getMessage(), null);
                    }
                }
        );
    }
}
