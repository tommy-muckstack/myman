#!/usr/bin/env python3
"""Build a local preview bundle. Never installs, launches, signs for release or uploads."""
from pathlib import Path
import subprocess, shutil, plistlib, sys
root = Path(__file__).resolve().parents[1]
if '--skip-build' not in sys.argv:
    subprocess.run(['swift', 'build'], cwd=root, check=True)
build = root / '.build/debug'
app = root / '.build/local/My Man Preview.app'
# Only replace the generated local preview folder owned by this script.
if app.exists(): shutil.rmtree(app)
for name in ['MacOS','Resources','Frameworks']: (app/'Contents'/name).mkdir(parents=True, exist_ok=True)
shutil.copy2(build/'MyMan', app/'Contents/MacOS/MyMan')
shutil.copytree(build/'MyMan_MyMan.bundle', app/'Contents/Resources/MyMan_MyMan.bundle')
for slice in (root/'.build/artifacts').rglob('macos-arm64_x86_64'):
    for framework in slice.glob('*.framework'):
        dest = app/'Contents/Frameworks'/framework.name
        if not dest.exists(): shutil.copytree(framework, dest, symlinks=True)
subprocess.run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(app/'Contents/MacOS/MyMan')], capture_output=True)
info = dict(CFBundleExecutable='MyMan', CFBundleIdentifier='com.muckstack.myman.preview', CFBundleName='My Man Preview', CFBundlePackageType='APPL', CFBundleShortVersionString='1.1.59-preview', CFBundleVersion='71', LSMinimumSystemVersion='14.2', NSHighResolutionCapable=True, NSMicrophoneUsageDescription='Record audio when you start dictation or a recording.', NSCameraUsageDescription='Show your camera when explicitly enabled.', NSScreenCaptureUsageDescription='Capture the screen when you request a screenshot or recording.')
info.update(NSAudioCaptureUsageDescription='Record system audio for requested meeting notes.', NSCalendarsFullAccessUsageDescription='Show your calendar when you grant access.', NSAppleEventsUsageDescription='Control music while you record a meeting.')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
print(app)
