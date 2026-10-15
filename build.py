#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Сборка fhOS.

  1. NASM собирает stage 1 (src/boot.asm) и ядро (src/kernel.asm).
  2. Оба объединяются в один загрузочный образ.
  3. Образ упаковывается в загрузочный ISO (El Torito, режим
     "no emulation"): BIOS сам копирует образ в память 1000:0000.

ISO строится "руками" (ISO9660 + El Torito), без внешних утилит.
"""

import os
import shutil
import struct
import subprocess
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "src")
BUILD = os.path.join(ROOT, "build")

# NASM не умеет работать с не-ASCII (кириллическими) путями в аргументах,
# поэтому ему передаются ОТНОСИТЕЛЬНЫЕ пути, а рабочим каталогом служит
# корень проекта (передаётся в Unicode через CreateProcessW).
BOOT_ASM_REL = os.path.join("src", "boot.asm")
KERNEL_ASM_REL = os.path.join("src", "kernel.asm")
BOOT_BIN_REL = os.path.join("build", "boot.bin")
KERNEL_BIN_REL = os.path.join("build", "kernel.bin")

SECTOR = 512
LOAD_SEGMENT = 0x1000                     # BIOS грузит образ на 1000:0000

ISO_BLOCK = 2048

# ---- карта размещения ISO (в блоках по 2048 байт) ----
LBA_PVD      = 16
LBA_BRVD     = 17
LBA_TERM     = 18
LBA_CATALOG  = 19
LBA_PT_L     = 20
LBA_PT_M     = 21
LBA_ROOT     = 22
LBA_README   = 23
LBA_BOOTIMG  = 24


# =====================================================================
#  Поиск NASM
# =====================================================================
def find_nasm():
    env = os.environ.get("NASM")
    if env and os.path.isfile(env):
        return env
    which = shutil.which("nasm")
    if which:
        return which
    candidates = [
        os.path.expandvars(r"%LOCALAPPDATA%\bin\NASM\nasm.exe"),
        r"C:\Users\Девайс\AppData\Local\bin\NASM\nasm.exe",
        r"C:\Program Files\NASM\nasm.exe",
        r"C:\Program Files (x86)\NASM\nasm.exe",
    ]
    for c in candidates:
        if os.path.isfile(c):
            return c
    return None


# =====================================================================
#  Хелперы ISO9660
# =====================================================================
def both16(v):
    return struct.pack("<H", v) + struct.pack(">H", v)


def both32(v):
    return struct.pack("<I", v) + struct.pack(">I", v)


DIR_DT = bytes([126, 10, 14, 12, 0, 0, 0])       # 2026-10-14 12:00:00
VOL_DT = b"2026101412000000" + b"\x00"            # 17 байт
EMPTY_DT = b"0" * 16 + b"\x00"


def dir_record(lba, size, flags, ident):
    """Запись каталога ISO9660."""
    n = len(ident)
    length = 33 + n
    if length & 1:
        length += 1
    rec = bytearray(length)
    rec[0] = length
    rec[1] = 0
    rec[2:10] = both32(lba)
    rec[10:18] = both32(size)
    rec[18:25] = DIR_DT
    rec[25] = flags                      # 2 = каталог
    rec[26] = 0
    rec[27] = 0
    rec[28:32] = both16(1)
    rec[32] = n
    rec[33:33 + n] = ident
    return bytes(rec)


def build_pvd(bootimg_size, total_blocks):
    pvd = bytearray(ISO_BLOCK)
    pvd[0] = 1
    pvd[1:6] = b"CD001"
    pvd[6] = 1
    pvd[8:40] = b" " * 32                       # System Identifier
    pvd[40:72] = b"FHOS".ljust(32, b" ")        # Volume Identifier
    pvd[80:88] = both32(total_blocks)           # Volume Space Size
    pvd[120:124] = both16(1)                    # Volume Set Size
    pvd[124:128] = both16(1)                    # Volume Sequence Number
    pvd[128:132] = both16(ISO_BLOCK)            # Logical Block Size
    pvd[132:140] = both32(10)                   # Path Table Size
    pvd[140:144] = struct.pack("<I", LBA_PT_L)
    pvd[144:148] = struct.pack("<I", 0)
    pvd[148:152] = struct.pack(">I", LBA_PT_M)
    pvd[152:156] = struct.pack(">I", 0)
    pvd[156:190] = dir_record(LBA_ROOT, ISO_BLOCK, 2, b"\x00")
    for off in (190, 318, 446, 574):            # идентификаторы
        pvd[off:off + 128] = b" " * 128
    for off in (702, 739, 776):                 # файлы
        pvd[off:off + 37] = b" " * 37
    pvd[813:830] = VOL_DT                       # Volume Creation Date/Time
    pvd[830:847] = VOL_DT                       # Volume Modification
    pvd[847:864] = EMPTY_DT                     # Volume Expiration
    pvd[864:881] = EMPTY_DT                     # Volume Effective
    pvd[881] = 1                                # File Structure Version
    return bytes(pvd)


def build_brvd():
    brvd = bytearray(ISO_BLOCK)
    brvd[0] = 0
    brvd[1:6] = b"CD001"
    brvd[6] = 1
    brvd[7:39] = b"EL TORITO SPECIFICATION".ljust(32, b"\x00")
    brvd[71:75] = struct.pack("<I", LBA_CATALOG)
    return bytes(brvd)


def build_terminator():
    t = bytearray(ISO_BLOCK)
    t[0] = 255
    t[1:6] = b"CD001"
    t[6] = 1
    return bytes(t)


def build_boot_catalog(sector_count):
    """Каталог El Torito: режим no emulation, загрузка на LOAD_SEGMENT."""
    cat = bytearray(ISO_BLOCK)
    # --- Validation Entry (32 байта) ---
    cat[0] = 1
    cat[1] = 0                                  # платформа 80x86
    cat[4:28] = b"EL TORITO SPECIFICATION".ljust(24, b"\x00")
    cat[30] = 0x55
    cat[31] = 0xAA
    words = struct.unpack("<16H", bytes(cat[0:32]))
    checksum = (-sum(words)) & 0xFFFF
    cat[28:30] = struct.pack("<H", checksum)
    # --- Default/Initial Entry (32 байта) ---
    cat[32] = 0x88                              # загрузочная запись
    cat[33] = 0x00                              # no emulation
    cat[34:36] = struct.pack("<H", LOAD_SEGMENT)
    cat[36] = 0                                 # system type
    cat[38:40] = struct.pack("<H", sector_count)
    cat[40:44] = struct.pack("<I", LBA_BOOTIMG)
    return bytes(cat)


def build_root_dir(bootimg_size, readme_size):
    data = b""
    data += dir_record(LBA_ROOT, ISO_BLOCK, 2, b"\x00")            # "."
    data += dir_record(LBA_ROOT, ISO_BLOCK, 2, b"\x01")            # ".."
    data += dir_record(LBA_README, readme_size, 0, b"README.TXT;1")
    data += dir_record(LBA_BOOTIMG, bootimg_size, 0, b"BOOT.IMG;1")
    return data.ljust(ISO_BLOCK, b"\x00")


def build_path_tables():
    ptl = bytes([1, 0]) + struct.pack("<I", LBA_ROOT) + struct.pack("<H", 1) + b"\x00"
    ptm = bytes([1, 0]) + struct.pack(">I", LBA_ROOT) + struct.pack(">H", 1) + b"\x00"
    return ptl.ljust(ISO_BLOCK, b"\x00"), ptm.ljust(ISO_BLOCK, b"\x00")


README = (
    "fhOS - a minimal x86 operating system written in NASM.\r\n"
    "\r\n"
    "Graphical shell (VGA mode 13h, 320x200) with a top taskbar,\r\n"
    "two themes (dark/light) and an in-memory filesystem.\r\n"
    "Boots from the El Torito boot image (stage 1 + kernel).\r\n"
    "\r\n"
    "Commands: help clear about ver echo theme time mem color\r\n"
    "          ls cat write touch rm fsinfo beep reboot halt\r\n"
)


# =====================================================================
#  Сборка
# =====================================================================
def run(cmd):
    print("  $", " ".join(cmd))
    subprocess.run(cmd, check=True, cwd=ROOT)


def main():
    nasm = find_nasm()
    if not nasm:
        print("ОШИБКА: не найден nasm.exe (задайте переменную окружения NASM).")
        sys.exit(1)
    print("NASM:", nasm)

    os.makedirs(BUILD, exist_ok=True)
    boot_bin = os.path.join(BUILD, "boot.bin")
    kernel_bin = os.path.join(BUILD, "kernel.bin")

    print("[1/4] Ассемблирование stage 1...")
    run([nasm, "-f", "bin", "-o", BOOT_BIN_REL, BOOT_ASM_REL])
    boot = open(boot_bin, "rb").read()
    if len(boot) != SECTOR:
        print("ОШИБКА: stage 1 = %d байт (нужно 512)." % len(boot))
        sys.exit(1)

    print("[2/4] Ассемблирование ядра...")
    run([nasm, "-f", "bin", "-o", KERNEL_BIN_REL, KERNEL_ASM_REL])
    kernel = open(kernel_bin, "rb").read()
    print("      размер ядра: %d байт" % len(kernel))

    # --- загрузочный образ = stage1 + ядро (выровнен по блоку CD) ---
    image = boot + kernel
    image = image.ljust((len(image) + ISO_BLOCK - 1) // ISO_BLOCK * ISO_BLOCK, b"\x00")
    image_blocks = len(image) // ISO_BLOCK
    sector_count = image_blocks * (ISO_BLOCK // SECTOR)     # в 512-байтных секторах
    if sector_count > 0xFFFF:
        print("ОШИБКА: образ слишком большой.")
        sys.exit(1)
    print("[3/4] Загрузочный образ: %d байт (%d блоков CD, %d секторов)"
          % (len(image), image_blocks, sector_count))

    readme = README.encode("ascii")
    total_blocks = LBA_BOOTIMG + image_blocks

    print("[4/4] Создание загрузочного ISO (El Torito, no emulation)...")
    iso = bytearray(total_blocks * ISO_BLOCK)

    def put(lba, data):
        off = lba * ISO_BLOCK
        iso[off:off + len(data)] = data

    ptl, ptm = build_path_tables()
    put(LBA_PVD, build_pvd(len(image), total_blocks))
    put(LBA_BRVD, build_brvd())
    put(LBA_TERM, build_terminator())
    put(LBA_CATALOG, build_boot_catalog(sector_count))
    put(LBA_PT_L, ptl)
    put(LBA_PT_M, ptm)
    put(LBA_ROOT, build_root_dir(len(image), len(readme)))
    put(LBA_README, readme)
    put(LBA_BOOTIMG, image)

    iso_path = os.path.join(BUILD, "fhos.iso")
    with open(iso_path, "wb") as f:
        f.write(iso)

    print()
    print("Готово:")
    print("  ISO :", iso_path, "(%d байт, %d секторов CD)" % (len(iso), total_blocks))


if __name__ == "__main__":
    main()
