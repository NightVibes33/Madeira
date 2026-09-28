#!/usr/bin/env python3
"""Generate a deterministic static x86-64 Linux ELF for the first SteamOS-iOS gate."""

from __future__ import annotations

import argparse
import pathlib
import struct

MESSAGE = b"STEAMOS_IOS_ELF_OK\n"
BASE = 0x400000
CODE_OFFSET = 0x80


def build() -> bytes:
    code = bytearray()
    code += b"\xB8\x01\x00\x00\x00"
    code += b"\xBF\x01\x00\x00\x00"
    lea_at = len(code)
    code += b"\x48\x8D\x35\x00\x00\x00\x00"
    code += b"\xBA" + struct.pack("<I", len(MESSAGE))
    code += b"\x0F\x05"
    code += b"\xB8\x3C\x00\x00\x00"
    code += b"\x31\xFF"
    code += b"\x0F\x05"

    message_offset = CODE_OFFSET + len(code)
    next_rip = BASE + CODE_OFFSET + lea_at + 7
    disp = (BASE + message_offset) - next_rip
    struct.pack_into("<i", code, lea_at + 3, disp)

    total_size = message_offset + len(MESSAGE)
    ident = bytearray(16)
    ident[0:4] = b"\x7fELF"
    ident[4] = 2
    ident[5] = 1
    ident[6] = 1

    ehdr = struct.pack(
        "<16sHHIQQQIHHHHHH",
        bytes(ident), 2, 62, 1, BASE + CODE_OFFSET, 64, 0, 0, 64, 56, 1, 0, 0, 0,
    )
    phdr = struct.pack(
        "<IIQQQQQQ",
        1, 5, 0, BASE, BASE, total_size, total_size, 0x1000,
    )

    blob = bytearray(total_size)
    blob[:64] = ehdr
    blob[64:120] = phdr
    blob[CODE_OFFSET:CODE_OFFSET + len(code)] = code
    blob[message_offset:] = MESSAGE
    return bytes(blob)


def write_header(path: pathlib.Path, blob: bytes) -> None:
    rows = []
    for i in range(0, len(blob), 12):
        rows.append("    " + ", ".join(f"0x{b:02x}" for b in blob[i:i + 12]) + ",")
    path.write_text(
        "#ifndef STEAMOS_IOS_STATIC_SMOKE_H\n"
        "#define STEAMOS_IOS_STATIC_SMOKE_H\n\n"
        "static const unsigned char steamos_ios_static_smoke_elf[] = {\n"
        + "\n".join(rows)
        + "\n};\n"
        f"static const unsigned int steamos_ios_static_smoke_elf_len = {len(blob)};\n\n"
        "#endif\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--elf", type=pathlib.Path, required=True)
    parser.add_argument("--header", type=pathlib.Path)
    args = parser.parse_args()
    blob = build()
    args.elf.parent.mkdir(parents=True, exist_ok=True)
    args.elf.write_bytes(blob)
    if args.header:
        args.header.parent.mkdir(parents=True, exist_ok=True)
        write_header(args.header, blob)


if __name__ == "__main__":
    main()
