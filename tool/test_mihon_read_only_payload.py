#!/usr/bin/env python3
"""Compile and execute the production Mihon read-only APK staging helper."""
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

kotlinc = shutil.which('kotlinc')
java = shutil.which('java')
if not kotlinc or not java:
    print('SKIP: kotlinc/java are not installed for Mihon read-only APK staging')
    raise SystemExit(0)

root = Path(__file__).resolve().parents[1]
source = (
    root
    / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt'
).read_text()
match = re.search(
    r'(private fun stageReadOnlyMihonApk\(.*?)(?=\nprivate fun extractNativeLibraries)',
    source,
    re.S,
)
if not match:
    raise SystemExit('Mihon APK staging helpers not found')
helpers = match.group(1)

with tempfile.TemporaryDirectory() as directory:
    work = Path(directory)
    smoke = work / 'Smoke.kt'
    smoke.write_text(
        '''import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission
import java.security.MessageDigest
'''
        + helpers
        + '''
fun main() {
    val root = Files.createTempDirectory("zic-mihon-stage-").toFile()
    val payload = File(root, "source.apk")
    val bytes = ByteArray(4096) { (it and 0xff).toByte() }
    payload.writeBytes(bytes)
    val sha = MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    val target = File(root, "runtime/extension.apk")
    target.parentFile.mkdirs()
    target.writeText("old")
    val staged = stageReadOnlyMihonApk(
        payload,
        target,
        bytes.size.toLong(),
        sha,
        verifiedExisting = false,
    )
    check(staged.readBytes().contentEquals(bytes))
    val permissions = Files.getPosixFilePermissions(staged.toPath())
    check(PosixFilePermission.OWNER_WRITE !in permissions)
    check(PosixFilePermission.GROUP_WRITE !in permissions)
    check(PosixFilePermission.OTHERS_WRITE !in permissions)
    check(!File(staged.parentFile, staged.name + ".part").exists())
    println("Mihon read-only APK staging: OK")
}
'''
    )
    jar = work / 'smoke.jar'
    subprocess.run(['kotlinc', str(smoke), '-include-runtime', '-d', str(jar)], check=True)
    subprocess.run(['java', '-jar', str(jar)], check=True)
