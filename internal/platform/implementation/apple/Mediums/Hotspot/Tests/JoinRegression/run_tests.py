#!/usr/bin/env python3
# Copyright 2026 Google LLC
# SPDX-License-Identifier: Apache-2.0
"""Compile the verbatim iOS join implementation against deterministic OS boundaries."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--revision', help='Read production source from this git revision (baseline RED).')
parser.add_argument('--test', help='One XCTest method, e.g. testConsentCanTakeLongerThan18Seconds.')
parser.add_argument('--output-dir', type=Path, help='Keep generated source, executable and provenance here.')
args = parser.parse_args()
here = Path(__file__).resolve().parent
sdk = Path(subprocess.check_output(['git', '-C', str(here), 'rev-parse', '--show-toplevel'], text=True).strip())
relative = 'internal/platform/implementation/apple/Mediums/Hotspot/GNCHotspotMedium.m'
source = sdk / relative
text = subprocess.check_output(['git', '-C', str(sdk), 'show', f'{args.revision}:{relative}'], text=True) if args.revision else source.read_text()
out = args.output_dir or Path(tempfile.mkdtemp(prefix='nearby-hotspot-join-tests-'))
out.mkdir(parents=True, exist_ok=True)
constants = text[text.index('#if TARGET_OS_IOS', text.index('NS_ASSUME_NONNULL_BEGIN')):text.index('@interface GNCHotspotMedium ()')]
start = text.index('- (BOOL)connectToWifiNetworkWithSSID:')
end = text.index('- (void)disconnectToWifiNetworkWithSSID:', start)
methods = text[start:end]
# The join gate, both connect selectors, and SSID lookup methods are copied
# verbatim; only their OS API/monotonic clock boundaries are replaced.
helper_start = text.index('- (NSString *)getCurrentWifiSSID {')
helpers = text[helper_start:text.index('\n@end', helper_start)]
generated = 'NS_ASSUME_NONNULL_BEGIN\n' + constants + '\n@implementation GNCHotspotMedium\n'
generated += '- (instancetype)init { if ((self = [super init])) _locationManager = [CLLocationManager new]; return self; }\n'
generated += f'#line {text[:start].count(chr(10)) + 1} "{source}"\n' + methods
generated += f'#line {text[:helper_start].count(chr(10)) + 1} "{source}"\n' + helpers + '\n@end\nNS_ASSUME_NONNULL_END\n'
(out / 'ActualHotspotJoin.inc').write_text(generated)
(out / 'source-evidence.json').write_text(json.dumps({
    'revision': args.revision or subprocess.check_output(['git', '-C', str(sdk), 'rev-parse', 'HEAD'], text=True).strip(),
    'working_tree': not bool(args.revision), 'source_path': relative,
    'source_sha256': hashlib.sha256(text.encode()).hexdigest(),
    'methods_sha256': hashlib.sha256(methods.encode()).hexdigest(),
    'ssid_helpers_sha256': hashlib.sha256(helpers.encode()).hexdigest(),
    'seam': 'verbatim production constants/helpers/connect methods; fake NetworkExtension/CoreLocation/monotonic clock; actual SSID lookup helpers',
}, indent=2) + '\n')
bundle = out / 'HotspotJoinTests.xctest'
binary = bundle / 'Contents/MacOS/HotspotJoinTests'
binary.parent.mkdir(parents=True, exist_ok=True)
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleExecutable': binary.name, 'CFBundleIdentifier': 'local.nearby.hotspot-join-tests',
    'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '1'}))
developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
frameworks = developer / 'Platforms/MacOSX.platform/Developer/Library/Frameworks'
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-bundle', '-g',
    '-Wno-incomplete-implementation', '-mmacosx-version-min=14.0', '-F', str(frameworks),
    '-I', str(out), '-framework', 'Foundation', '-framework', 'XCTest',
    '-Wl,-rpath,' + str(frameworks), '-o', str(binary), str(here / 'HotspotJoinTests.m')], check=True)
command = ['xcrun', 'xctest']
if args.test:
    command += ['-XCTest', 'HotspotJoinTests/' + args.test]
command.append(str(bundle))
print('Generated source and provenance:', out, flush=True)
raise SystemExit(subprocess.run(command).returncode)
