"""Package a locally supplied, verified Snapchat 14.32.0.53 decrypted IPA.

Only the main executable's load commands and the main Info.plist are changed.
The original IPA is preserved. Signing is a separate, device-account step.
"""

import argparse
import copy
import hashlib
import json
import plistlib
import re
import shutil
import struct
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

EXPECTED_EXECUTABLE_SHA256 = "06ec08098abdb9c7829bfb1cd16dafd2b1b5a1dcafe4ededbb0434345db16a82"
LIBRARY_PATH = "@executable_path/Frameworks/SnapDuo.dylib"
MAIN = "Payload/Snapchat.app/Snapchat"
PLIST = "Payload/Snapchat.app/Info.plist"
LIBRARY_MEMBER = "Payload/Snapchat.app/Frameworks/SnapDuo.dylib"


def commands(data):
    if data[:4] != bytes.fromhex("cffaedfe"):
        raise ValueError("Expected a thin arm64 Mach-O")
    position = 32
    count, total = struct.unpack_from("<II", data, 16)
    for _ in range(count):
        kind, size = struct.unpack_from("<II", data, position)
        if size < 8 or position + size > 32 + total:
            raise ValueError("Invalid Mach-O command")
        yield kind, position, size
        position += size
    if position != 32 + total:
        raise ValueError("Invalid Mach-O header size")


def check_plain(data):
    if struct.unpack_from("<I", data, 4)[0] != 0x100000c:
        raise ValueError("Expected arm64 executable")
    for kind, at, _ in commands(data):
        if kind in (0x21, 0x2c) and struct.unpack_from("<I", data, at+16)[0]:
            raise ValueError("Encrypted executable requires decryption first")


def patch_executable(original):
    if hashlib.sha256(original).hexdigest() != EXPECTED_EXECUTABLE_SHA256:
        raise ValueError("Input executable differs from the inspected Snapchat build")
    check_plain(original)
    data = bytearray(original)
    count, total = struct.unpack_from("<II", data, 16)
    first_section = len(data)
    sdk_command = None
    for kind, at, _ in commands(data):
        if kind == 0x19:
            sections = struct.unpack_from("<I", data, at+64)[0]
            for i in range(sections):
                offset = struct.unpack_from("<I", data, at+72+i*80+48)[0]
                if offset:
                    first_section = min(first_section, offset)
        elif kind == 0x32:
            sdk_command = at
            platform, minimum, sdk = struct.unpack_from("<III", data, at+8)
            if platform != 2 or sdk != 0x1a0500:
                raise ValueError("Unexpected original platform or SDK")
    if sdk_command is None:
        raise ValueError("Missing SDK compatibility declaration")
    name = LIBRARY_PATH.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    at = 32 + total
    if at + size > first_section or any(data[at:at+size]):
        raise ValueError("Insufficient empty load-command space")
    command = struct.pack("<6I", 0xc, size, 24, 0, 0x10000, 0x10000) + name
    data[at:at+size] = command.ljust(size, b"\0")
    struct.pack_into("<II", data, 16, count+1, total+size)
    # iOS uses the SDK field to select display compatibility behavior.
    # This is a binary compatibility opt-in, not a recompilation of Snapchat.
    struct.pack_into("<I", data, sdk_command+16, 0x1b0100)
    assert data[first_section:] == original[first_section:]
    check_plain(data)
    list(commands(data))
    return data


def file_digest(archive, name):
    with archive.open(name) as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def package(source, library, output):
    if output.exists() or output.with_suffix(".partial").exists():
        raise FileExistsError("Output already exists")
    dynamic_library = library.read_bytes()
    check_plain(dynamic_library)
    if struct.unpack_from("<I", dynamic_library, 12)[0] != 6:
        raise ValueError("Expected a dylib")
    temporary = output.with_suffix(".partial")
    with ZipFile(source) as original:
        if original.testzip() is not None:
            raise ValueError("Input IPA CRC check failed")
        metadata = plistlib.loads(original.read(PLIST))
        if metadata["CFBundleIdentifier"] != "com.toyopagroup.picaboo" or metadata["CFBundleVersion"] != "14.32.0.53":
            raise ValueError("Incorrect Snapchat version")
        modified = patch_executable(original.read(MAIN))
        metadata["UISupportedInterfaceOrientations"] = [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ]
        metadata["UIRequiresFullScreen"] = False
        metadata["MinimumOSVersion"] = "27.1"
        metadata["SnapDuoPatchVersion"] = "0.2"
        metadata["SnapDuoPrivateAppGroupStorage"] = True
        if LIBRARY_MEMBER in original.namelist():
            raise ValueError("Input already contains SnapDuo")
        with ZipFile(temporary, "x", compression=ZIP_DEFLATED, compresslevel=3) as result:
            for member in original.infolist():
                if member.is_dir():
                    continue
                entry = copy.copy(member)
                entry.compress_type = ZIP_DEFLATED
                with original.open(member) as reader:
                    magic = reader.read(4)
                if magic in (bytes.fromhex("cffaedfe"), bytes.fromhex("cafebabe")):
                    entry.create_system = 3
                    entry.external_attr = 0o100755 << 16
                if member.filename == MAIN:
                    result.writestr(entry, modified)
                elif member.filename == PLIST:
                    result.writestr(entry, plistlib.dumps(metadata))
                else:
                    with original.open(member) as reader, result.open(entry, "w", force_zip64=True) as writer:
                        shutil.copyfileobj(reader, writer, 1024*1024)
            entry = ZipInfo(LIBRARY_MEMBER)
            entry.create_system = 3
            entry.external_attr = 0o100755 << 16
            entry.compress_type = ZIP_DEFLATED
            result.writestr(entry, dynamic_library)
        with ZipFile(temporary) as result:
            assert result.testzip() is None
            assert len(result.namelist()) == len(set(result.namelist()))
            assert result.read(MAIN) == modified
            assert result.read(LIBRARY_MEMBER) == dynamic_library
            written_metadata = plistlib.loads(result.read(PLIST))
            assert written_metadata["SnapDuoPatchVersion"] == "0.2"
            assert written_metadata["SnapDuoPrivateAppGroupStorage"] is True
            assert (result.getinfo(MAIN).external_attr >> 16) & 0o111 == 0o111
            assert (result.getinfo(LIBRARY_MEMBER).external_attr >> 16) & 0o111 == 0o111
            for member in original.infolist():
                if member.is_dir() or member.filename in (MAIN, PLIST):
                    continue
                assert file_digest(original, member.filename) == file_digest(result, member.filename), member.filename
            assert LIBRARY_PATH.encode() in result.read(MAIN)[:20000]
    temporary.rename(output)
    print(json.dumps({
        "output": output.name,
        "bytes": output.stat().st_size,
        "extension_sha256": hashlib.sha256(dynamic_library).hexdigest(),
        "input_build": "14.32.0.53",
        "signed": False,
        "device_tested": False,
        "patch_version": "0.2",
        "app_group_storage": "private main-app container; no extension sharing",
        "sdk_compatibility_opt_in": "27.1",
    }, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("library", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    package(args.source, args.library, args.output)
