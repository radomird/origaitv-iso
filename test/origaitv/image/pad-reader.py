#!/usr/bin/env python3
#
# What a game does with controllers, for the image checks: it counts the
# input devices udev marked as joysticks, and reads the one with the name
# it's given, as the person logged in on the screen. Each thing it sees is a
# line:
#   controllers <n>              how many there are, each time that changes
#   reading <device>             it opened the one it was asked for
#   key <code> <value> <time>    a button went down (1) or up (0)
#   abs <code> <value> <time>    an axis moved
#   gone <device>                the one it was reading went away
# The time is the kernel's own for the event.
#
#   pad-reader.py <name>
#
# Standard library only.

import glob
import os
import select
import struct
import sys
import time

EVENT = struct.Struct("llHHi")
EV_KEY, EV_ABS = 0x01, 0x03


def joysticks():
    """The devices udev marked as joysticks, each with its name."""
    found = {}
    for node in glob.glob("/sys/class/input/event*"):
        try:
            with open(f"{node}/device/name") as file:
                name = file.read().strip()
            with open(f"{node}/dev") as file:
                number = file.read().strip()
            with open(f"/run/udev/data/c{number}") as file:
                marked = "E:ID_INPUT_JOYSTICK=1" in file.read().splitlines()
        except OSError:
            continue
        if marked:
            found[f"/dev/input/{os.path.basename(node)}"] = name
    return found


def main(args):
    if len(args) != 1:
        print("usage: pad-reader.py <name>", file=sys.stderr)
        return 2
    wanted = args[0]
    count = None
    fd = None
    path = None
    while True:
        there = joysticks()
        if len(there) != count:
            count = len(there)
            print(f"controllers {count}", flush=True)
        if fd is None:
            for device, name in sorted(there.items()):
                if name != wanted:
                    continue
                try:
                    fd = os.open(device, os.O_RDONLY | os.O_NONBLOCK)
                except OSError as error:
                    print(f"can't read {device}: {error}", flush=True)
                    continue
                path = device
                print(f"reading {path}", flush=True)
                break
        if fd is None:
            time.sleep(0.2)
            continue
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            continue
        try:
            data = os.read(fd, EVENT.size * 64)
        except BlockingIOError:
            continue
        except OSError:
            data = b""
        if not data:
            print(f"gone {path}", flush=True)
            os.close(fd)
            fd = None
            continue
        for i in range(0, len(data) - EVENT.size + 1, EVENT.size):
            seconds, micros, kind, code, value = EVENT.unpack_from(data, i)
            if kind in (EV_KEY, EV_ABS):
                print(f"{'key' if kind == EV_KEY else 'abs'} {code} {value} {seconds}.{micros:06d}", flush=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
