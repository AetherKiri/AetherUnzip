"""Regenerate small local fixtures. RAR and codec fixtures have separate provenance."""
import bz2
from gzip import compress
from io import BytesIO
import json
import lzma
from pathlib import Path
import shutil
import stat
import struct
import tarfile
import zipfile
from zlib import adler32, compress as zlib_compress, crc32

root = Path(__file__).parent
message = b"AetherUnzip fixture\n"
files = {"notes.txt": message, "docs/readme.txt": b"Nested document\n", "docs/空白.txt": b""}


def zip_file(name, content):
    with zipfile.ZipFile(root / name, "w") as archive:
        for path, data in content.items():
            info = zipfile.ZipInfo(path)
            archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED)


zip_file("sample.zip", files)
wrapper = b"\x00\x01PKG1\x00\x00"
profile_payload = (root / "sample.zip").read_bytes()
(root / "profile-box.bin").write_bytes(wrapper + profile_payload + b"Unrelated footer")
(root / "format-profile.json").write_text(json.dumps({
    "version": 1, "signatureOffset": 2, "signatureHex": "504b4731", "payloadOffset": len(wrapper),
    "payloadLength": len(profile_payload), "payloadName": "payload.zip", "expectedFormat": "zip"
}, indent=2) + "\n", encoding="utf-8")
# A self-extracting-style prefix. The fixture contains no executable program.
(root / "prefixed-zip.bin").write_bytes(b"MZ\0AetherUnzip inert prefix\0" +
                                        (root / "sample.zip").read_bytes())
zip_file("empty.zip", {})
zip_file("layout.zip", {"Layout/": b"", "Layout/notes.txt": message, "Layout/docs/readme.txt": files["docs/readme.txt"]})
zip_file("layout-unsafe.zip", {"Layout/notes.txt": message, "Layout/../escaped.txt": message})
zip_file("traversal.zip", {"../escaped.txt": message})
zip_file("absolute.zip", {"/escaped.txt": message})
zip_file("windows-path.zip", {"C:\\escaped.txt": message})
zip_file("deep.zip", {"a/b/c/d.txt": message})
zip_file("resource-index.zip", {"./docs/": b"", "./docs/report.txt": message,
                                "docs/report.txt": b"Duplicate path\n",
                                "docs/regional/样本.txt": b"Regional text\n",
                                "../excluded.txt": b"Outside the resource namespace\n",
                                "file": b"File with conflicting descendants\n",
                                "file/child.txt": b"Conflicting descendant\n",
                                "file-sibling.txt": b"Sibling stays visible\n",
                                "empty/": b""})
zip_file("composition-patch.zip", {"plain.txt": b"Patch bytes\n", "packages": b"Conflicting file\n"})

with BytesIO() as nested:
    with zipfile.ZipFile(nested, "w") as middle:
        middle.writestr(zipfile.ZipInfo("deep.zip"), (root / "sample.zip").read_bytes())
    zip_file("nested.zip", {"packages/内层.bin": nested.getvalue(), "plain.txt": message,
                            "visible.zip": nested.getvalue()})


def xp3_chunk(tag, data):
    return tag + struct.pack("<Q", len(data)) + data


