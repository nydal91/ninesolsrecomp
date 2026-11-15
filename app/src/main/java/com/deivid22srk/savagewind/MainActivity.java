package com.deivid22srk.savagewind;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.FileInputStream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import android.app.AlertDialog;
import android.content.Intent;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.Environment;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.provider.Settings;
import android.system.Os;
import android.widget.Toast;

import com.chaquo.python.android.AndroidPlatform;
import com.chaquo.python.Python;

import org.libsdl.app.SDLActivity;

/**
 * Savage Wind (Android port of SavageWindRecomp).
 *
 * Runs the original C runtime through SDL3's SDLActivity. The player's own game files
 * (exefs/ + romfs/, extracted from their own copy of the game) are picked with the system
 * folder picker and read from wherever they already are - nothing is decrypted, no keys
 * are needed, and no game data ships with the APK.
 */
public class MainActivity extends SDLActivity {

    private static final int REQ_PICK_FOLDER = 41;
    private static final int REQ_PICK_FILE = 42;
    private static final int REQ_PICK_DRIVER = 43;
    private static final int REQ_PICK_SAVE = 44;  // (android_bridge.c: dialog callback 2)

    static Context sContext;  // package-private: Swgen reads it
    private static File sBootLog;

    static {
        // The libraries themselves are loaded by SDLActivity (getLibraries(): bootlog, SDL3, main).
    }

    // ------------------------------------------------------------------ boot log
    // Every startup step lands here (and in logcat "swboot"), so a failure during boot is
    // visible in the user's own log capture. libbootlog.so appends native crashes to the
    // same file through SAVAGEWIND_CRASHLOG.
    private static void bootLog(String msg) {
        android.util.Log.i("swboot", msg);
        if (sBootLog == null) return;
        try (FileOutputStream o = new FileOutputStream(sBootLog, true)) {
            o.write((System.currentTimeMillis() + " " + msg + "\n").getBytes("UTF-8"));
        } catch (Exception ignored) {
        }
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        sContext = this;  // the pickers (pickFolder / pickFile) and Swgen use it: it was never set
        File root = getExternalFilesDir(null);
        if (root == null) root = getFilesDir();
        sBootLog = new File(root, "bootlog.txt");
        bootLog("app: onCreate begin");
        try {
            // Read before the SDL thread starts: the runtime's paths.c picks the data root
            // up from SAVAGEWIND_DATA_ROOT. The compiler is the clang shipped inside the APK
            // (libclang.so in nativeLibraryDir), found through SAVAGEWIND_CC like on the desktop;
            // ld.lld is reached through a symlink in the PATH, since only nativeLibraryDir is
            // executable and the linker's name must be ld.lld for clang's -fuse-ld=lld.
            // (The symlink must live on internal storage: /storage's FUSE rejects symlink(2).)
            String libdir = getApplicationInfo().nativeLibraryDir;
            Os.setenv("SAVAGEWIND_DATA_ROOT", root.getAbsolutePath(), true);
            Os.setenv("SAVAGEWIND_CRASHLOG", sBootLog.getAbsolutePath(), true);
            Os.setenv("SAVAGEWIND_LIB_DIR", libdir, true);
            Os.setenv("SAVAGEWIND_CC", libdir + "/libclang.so", true);
            // the generator's ctypes packages load their C library from here (build_deps_android.sh)
            Os.setenv("LIBUNICORN_PATH", libdir, true);
            Os.setenv("LIBCAPSTONE_PATH", libdir, true);
            // the game code library is loaded from here: native code can't load from shared storage
            Os.setenv("SAVAGEWIND_CODE_DIR", getCodeCacheDir().getAbsolutePath(), true);
            // the on-device link (runtime/gamebuild.c): the shipped sysroot / compiler runtime (copyAssets)
            // and libmain.so, so the game code library resolves the runtime functions it calls
            Os.setenv("SAVAGEWIND_LINK_FLAGS", "--sysroot=" + root.getAbsolutePath() + "/sysroot -resource-dir="
                      + root.getAbsolutePath() + "/clangrt -L" + libdir + " -lmain -lm", true);
            // (tests, over adb) SAVAGEWIND_* string extras become environment variables, e.g.
            // am start -n <pkg>/.MainActivity --es SAVAGEWIND_LAUNCHER_SETUP /storage/emulated/0/SavageWind
            Bundle extras = getIntent() != null ? getIntent().getExtras() : null;
            if (extras != null)
                for (String k : extras.keySet())
                    if (k.startsWith("SAVAGEWIND_") && extras.get(k) instanceof String) Os.setenv(k, extras.getString(k), true);
            File bin = new File(getFilesDir(), "bin");
            bin.mkdirs();
            // made anew each start: an update moves nativeLibraryDir (a new random path), and the old
            // link then dangled (symlink() failed with EEXIST, the linker was never found)
            File lld = new File(bin, "ld.lld");
            lld.delete();
            try {
                Os.symlink(libdir + "/libld.lld.so", lld.getAbsolutePath());
            } catch (Exception e) {
                bootLog("env: ld.lld link FAILED: " + e);
            }
            String path = System.getenv("PATH");
            Os.setenv("PATH", bin.getAbsolutePath() + ":" + (path != null ? path : ""), true);
            Os.setenv("LD_LIBRARY_PATH", libdir, true);
            Os.setenv("HOME", root.getAbsolutePath(), true);
            Os.setenv("TMPDIR", getCacheDir().getAbsolutePath(), true);
            bootLog("env: data_root=" + root + " libdir=" + libdir + " bin=" + bin
                    + " ld.lld->" + (new File(bin, "ld.lld").exists() ? "ok" : "missing"));
        } catch (Exception e) {
            bootLog("env: setup FAILED: " + e);
        }

        installDrivers(root);
        copyAssets(root);
        bootLog("assets: copied");
        try {
            Python.start(new AndroidPlatform(getApplicationContext()));
            bootLog("python: started");
        } catch (Throwable t) {
            bootLog("python: start FAILED: " + t);
            throw t;
        }
        ensureStorageAccess();
        bootLog("storage: managed=" + Environment.isExternalStorageManager());
        bootLog("sdl: entering SDLActivity.onCreate (loads bootlog, SDL3, main)");
        super.onCreate(savedInstanceState);
        bootLog("sdl: SDLActivity.onCreate returned");
        nativeSetContext(this);
        bootLog("native: context set");
    }

