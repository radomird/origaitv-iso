"""OrigaiTV's step in Omarchy's install: what the first screen hands over.

OrigaiTV's first screen on the USB stick leaves files for the installed box in
/root/origaitv-handover, laid out the way they go on the box: the account's
marker, which says its password is one nobody knows yet. This copies them
onto the new system, owned by root. With nothing there (an autoinstall, or
Omarchy's own installer after Ctrl+C) it does nothing.

It also drops what the disk's old system asked its boot loader for on its
next start only. "Restart to the boot menu" in Settings, under Power, asks
for the menu with no countdown, and so does systemd's --boot-loader-menu.
That request lives in the firmware, not on the disk. The USB stick starts
with GRUB, which never reads it, so the new system's boot loader found it on
its first start and waited there for Enter. Every later start was quiet,
since the boot loader erases the request once it has read it.

Then it asks for the first start to have no countdown at all, with
"menu-disabled", which Limine reads for that start only (and erases), ahead
of limine.conf's quiet second. So a key pressed on the keyboard or the remote
as the new system first starts can't stop it at the menu either. Every later
start keeps the quiet second, where a key still shows the menu.

customize.sh puts this file in the installer and lists it among the install's
phases, right after SSH access, when the ISO is built.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

HANDOVER = Path("/root/origaitv-handover")
EFIVARS = Path("/sys/firmware/efi/efivars")
# systemd's boot loader interface: its variables' vendor GUID, and the two a
# system sets for its next start only (the menu's timeout, and an entry).
LOADER_GUID = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
ONE_SHOT = ("LoaderConfigTimeoutOneShot", "LoaderEntryOneShot")


def hand_over(source: Path, target: Path) -> list[Path]:
    """Copies source's files onto target, as root's, keeping their modes.
    Returns the paths it wrote on target. Links are left out."""
    written: list[Path] = []
    if not source.is_dir():
        return written
    for path in sorted(source.rglob("*")):
        if path.is_symlink():
            continue
        destination = target / path.relative_to(source)
        if path.is_dir():
            destination.mkdir(mode=0o755, parents=True, exist_ok=True)
        elif path.is_file():
            destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            shutil.copy2(path, destination)
            if os.geteuid() == 0:
                os.chown(destination, 0, 0)
            written.append(destination)
    return written


def drop_one_shot_requests(efivars: Path = EFIVARS) -> list[str]:
    """Removes the boot loader requests for the next start only, which the
    disk's old system may have left in the firmware. Returns the names it
    removed. efivarfs makes each variable immutable, so that goes first."""
    dropped: list[str] = []
    for name in ONE_SHOT:
        path = efivars / f"{name}-{LOADER_GUID}"
        if not path.exists():
            continue
        subprocess.run(["chattr", "-i", str(path)], capture_output=True, check=False)
        try:
            path.unlink()
        except OSError:
            continue
        dropped.append(name)
    return dropped


def ask_for_no_countdown(efivars: Path = EFIVARS) -> bool:
    """Asks the boot loader to boot the next start straight away, with no
    second for a key to stop it in. The variable's attributes (non-volatile,
    boot and runtime), then "menu-disabled" in UTF-16 with its NUL, as the
    boot loader interface spells it. Written in one go, as efivarfs needs."""
    value = (0x7).to_bytes(4, "little") + "menu-disabled\0".encode("utf-16-le")
    try:
        with open(efivars / f"LoaderConfigTimeoutOneShot-{LOADER_GUID}", "wb", buffering=0) as out:
            out.write(value)
    except OSError:
        return False
    return True


def origaitv_handover(ctx) -> None:
    from .ui import info

    written = hand_over(HANDOVER, Path(ctx.target))
    for path in written:
        info(f"› OrigaiTV: /{path.relative_to(ctx.target)}")
    # Only for OrigaiTV's first screen, which always erases the whole disk.
    # Omarchy's own installer can install beside another system, whose
    # requests aren't ours to drop.
    if written:
        for name in drop_one_shot_requests():
            info(f"› OrigaiTV: dropped the old system's {name}, so the first start doesn't stop at the boot menu")
        if ask_for_no_countdown():
            info("› OrigaiTV: the first start boots with no countdown, so no key can stop it at the boot menu")
