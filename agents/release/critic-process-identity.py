#!/usr/bin/env python3
"""Print a high-resolution, timezone-independent process start identity."""

from __future__ import annotations

import ctypes
import ctypes.util
from pathlib import Path
import sys
from typing import Optional


class ProcBsdInfo(ctypes.Structure):
    """Darwin's public struct proc_bsdinfo (PROC_PIDTBSDINFO)."""

    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


def linux_identity(pid: int) -> Optional[str]:
    data = Path(f"/proc/{pid}/stat").read_bytes()
    end = data.rfind(b")")
    if end < 0:
        return None
    fields = data[end + 2 :].split()
    if len(fields) <= 19:
        return None
    start_ticks = int(fields[19])
    boot_id = int(
        Path("/proc/sys/kernel/random/boot_id")
        .read_text(encoding="ascii")
        .strip()
        .replace("-", ""),
        16,
    )
    return f"{boot_id}-{start_ticks}"


def darwin_identity(pid: int) -> Optional[str]:
    # The public XNU proc_bsdinfo ABI is 136 bytes on supported 64-bit macOS.
    size = ctypes.sizeof(ProcBsdInfo)
    if size != 136:
        return None
    library = ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib"
    libproc = ctypes.CDLL(library, use_errno=True)
    libproc.proc_pidinfo.argtypes = [
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    ]
    libproc.proc_pidinfo.restype = ctypes.c_int
    info = ProcBsdInfo()
    if libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size:
        return None
    if info.pbi_pid != pid:
        return None
    return f"{info.pbi_start_tvsec}-{info.pbi_start_tvusec}"


def process_identity(pid: int) -> Optional[str]:
    if pid <= 0:
        return None
    if sys.platform.startswith("linux"):
        return linux_identity(pid)
    if sys.platform == "darwin":
        return darwin_identity(pid)
    return None


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    try:
        identity = process_identity(int(sys.argv[1]))
    except (OSError, ValueError, OverflowError, ctypes.ArgumentError):
        return 1
    if identity is None:
        return 1
    print(identity)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