    // libbootlog first: it installs the signal handlers that record a native death while
    // dlopen'ing the libraries below (invisible to uid-filtered log captures otherwise).
    @Override
    protected String[] getLibraries() {
        return new String[] { "bootlog", "SDL3", "main" };
    }

    @Override
    public void loadLibraries() {
        for (String lib : getLibraries()) {
            bootLog("native: loading lib" + lib + ".so ...");
            try {
                System.loadLibrary(lib);
            } catch (Throwable t) {
                bootLog("native: lib" + lib + ".so FAILED: " + t);
                throw t;  // SDLActivity catches this and shows its error dialog
            }
            bootLog("native: lib" + lib + ".so loaded");
        }
    }

    // ------------------------------------------------------------------ storage permission
    // The setup copies from the folder the player chose with the system picker. Reading it
    // needs All files access (a real filesystem path is resolved from the picker result).
    private void ensureStorageAccess() {
        if (Environment.isExternalStorageManager()) return;
        try {
            Intent i = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                  Uri.parse("package:" + getPackageName()));
            startActivity(i);
        } catch (Exception e) {
            try {
                startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
            } catch (Exception ignored) {
            }
        }
    }

    // ------------------------------------------------------------------ GPU drivers
    // Adreno drivers in the AdrenoTools format (Mesa Turnip...: a zip with meta.json and the driver's .so), put in
    // <external files>/drivers, are unpacked into <files>/drivers/<zip name>/: native code can only load libraries
    // from internal storage. android/vk_dispatch.c loads the one the GPU driver setting names.
    private void installDrivers(File root) {
        File in = new File(root, "drivers"), out = new File(getFilesDir(), "drivers");
        in.mkdirs();
        out.mkdirs();
        try {
            Os.setenv("SAVAGEWIND_DRIVERS_DIR", out.getAbsolutePath(), true);
        } catch (Exception ignored) {
        }
        File[] zips = in.listFiles();
        if (zips == null) return;
        for (File z : zips) {
            String n = z.getName();
            if (!n.toLowerCase().endsWith(".zip")) continue;
            File stamp = new File(new File(out, n.substring(0, n.length() - 4)), ".from_zip");
            if (stamp.isFile() && stamp.lastModified() >= z.lastModified()) continue;
            unpackDriver(z, out);
        }
    }

    // One driver zip -> <out>/<zip name without .zip>/ (flat: the driver and meta.json). False (and nothing left
    // behind) when it isn't an AdrenoTools driver.
    private boolean unpackDriver(File z, File out) {
        String n = z.getName();
        File dir = new File(out, n.substring(0, n.length() - 4));
        File stamp = new File(dir, ".from_zip");
        deleteTree(dir);
        dir.mkdirs();
        boolean ok = false;
        try (ZipInputStream zi = new ZipInputStream(new FileInputStream(z))) {
            ZipEntry e;
            byte[] buf = new byte[1 << 16];
            while ((e = zi.getNextEntry()) != null) {
                if (e.isDirectory()) continue;
                String name = new File(e.getName()).getName();
                if (name.isEmpty() || name.startsWith(".")) continue;
                try (OutputStream o = new FileOutputStream(new File(dir, name))) {
                    int k;
                    while ((k = zi.read(buf)) > 0) o.write(buf, 0, k);
                }
                ok |= name.equals("meta.json");
            }
            if (ok) new FileOutputStream(stamp).close();
        } catch (IOException e) {
            ok = false;
        }
        if (!ok) deleteTree(dir);
        bootLog("drivers: " + n + (ok ? " installed" : " is not an AdrenoTools driver zip (no meta.json)"));
        return ok;
    }

    // Video > GPU driver > Install driver from .zip (runtime/ui/menu.mm, through android_bridge.c): the system file
    // picker, any provider (Downloads, Drive...: read through the ContentResolver, no real path needed). The zip is
    // copied into <external files>/drivers - where installDrivers finds it at every start - and unpacked at once;
    // nativeOnDriverInstalled gets the folder name the GPU driver setting takes, or null and why not.
    public static void pickDriverZip() {
        final MainActivity a = (MainActivity) sContext;
        a.runOnUiThread(() -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            i.addCategory(Intent.CATEGORY_OPENABLE);
            i.setType("*/*");
            i.putExtra(Intent.EXTRA_MIME_TYPES, new String[] {"application/zip", "application/x-zip-compressed",
                                                              "application/octet-stream"});
            try {
                a.startActivityForResult(i, REQ_PICK_DRIVER);
            } catch (Exception e) {
                nativeOnDriverInstalled(null, "No file picker on this phone.");
            }
        });
    }

    // No Vulkan 1.3 GPU with the driver in use (runtime/nvn/vulkan/device.c no_vulkan13, through android_bridge.c),
    // before the start screen can be drawn: install a driver .zip (pickDriverZip: the answer reaches native code the
    // same way) or quit.
    public static void chooseDriver(final String message) {
        final MainActivity a = (MainActivity) sContext;
        a.runOnUiThread(() -> new AlertDialog.Builder(a)
                .setTitle("A newer GPU driver is needed")
                .setMessage(message)
                .setCancelable(false)
                .setPositiveButton("Install driver (.zip)...", (d, w) -> pickDriverZip())
                .setNegativeButton("Quit", (d, w) -> {
                    a.finishAndRemoveTask();
                    System.exit(0);
                })
                .show());
    }

    private void installPickedDriver(final Uri uri) {
        new Thread(() -> {
            String name = null;
            try (Cursor c = getContentResolver().query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                if (c != null && c.moveToFirst()) name = c.getString(0);
            } catch (Exception ignored) {
            }
            if (name == null) name = uri.getLastPathSegment();
            if (name == null) name = "driver.zip";
            name = new File(name).getName().replaceAll("[^A-Za-z0-9._+-]", "_");
            if (!name.toLowerCase().endsWith(".zip")) name += ".zip";
            File in = new File(sBootLog.getParentFile(), "drivers"), out = new File(getFilesDir(), "drivers");  // (the data root: onCreate)
            in.mkdirs();
            out.mkdirs();
            File z = new File(in, name);
            try (InputStream is = getContentResolver().openInputStream(uri); OutputStream os = new FileOutputStream(z)) {
                if (is == null) throw new IOException("cannot open");
                byte[] buf = new byte[1 << 16];
                int k;
                while ((k = is.read(buf)) > 0) os.write(buf, 0, k);
            } catch (IOException e) {
                z.delete();
                nativeOnDriverInstalled(null, "Could not read the file.");
                return;
            }
            if (unpackDriver(z, out)) {
                nativeOnDriverInstalled(name.substring(0, name.length() - 4), null);
            } else {
                z.delete();
                nativeOnDriverInstalled(null, name + " is not an AdrenoTools driver zip (it has no meta.json).");
            }
        }).start();
    }

    private static void deleteTree(File f) {
        File[] sub = f.listFiles();
        if (sub != null) for (File c : sub) deleteTree(c);
        f.delete();
    }

    // ------------------------------------------------------------------ assets -> data root
    // Shipped resources (fonts, icon, the game-code build headers, TCC's runtime) unpack
    // into the data root, where the runtime's rt_resource() finds them.
    private void copyAssets(File root) {
        copyTree("gamelib-src", new File(root, "gamelib-src"));
        // clang's freestanding builtin headers (CI-extracted) land in the same folder the
        // on-device compile gets via -I, next to the runtime's own headers and the shims.
        copyTree("clang-include", new File(root, "gamelib-src"));
        // into the data root itself: rt_resource() looks for FiraSans-*.ttf / NotoSansThai-*.ttf beside the "exe"
        copyTree("fonts", root);
        copyTree("sysroot", new File(root, "sysroot"));  // (the on-device link: build_deps_android.sh)
        copyTree("clangrt", new File(root, "clangrt"));
        copyTree("colour-luts", new File(root, "colour-luts"));  // (Video > Colour: runtime/color_grade.c)
        copyOne("icon.png", new File(root, "icon.png"));
    }

    private void copyTree(String assetDir, File targetDir) {
        try {
            String[] names = getAssets().list(assetDir);
            if (names == null) return;
            targetDir.mkdirs();
            for (String name : names) {
                File f = new File(targetDir, name);
                if (names.length > 0 && assetDir.length() > 0) {
                    String[] sub = getAssets().list(assetDir + "/" + name);
                    if (sub != null && sub.length > 0) {
                        copyTree(assetDir + "/" + name, f);
                        continue;
                    }
                }
                copyOne(assetDir + "/" + name, f);
            }
        } catch (IOException ignored) {
        }
    }

    private void copyOne(String assetPath, File target) {
        try {
            if (target.isFile()) {
                long existing = target.length();
                long inApk = -1;
                try (InputStream in = getAssets().open(assetPath)) {
                    inApk = in.available();
                } catch (IOException ignored) {
                }
                if (inApk >= 0 && existing == inApk) return;  // same size: keep the copy
            }
            target.getParentFile().mkdirs();
            try (InputStream in = getAssets().open(assetPath);
                 OutputStream out = new FileOutputStream(target)) {
                byte[] buf = new byte[1 << 16];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            }
        } catch (IOException ignored) {
        }
    }

    // ------------------------------------------------------------------ file / folder picking
    // Called from native (runtime/platform/android.c) when the start screen asks for a
    // folder. The picker result is turned into a real filesystem path when it lives on the
    // primary storage, so the original C setup code can read it directly.
    public static void pickFolder() {
        final MainActivity a = (MainActivity) sContext;
        a.runOnUiThread(() -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
            a.startActivityForResult(i, REQ_PICK_FOLDER);
        });
    }

    public static void pickFile() {
        final MainActivity a = (MainActivity) sContext;
        a.runOnUiThread(() -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            i.addCategory(Intent.CATEGORY_OPENABLE);
            i.setType("*/*");
            a.startActivityForResult(i, REQ_PICK_FILE);
        });
    }

    // Saves > Import save (runtime/ui/saves_tab.mm, through android_bridge.c): a folder from any provider. Its save
    // files (*.sav, *.jpg: the slots, option.sav, the Hero's Path, the album and the compendium) are copied, keeping
    // the folder layout, into <cache>/save-import, whose path goes to the converter; null when cancelled or failed.
    public static void pickSaveFolder() {
        final MainActivity a = (MainActivity) sContext;
        a.runOnUiThread(() -> {
            Intent i = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
            i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            try {
                a.startActivityForResult(i, REQ_PICK_SAVE);
            } catch (Exception e) {
                Toast.makeText(a, "No folder picker on this phone.", Toast.LENGTH_LONG).show();
                nativeOnPicked(REQ_PICK_SAVE, null);
            }
        });
    }

    private static final long SAVE_COPY_MAX_FILE = 64L << 20, SAVE_COPY_MAX_TOTAL = 512L << 20;
    private static final int SAVE_COPY_MAX_DEPTH = 10, SAVE_COPY_MAX_VISITS = 50000;
    private long mSaveCopyBytes;
    private int mSaveCopyVisits;

    private void copyPickedSaves(final Uri tree) {
        new Thread(() -> {
            File out = new File(getCacheDir(), "save-import");
            deleteTree(out);
            out.mkdirs();
            mSaveCopyBytes = 0;
            mSaveCopyVisits = 0;
            String err = null;
            try {
                String root = DocumentsContract.getTreeDocumentId(tree);
                copySaveTree(tree, root, out, 0);
                // the picked folder as the player knows it, for the Saves tab's "From:" (source_path)
                try (OutputStream os = new FileOutputStream(new File(out, ".picked"))) {
                    os.write(pickedLabel(tree, root).getBytes("UTF-8"));
                }
            } catch (Exception e) {
                err = e.getMessage() != null ? e.getMessage() : "Could not read that folder.";
            }
            bootLog("saves: picked " + tree + " -> " + (err == null ? mSaveCopyBytes + " bytes copied" : err));
            if (err != null) {
                deleteTree(out);
                final String msg = err;
                runOnUiThread(() -> Toast.makeText(this, msg, Toast.LENGTH_LONG).show());
                nativeOnPicked(REQ_PICK_SAVE, null);
            } else {
                nativeOnPicked(REQ_PICK_SAVE, out.getAbsolutePath());
            }
        }).start();
    }

    // "Download/Saves" for the phone's storage ("primary:Download/Saves"), "SD card: Saves" for another volume, else
    // the folder's name as its provider shows it
    private String pickedLabel(Uri tree, String root) {
        if ("com.android.externalstorage.documents".equals(tree.getAuthority())) {
            int c = root.indexOf(':');
            if (c >= 0) {
                String vol = root.substring(0, c), rel = root.substring(c + 1);
                if (vol.equals("primary")) return rel.isEmpty() ? "Internal storage" : rel;
                return "SD card" + (rel.isEmpty() ? "" : ": " + rel);
            }
        }
        try (Cursor c = getContentResolver().query(DocumentsContract.buildDocumentUriUsingTree(tree, root),
                                                   new String[] {DocumentsContract.Document.COLUMN_DISPLAY_NAME}, null, null, null)) {
            if (c != null && c.moveToFirst() && c.getString(0) != null) return c.getString(0);
        } catch (Exception ignored) {
        }
        return "the folder you picked";
    }

    private void copySaveTree(Uri tree, String docId, File dir, int depth) throws IOException {
        if (depth > SAVE_COPY_MAX_DEPTH) return;
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, docId);
        String[] cols = {DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                         DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
                         DocumentsContract.Document.COLUMN_LAST_MODIFIED};
        try (Cursor c = getContentResolver().query(children, cols, null, null, null)) {
            if (c == null) throw new IOException("Could not read that folder.");
            while (c.moveToNext()) {
                if (++mSaveCopyVisits > SAVE_COPY_MAX_VISITS)
                    throw new IOException("That folder is too big to search. Choose one closer to the save.");
                String id = c.getString(0), name = c.getString(1), mime = c.getString(2);
                long size = c.isNull(3) ? -1 : c.getLong(3), mtime = c.isNull(4) ? 0 : c.getLong(4);
                if (name == null || name.isEmpty() || name.startsWith(".") || name.contains("/")) continue;
                if (DocumentsContract.Document.MIME_TYPE_DIR.equals(mime)) {
                    File sub = new File(dir, name);
                    sub.mkdirs();
                    copySaveTree(tree, id, sub, depth + 1);
                    continue;
                }
                String lower = name.toLowerCase();
                if (!lower.endsWith(".sav") && !lower.endsWith(".jpg")) continue;
                if (size > SAVE_COPY_MAX_FILE) continue;
                Uri doc = DocumentsContract.buildDocumentUriUsingTree(tree, id);
                File to = new File(dir, name);
                try (InputStream is = getContentResolver().openInputStream(doc); OutputStream os = new FileOutputStream(to)) {
                    if (is == null) throw new IOException("Could not read " + name + ".");
                    byte[] buf = new byte[1 << 16];
                    int k;
                    while ((k = is.read(buf)) > 0) {
                        os.write(buf, 0, k);
                        if ((mSaveCopyBytes += k) > SAVE_COPY_MAX_TOTAL)
                            throw new IOException("That folder holds too much. Choose one closer to the save.");
                    }
                }
                // the slot list's dates are the files' times (caption.sav: when the game wrote the slot), which the
                // converter keeps: so the copy keeps them too
                if (mtime > 0) to.setLastModified(mtime);
            }
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == REQ_PICK_SAVE) {
            if (resultCode == RESULT_OK && data != null && data.getData() != null) copyPickedSaves(data.getData());
            else nativeOnPicked(REQ_PICK_SAVE, null);  // (cancelled)
            return;
        }
        if (requestCode == REQ_PICK_DRIVER) {
            if (resultCode == RESULT_OK && data != null && data.getData() != null) installPickedDriver(data.getData());
            else nativeOnDriverInstalled(null, null);  // (cancelled)
            return;
        }
        String path = null;
        if (resultCode == RESULT_OK && data != null && data.getData() != null) {
            path = realPath(data.getData());
            if (path == null) {
                Toast.makeText(this,
                    "Only folders on the phone's internal storage are supported (move the game files there).",
                    Toast.LENGTH_LONG).show();
            }
        }
        nativeOnPicked(requestCode, path);
    }

    // SAF tree/document URI -> real path, for the primary storage only.
    private String realPath(Uri uri) {
        try {
            String docId;
            if ("com.android.externalstorage.documents".equals(uri.getAuthority())) {
                docId = "tree".equals(uri.getPathSegments().get(0))
                        ? DocumentsContract.getTreeDocumentId(uri)
                        : DocumentsContract.getDocumentId(uri);
            } else {
                return null;
            }
            if (!docId.startsWith("primary:")) return null;
            String rel = docId.substring("primary:".length());
            File base = Environment.getExternalStorageDirectory();
            return rel.isEmpty() ? base.getAbsolutePath() : new File(base, rel).getAbsolutePath();
        } catch (Exception e) {
            return null;
        }
    }

    // ------------------------------------------------------------------ JNI (libmain.so)
    static native void nativeSetContext(Context context);
    static native void nativeOnPicked(int requestCode, String path);
    static native void nativeSwgenDone(int handle, int exitCode);
    static native void nativeOnDriverInstalled(String name, String error);
}