def xp3_file(name, entries, *, compressed_index=False, chained=False):
    blob = bytearray(b"XP3\r\n \n\x1a\x8b\x67\x01" + b"\0" * 8)
    records = []
    for path, parts, flags, digest_delta in entries:
        segments = bytearray()
        content = bytearray()
        packed_size = 0
        for data, method in parts:
            packed = zlib_compress(data) if method else data
            segments.extend(struct.pack("<IQQQ", method, len(blob), len(data), len(packed)))
            content.extend(data)
            packed_size += len(packed)
            blob.extend(packed)
        name_utf16 = path.encode("utf-16le")
        info = struct.pack("<IQQH", flags, len(content), packed_size, len(name_utf16) // 2)
        chunks = xp3_chunk(b"info", info + name_utf16)
        chunks += xp3_chunk(b"segm", segments)
        chunks += xp3_chunk(b"adlr", struct.pack("<I", adler32(content) ^ digest_delta))
        records.append(xp3_chunk(b"File", chunks))
    struct.pack_into("<Q", blob, 11, len(blob))
    if chained:
        blob.extend(struct.pack("<BQQ", 0x80, 0, len(blob) + 17))
    index = b"".join(records)
    if compressed_index:
        packed = zlib_compress(index)
        blob.extend(struct.pack("<BQQ", 1, len(packed), len(index)) + packed)
    else:
        blob.extend(struct.pack("<BQ", 0, len(index)) + index)
    (root / name).write_bytes(blob)


xp3_file("sample.xp3", [("notes.txt", [(message, 0)], 0, 0),
    ("docs/样本📦.txt", [(b"Stored prefix\n", 0), (b"XP3 resource line\n" * 12000, 1)], 0, 0),
    ("empty.txt", [], 0, 0)], compressed_index=True, chained=True)
xp3_file("xp3-raw.xp3", [("notes.txt", [(message, 0)], 0, 0)])
# Inert aligned prefix with the same wrapper marker used by the KiriKiri reader.
(root / "xp3-wrapped.bin").write_bytes(b"MZ" + b"\0" * (32768 + 16 - 2) +
                                      (root / "xp3-raw.xp3").read_bytes())
xp3_file("xp3-protected.xp3", [("protected.txt", [(message, 0)], 0x80000000, 0),
                                ("notes.txt", [(message, 1)], 0, 0)])
xp3_file("xp3-checksum.xp3", [("notes.txt", [(message, 1)], 0, 1)])
xp3_file("xp3-unsafe.xp3", [("../escaped.txt", [(message, 0)], 0, 0)])
(root / "xp3-truncated.xp3").write_bytes((root / "sample.xp3").read_bytes()[:-2])
cyclic = bytearray((root / "sample.xp3").read_bytes())
first_index = struct.unpack_from("<Q", cyclic, 11)[0]
struct.pack_into("<Q", cyclic, first_index + 9, first_index)
(root / "xp3-index-cycle.xp3").write_bytes(cyclic)
zip_file("expansion.zip", {"large.txt": b"x" * 220_000})
with zipfile.ZipFile(root / "symlink.zip", "w") as archive:
    info = zipfile.ZipInfo("link")
    info.create_system = 3
    info.external_attr = (stat.S_IFLNK | 0o777) << 16
    archive.writestr(info, "../outside")

# Lower the threshold so the entry and end record actually use ZIP64.
limit = zipfile.ZIP64_LIMIT
zipfile.ZIP64_LIMIT = 8
try:
    zip_file("small-zip64.zip", {"notes.txt": message})
finally:
    zipfile.ZIP64_LIMIT = limit


def split_zip64():
    """Exercise disk-relative ZIP64 offsets and a cross-disk central directory."""
    def file_records(name, data, start_disk, offset):
        crc = crc32(data)
        local = struct.pack("<I5H3I2H", 0x04034B50, 45, 0, 0, 0, 0, crc,
                            len(data), len(data), len(name), 0) + name + data
        extra = struct.pack("<HHQI", 1, 12, offset, start_disk)
        central = struct.pack("<I6H3I5H2I", 0x02014B50, 0x032D, 45, 0, 0, 0, 0, crc,
                              len(data), len(data), len(name), len(extra), 0, 0xFFFF, 0,
                              (stat.S_IFREG | 0o644) << 16, 0xFFFFFFFF) + name + extra
        return local, central

    first, first_cd = file_records(b"first.txt", b"First ZIP64 disk\n", 0, 4)
    second, second_cd = file_records(b"second.txt", b"Second ZIP64 disk\n", 1, 0)
    central_size = len(first_cd) + len(second_cd)
    end = struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 2, 1, 1, 2, central_size, len(second))
    locator = struct.pack("<IIQI", 0x07064B50, 2, len(second_cd), 3)
    legacy = struct.pack("<I4H2IH", 0x06054B50, 2, 1, 1, 2, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    parts = root / "independent"
    parts.mkdir(exist_ok=True)
    (parts / "small-disk64.z01").write_bytes(struct.pack("<I", 0x08074B50) + first)
    (parts / "small-disk64.z02").write_bytes(second + first_cd)
    (parts / "small-disk64.zip").write_bytes(second_cd + end + locator + legacy)


split_zip64()

buffer = BytesIO()
with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
    info = tarfile.TarInfo("./")
    info.type = tarfile.DIRTYPE
    archive.addfile(info)
    info = tarfile.TarInfo("./notes.txt")
    info.size = len(message)
    archive.addfile(info, BytesIO(message))
(root / "sample.tar").write_bytes(buffer.getvalue())
(root / "sample.tar.gz").write_bytes(compress(buffer.getvalue(), mtime=0))
with BytesIO() as wrapped:
    with tarfile.open(fileobj=wrapped, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        info = tarfile.TarInfo("./Layout/")
        info.type = tarfile.DIRTYPE
        archive.addfile(info)
        for path in ("notes.txt", "docs/readme.txt"):
            info = tarfile.TarInfo(f"./Layout/{path}")
            info.size = len(files[path])
            archive.addfile(info, BytesIO(files[path]))
    (root / "layout.tar.gz").write_bytes(compress(wrapped.getvalue(), mtime=0))
(root / "notes.gz").write_bytes(compress(message, mtime=0))
(root / "empty.gz").write_bytes(compress(b"", mtime=0))
(root / "members.gz").write_bytes(compress(message, mtime=0) +
                                  compress(b"Additional member\n", mtime=0))

# The filter emits more than one output block before seeing these trailers.
large_gzip = compress(bytes(range(256)) * 800, mtime=0)
for name, index in [("gzip-crc", -8), ("gzip-size", -4)]:
    damaged = bytearray(large_gzip)
    damaged[index] ^= 1
    (root / f"{name}.gz").write_bytes(damaged)
for suffix, encoder in [("xz", lzma.compress), ("bz2", bz2.compress)]:
    (root / f"notes.{suffix}").write_bytes(encoder(message))
    (root / f"sample.tar.{suffix}").write_bytes(encoder(buffer.getvalue()))

swift = root.parent.parent / "bindings/swift/Tests/AetherUnzipKitTests/Fixtures"
for name in ["sample.zip", "layout.zip", "layout.tar.gz", "expansion.zip", "prefixed-zip.bin", "nested.zip", "sample.xp3",
             "profile-box.bin", "format-profile.json"]:
    shutil.copyfile(root / name, swift / name)
shutil.copyfile(root / "gzip-crc.gz", swift / "gzip-crc.gz")
