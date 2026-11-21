#!/usr/bin/env python3
"""ساخت ایندکس apt (Packages / Packages.gz) برای یک پوشهٔ deb — بدون وابستگی بیرونی.

استفاده:
    python3 mkindex.py /opt/gitlab-offline

ساختار خروجی:
    <dir>/pool/...            (فایل‌های deb، هرجا که باشند)
    <dir>/Packages
    <dir>/Packages.gz
    <dir>/Release             (حداقلی؛ چون سورس با trusted=yes استفاده می‌شود)
"""
import gzip
import hashlib
import os
import sys
import tarfile
import time
import io

FIELDS_ORDER = [
    "Package", "Version", "Architecture", "Maintainer", "Installed-Size",
    "Depends", "Pre-Depends", "Recommends", "Suggests", "Conflicts", "Breaks",
    "Replaces", "Provides", "Section", "Priority", "Homepage", "Description",
]


def read_ar_member(path, wanted_suffixes):
    """خواندن یک عضو از آرشیو ar (فرمت deb) با stdlib."""
    with open(path, "rb") as fh:
        magic = fh.read(8)
        if magic != b"!<arch>\n":
            raise ValueError(f"not an ar archive: {path}")
        while True:
            header = fh.read(60)
            if len(header) < 60:
                return None
            name = header[0:16].decode("utf-8", "replace").strip().rstrip("/")
            size = int(header[48:58].decode().strip())
            data = fh.read(size)
            if size % 2:
                fh.read(1)
            if any(name.startswith(sfx) for sfx in wanted_suffixes):
                return name, data


def tar_bytes(data):
    tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    try:
        for member in tf.getmembers():
            if member.isfile() and os.path.basename(member.name) == "control":
                return tf.extractfile(member).read().decode("utf-8", "replace")
    finally:
        tf.close()
    return None


def parse_control(path):
    member = read_ar_member(path, ("control.tar",))
    if not member:
        raise ValueError(f"control.tar not found in {path}")
    control = tar_bytes(member[1])
    if control is None:
        raise ValueError(f"control file not found in {path}")
    fields, last = {}, None
    for line in control.splitlines():
        if line.startswith((" ", "\t")) and last:
            fields[last] += "\n" + line
        elif ": " in line:
            k, v = line.split(": ", 1)
            fields[k] = v
            last = k
    return fields


def hashes(path):
    h = {"MD5sum": hashlib.md5(), "SHA1": hashlib.sha1(), "SHA256": hashlib.sha256()}
    size = 0
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            for v in h.values():
                v.update(chunk)
    return {k: v.hexdigest() for k, v in h.items()}, size


def main(root):
    root = os.path.abspath(root)
    debs = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.endswith(".deb"):
                debs.append(os.path.join(dirpath, fn))
    if not debs:
        print(f"هیچ فایل .deb در {root} پیدا نشد", file=sys.stderr)
        return 1

    stanzas = []
    for deb in sorted(debs):
        ctl = parse_control(deb)
        digest, size = hashes(deb)
        rel = os.path.relpath(deb, root)
        for k in FIELDS_ORDER:
            if k in ctl:
                stanzas.append((k, ctl[k]))
        stanzas.append(("Filename", f"./{rel}"))
        stanzas.append(("Size", str(size)))
        for k in ("MD5sum", "SHA1", "SHA256"):
            stanzas.append((k, digest[k]))
        stanzas.append(None)

    out = []
    for item in stanzas:
        if item is None:
            out.append("")
        else:
            out.append(f"{item[0]}: {item[1]}")
    body = "\n".join(out).rstrip() + "\n"

    with open(os.path.join(root, "Packages"), "w", encoding="utf-8") as fh:
        fh.write(body)
    with gzip.GzipFile(os.path.join(root, "Packages.gz"), "wb", mtime=0) as fh:
        fh.write(body.encode())

    # Release حداقلی + هش فایل‌های ایندکس (هشدار apt را خاموش می‌کند)
    def digest(path, algo):
        h = hashlib.new(algo)
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()

    lines = [
        "Origin: gitlab-offline",
        "Label: gitlab-offline",
        "Suite: offline",
        "Codename: offline",
        "Date: " + time.strftime("%a, %d %b %Y %H:%M:%S UTC", time.gmtime()),
        "Architectures: amd64 all",
        "Components: main",
        "Description: GitLab offline package bundle",
        "MD5Sum:",
    ]
    for idx in ("Packages", "Packages.gz"):
        p = os.path.join(root, idx)
        lines.append(f" {digest(p, 'md5')} {os.path.getsize(p)} {idx}")
    lines.append("SHA256:")
    for idx in ("Packages", "Packages.gz"):
        p = os.path.join(root, idx)
        lines.append(f" {digest(p, 'sha256')} {os.path.getsize(p)} {idx}")
    with open(os.path.join(root, "Release"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    print(f"✅ {len(debs)} پکیج ایندکس شد در {root}")
    for deb in debs:
        print(f"   - {os.path.relpath(deb, root)}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
