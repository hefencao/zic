#!/usr/bin/env python3
from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'


def main() -> int:
    kotlinc = shutil.which('kotlinc')
    javac = shutil.which('javac')
    if not kotlinc or not javac:
        print('SKIP: kotlinc/javac are not installed for Mihon payload Context compilation')
        return 0

    source = SOURCE.read_text(encoding='utf-8')
    match = re.search(
        r'private class MihonPayloadContext\(.*?\n}\n\ninternal val supportedMihonExtensionLibs',
        source,
        re.S,
    )
    if not match:
        raise SystemExit('MihonPayloadContext implementation not found')
    implementation = match.group(0).rsplit('\n\ninternal val supportedMihonExtensionLibs', 1)[0]

    java_sources = {
        'android/content/SharedPreferences.java': '''package android.content; public interface SharedPreferences {}''',
        'android/content/pm/ApplicationInfo.java': '''package android.content.pm; public class ApplicationInfo { public String sourceDir = ""; public String publicSourceDir = ""; }''',
        'android/content/res/AssetManager.java': '''package android.content.res; public class AssetManager {}''',
        'android/content/res/Resources.java': '''package android.content.res; public class Resources { private final AssetManager assets = new AssetManager(); public AssetManager getAssets(){ return assets; } public Theme newTheme(){ return new Theme(); } public static class Theme { public void setTo(Theme other) {} } }''',
        'android/content/Context.java': '''package android.content; import android.content.pm.ApplicationInfo; import android.content.res.AssetManager; import android.content.res.Resources; import java.io.File; public class Context { public static final String LAYOUT_INFLATER_SERVICE = "layout_inflater"; private final Resources resources = new Resources(); public Context getApplicationContext(){ return this; } public String getPackageName(){ return "host"; } public String getPackageCodePath(){ return ""; } public String getPackageResourcePath(){ return ""; } public ApplicationInfo getApplicationInfo(){ return new ApplicationInfo(); } public Context createPackageContext(String packageName, int flags){ return this; } public ClassLoader getClassLoader(){ return Context.class.getClassLoader(); } public Resources getResources(){ return resources; } public AssetManager getAssets(){ return resources.getAssets(); } public Resources.Theme getTheme(){ return resources.newTheme(); } public File getFilesDir(){ return new File("files"); } public File getCacheDir(){ return new File("cache"); } public File getCodeCacheDir(){ return new File("code-cache"); } public File getNoBackupFilesDir(){ return new File("no-backup"); } public SharedPreferences getSharedPreferences(String name, int mode){ return null; } public Object getSystemService(String name){ return null; } }''',
        'android/content/ContextWrapper.java': '''package android.content; public class ContextWrapper extends Context { private final Context base; public ContextWrapper(Context base){ this.base = base; } public Context getBaseContext(){ return base; } @Override public Object getSystemService(String name){ return base.getSystemService(name); } @Override public SharedPreferences getSharedPreferences(String name, int mode){ return base.getSharedPreferences(name, mode); } }''',
        'android/view/LayoutInflater.java': '''package android.view; import android.content.Context; public class LayoutInflater { public LayoutInflater cloneInContext(Context context){ return this; } }''',
    }

    kotlin = f'''package dev.zic.pluginhost

import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import android.content.res.AssetManager
import android.content.res.Resources
import android.view.LayoutInflater
import java.io.File

private fun safePath(value: String): String = value.replace(Regex("[^A-Za-z0-9._-]"), "_")

{implementation}
'''

    with tempfile.TemporaryDirectory() as raw_temp:
        temp = Path(raw_temp)
        classes = temp / 'classes'
        classes.mkdir()
        paths: list[str] = []
        for relative, text in java_sources.items():
            path = temp / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding='utf-8')
            paths.append(str(path))
        subprocess.run([javac, '-d', str(classes), *paths], check=True)
        kotlin_path = temp / 'MihonPayloadContextSmoke.kt'
        kotlin_path.write_text(kotlin, encoding='utf-8')
        subprocess.run(
            [kotlinc, str(kotlin_path), '-classpath', str(classes), '-d', str(temp / 'out.jar')],
            check=True,
        )
    print('Mihon payload Context compilation: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
