"""OrigaiTV's step in Omarchy's install: what the first screen hands over.

OrigaiTV's first screen on the USB stick leaves files for the installed box in
/root/origaitv-handover, laid out the way they go on the box: the account's
marker, which says its password is one nobody knows yet. This copies them
onto the new system, owned by root. With nothing there (an autoinstall, or
Omarchy's own installer after Ctrl+C) it copies nothing. Either way, an ISO
built from a release tag writes which release it is onto the box.

customize.sh puts this file in the installer and lists it among the install's
phases, right after SSH access, when the ISO is built.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path

HANDOVER = Path("/root/origaitv-handover")

# The release this ISO is, like 1.0.0-rc4, when it was built from a release
# tag: the ISO workflow writes it before the build. The box keeps it in
# /etc/origaitv/release, with the build of OrigaiTV the ISO installed on the
# line under it, like 0.2.0.r1061.g91b63a2e0. Settings, System says the box
# runs that release while it runs that build, and once an update on edge
# moves it on, that it was installed from it. An ISO built from a branch has
# no release.
RELEASE = Path("/usr/share/origaitv-iso/release")
RELEASE_ON_BOX = Path("etc/origaitv/release")
# The installed package's settings, where its version is.
SETTINGS_ON_BOX = Path("usr/share/origaitv/settings")


def installed_build(target: Path) -> str:
    """The version of OrigaiTV on target, from its package's settings, or ""."""
    try:
        text = (target / SETTINGS_ON_BOX).read_text()
    except OSError:
        return ""
    for line in text.splitlines():
        if line.startswith("ORIGAITV_VERSION="):
            return line.split("=", 1)[1].strip().strip("\"'")
    return ""


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


def hand_over_release(source: Path, target: Path) -> Path | None:
    """Writes the ISO's release onto target, readable by everyone, when the
    ISO has one, with the build target has on the line under it. Returns
    the path it wrote, or None."""
    try:
        release = source.read_text().split("\n")[0].strip()
    except OSError:
        return None
    if not release:
        return None
    destination = target / RELEASE_ON_BOX
    destination.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    build = installed_build(target)
    destination.write_text(release + "\n" + (build + "\n" if build else ""))
    destination.chmod(0o644)
    if os.geteuid() == 0:
        os.chown(destination, 0, 0)
    return destination


def origaitv_handover(ctx) -> None:
    from .ui import info

    written = hand_over(HANDOVER, Path(ctx.target))
    release = hand_over_release(RELEASE, Path(ctx.target))
    if release is not None:
        written.append(release)
    for path in written:
        info(f"› OrigaiTV: /{path.relative_to(ctx.target)}")
