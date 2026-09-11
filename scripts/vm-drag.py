#!/usr/bin/env python3
"""Synthesise a pointer drag inside the guest, so a gesture can be tested.

Runs IN THE GUEST, as root, driven by scripts/vm-drag.sh. Not part of the
image -- it is copied in for the length of a test run.

  vm-drag.py <x> <y> <dy> [steps] [delay_ms]   negative dy is upward
  HOLD=<seconds>                               hold before releasing

The VM's own pointer is the `usb-tablet` QEMU forwards from the host, and
nothing in the guest can drive it. This creates a second, relative pointer
through /dev/uinput for the length of one gesture and destroys it again.

Relative rather than absolute: an absolute uinput device needs a full evdev
absinfo block and libinput would classify it as a tablet. The cost is that
libinput accelerates the motion, so vm-drag.sh sets `accel_profile flat`
first and the start position is corrected against `hyprctl cursorpos` --
open loop, one jump of 180 units lands at the far edge of the screen.
"""
import fcntl
import os
import struct
import subprocess
import sys
import time

UINPUT = "/dev/uinput"
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502
UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_RELBIT = 0x40045564, 0x40045565, 0x40045566
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
REL_X, REL_Y = 0, 1
BTN_LEFT = 0x110
SYN_REPORT = 0
SCREEN_H = 720

fd = os.open(UINPUT, os.O_WRONLY | os.O_NONBLOCK)
for ev in (EV_KEY, EV_REL, EV_SYN):
    fcntl.ioctl(fd, UI_SET_EVBIT, ev)
fcntl.ioctl(fd, UI_SET_KEYBIT, BTN_LEFT)
for rel in (REL_X, REL_Y):
    fcntl.ioctl(fd, UI_SET_RELBIT, rel)

name = b"omarchy-mobile-test-pointer".ljust(80, b"\0")
os.write(fd, name + struct.pack("HHHH", 3, 0x1234, 0x5678, 1)
         + struct.pack("i", 0) + b"\0" * (4 * 4 * 64))
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(1.0)   # let udev and libinput notice it


def emit(kind, code, value):
    os.write(fd, struct.pack("llHHi", 0, 0, kind, code, value)
             + struct.pack("llHHi", 0, 0, EV_SYN, SYN_REPORT, 0))


def cursorpos():
    out = subprocess.check_output(["hyprctl", "cursorpos"]).decode()
    x, y = out.strip().split(",")
    return int(x), int(y)


def move_to(tx, ty):
    """Walk to (tx, ty), correcting against where the cursor actually is."""
    emit(EV_REL, REL_X, -4000)
    emit(EV_REL, REL_Y, 4000)
    time.sleep(0.15)
    x, y = cursorpos()
    for _ in range(400):
        x, y = cursorpos()
        dx, dy = tx - x, ty - y
        if abs(dx) <= 1 and abs(dy) <= 1:
            return
        if dx:
            emit(EV_REL, REL_X, max(-6, min(6, dx)))
        if dy:
            emit(EV_REL, REL_Y, max(-6, min(6, dy)))
        time.sleep(0.008)
    raise SystemExit("could not reach %d,%d (stuck at %d,%d)" % (tx, ty, x, y))


startx, starty, dy = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
steps = int(sys.argv[4]) if len(sys.argv) > 4 else 30
delay = (int(sys.argv[5]) if len(sys.argv) > 5 else 12) / 1000.0
hold = float(os.environ.get("HOLD", "0"))
# Horizontal travel, for the sideways swipe (gestures.md B). An environment
# variable rather than a fourth positional so every existing call keeps its
# meaning.
dx = int(os.environ.get("DX", "0"))

move_to(startx, starty)
time.sleep(0.2)
emit(EV_KEY, BTN_LEFT, 1)
time.sleep(0.05)

# Open loop, at a steady cadence. Correcting against cursorpos mid-drag is what
# this used to do, and the correction's own jitter read as a downward fling on
# release -- a drag that should have opened the drawer sprang back instead.
per_y = dy / float(steps)
per_x = dx / float(steps)
travelled_y = travelled_x = 0
for i in range(steps):
    move_x = int(round(per_x * (i + 1))) - travelled_x
    move_y = int(round(per_y * (i + 1))) - travelled_y
    if move_x:
        emit(EV_REL, REL_X, move_x)
        travelled_x += move_x
    if move_y:
        emit(EV_REL, REL_Y, move_y)
        travelled_y += move_y
    time.sleep(delay)

time.sleep(0.05 + hold)
emit(EV_KEY, BTN_LEFT, 0)
time.sleep(0.15)
print("ended at %s (wanted %d,%d)" % (cursorpos(), startx + dx, starty + dy))

fcntl.ioctl(fd, UI_DEV_DESTROY)
os.close(fd)
