# Build log

The chronological account: every measurement, and every dead end. Written the
way moarchy's is, because the useful half of a port is the part that did not
work the first time.

---

## 2026-09-09 -- the premise, checked before building anything

moarchy exists because of two blockers on PinePhone hardware, both of which it
verified rather than assumed:

1. **Hyprland cannot run on a Mali-400.** Its renderer includes `<GLES3/gl32.h>`
   and aborts if it cannot get a GLES 3.x context. Lima on an Allwinner A64
   tops out at GLES 2.0, and Hyprland 0.50 removed the legacy GLES2 renderer.
2. **Omarchy's package repo is x86_64-only.** `pkgs.omarchy.org/stable/aarch64/`
   is a 404.

This project's premise is that a VM has neither problem. Before writing a line
of it, both halves were checked.

### Hyprland for aarch64 exists, prebuilt

```
$ docker run --rm --platform linux/arm64 menci/archlinuxarm@sha256:f7c6f64... \
    pacman -Si hyprland quickshell ...

hyprland                     0.56.1-3       extra
hyprlang                     0.6.8-5        extra
hyprutils                    0.14.2-1       extra
hyprcursor                   0.1.13-7       extra
hyprgraphics                 0.5.1-4        extra
aquamarine                   0.15.0-2       extra
hyprwayland-scanner          0.4.6-1        extra
xdg-desktop-portal-hyprland  1.4.1-2        extra
quickshell                   0.3.1-1        extra
mesa                         1:26.2.2-1     extra
vulkan-swrast                1:26.2.2-1     extra
uwsm                         0.26.7-1       extra
```

Arch Linux ARM rebuilds Arch's `extra` for aarch64, and the whole Hyprland
stack is in it. **Nothing about Hyprland needs cross-compiling.** That was the
single biggest unknown in the project and it cost one `pacman -Si` to settle.

The GLES floor is cleared by Mesa's llvmpipe, which advertises GLES 3.2 in
software. So the port's central patch -- moarchy's 264-line
`port-4x.patch` turning `Quickshell.Hyprland` into `Quickshell.I3` -- is not
needed here at all. Upstream Omarchy is vendored unpatched.

### 120 of Omarchy's 147 base packages exist for aarch64

`install/omarchy-base.packages` at the pinned commit lists 147. Checked one by
one with `pacman -Si` in an aarch64 container:

```
available: 120 / missing: 27
```

The 27 are in `vm/packages/omitted`, each with a reason. They break down as ten
packages from Basecamp's own x86_64-only repo (`aether`, `herdr`, `omacalc`,
`omacut`, `omawrite`, `omarchy-nvim`, `ttfx`, `tensaku`, `tobi-try`, `cliamp`),
six AUR packages that moarchy already builds for aarch64, five x86-only
upstreams, and six that a VM has no use for.

One correction to moarchy's own notes falls out of this: it dropped Omarchy's
OCR capture on the grounds that `tesseract` "has no aarch64 build". It has one
now -- `tesseract 5.x` and `tesseract-data-eng` are both in `extra` -- so this
port keeps OCR.

`herdr` deserves its own line because moarchy's history turns on it: an earlier
port read Omarchy 4.0.0's move to herdr as a move to a closed-source x86_64
shell, and that reading was wrong twice over. herdr is neither the shell (that
is quickshell) nor closed source. It is omitted here only because it is
packaged for x86_64 alone.

### What Omarchy 4.x actually starts

Worth writing down, because it decides what the image has to arrange:

- Hyprland is configured in **Lua**, not `hyprland.conf`:
  `~/.config/hypr/hyprland.lua` sources `/usr/share/omarchy/default/hypr/*.lua`.
- `default/hypr/autostart.lua` runs `omarchy-launch-shell` on `hyprland.start`,
  which is what brings up the quickshell bar/launcher/notifications/OSD.
- New users get their `~/.config` from **`/etc/skel`**, populated from the
  source tree's `config/`. `omarchy-provision-user`'s own help text is the
  authority on this.
- Upstream enables **sddm**, with
  `CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua`.

This image does not use sddm. A phone shows no login screen, and on a
software-rendered VM a display manager is one more graphical thing that can
fail before Hyprland gets a chance to. tty1 autologin into
`uwsm start -- hyprland-uwsm.desktop` replaces it -- `uwsm` because Omarchy's
own autostart imports the environment into the systemd user manager and
launches every app through `uwsm-app`, so a bare `Hyprland` would leave those
app scopes unparented.

### Host

Apple M2 Pro, 16 GB, macOS 25.6. QEMU 11.1.1 from Homebrew;
`edk2-aarch64-code.fd` ships with it at 64 MiB, which is the size the pflash
pairing requires. Docker Desktop 28.3.0 runs `linux/arm64` containers natively,
so every package in the image is built and installed at full speed with nothing
emulated anywhere.

---

## 2026-09-09 -- first boot

It works. Omarchy 4.0.3's quickshell shell, on Hyprland 0.56.2, on aarch64, at
720x1440:

![first boot](screenshots/first-boot-720x1440.png)

```
$ ./scripts/vm-ssh.sh 'pgrep -a Hyprland; pgrep -a quickshell'
470 Hyprland --watchdog-fd 4
522 quickshell -n -p /usr/share/omarchy/shell

$ ./scripts/vm-ssh.sh hyprctl version
Hyprland 0.56.2 built from branch v0.56.2 at commit efb5099378 clean

$ ./scripts/vm-ssh.sh hyprctl monitors
Monitor Virtual-1 (ID 0):
        720x1440@74.99900 at 0x0
        reserved: 0 26 0 0
        scale: 1
```

`reserved: 0 26 0 0` is the shell's bar claiming its exclusive zone, which is
the cheapest possible proof that the QML shell is not merely running but
talking to the compositor. And it is talking to it through
`Quickshell.Hyprland` — the import moarchy has to rewrite — with no patch
applied.

The window in the second screenshot has a teal focus border, gaps and rounded
corners: three of the things moarchy's README lists under "Gone, because they
are Hyprland renderer features that a GLES 2.0 device could never have driven".

### Five failures on the way there, four of them one bug

Worth writing down together, because four of the five had the same cause
wearing four different disguises, and each one read as a defect somewhere else
entirely.

**1. `pacstrap` refused the transaction.**

```
:: unable to satisfy dependency 'libaquamarine.so=13-64' required by hyprland
```

Arch Linux ARM is one rebuild behind. Fixed by building hyprland 0.56.2-2 for
aarch64 from Arch's packaging repo — see `[pkg.hyprland]` in `manifest.toml`.

**2. `arch-chroot` could not find a file that was plainly there.**

```
chroot: failed to run command '/tmp/configure.sh': No such file or directory
```

`arch-chroot` mounts a fresh tmpfs over the target's `/tmp` before it chroots,
so anything staged there is hidden by the time it runs. Staged in `/root`
instead.

**3, 4, 5. Docker Desktop's VirtioFS silently discards atomic writes.**

Three separate failures, one cause. First pacman, on a file it had just
written:

```
error: could not rename /var/cache/pacman/pkg/libxau-1.0.12-1-aarch64.pkg.tar.xz.part
       to /var/cache/pacman/pkg/libxau-1.0.12-1-aarch64.pkg.tar.xz (No such file or directory)
```

Then `useradd`, reporting that every base group was missing. Then
`systemd-sysusers`, which is what creates those groups — and which printed
that it had created them:

```
Creating group 'wheel' with GID 998.
Creating group 'audio' with GID 995.
```

while `/etc/group` still contained exactly one line. Reduced to a test that
isolates it:

```
$ systemd-sysusers --root=/out/t          # /out is a host bind mount
Creating group 'wheel' with GID 999.
Failed to flush /out/t/etc/.#group5b567ce2a2a0917e: No such file or directory
$ cat /out/t/etc/group
root:x:0:root

$ systemd-sysusers --root=/tmp/t          # container-internal
Creating group 'wheel' with GID 999.
$ cat /tmp/t/etc/group
root:x:0:root
wheel:x:999:
```

**A rootfs cannot be built on a Docker Desktop bind mount at all.** The
write-to-temp-then-rename pattern that every careful program uses loses the
file, usually without an error. The build now assembles the rootfs in a Docker
named volume and copies only the finished image out to `/out`; the pacman cache
and the package output are named volumes for the same reason.

The lesson generalises past this project: on Docker Desktop for macOS, a bind
mount is fine for *reading* a repo and for *writing* one finished artifact, and
is not a filesystem you can install an operating system onto.

### `--headless` meant the wrong thing

The first design gave the guest no display device at all, on the reasoning that
Hyprland would fall back to aquamarine's headless backend. It does — but the
guest then has no `/dev/dri` **and no tty1**, and the session is started by
tty1 autologin:

```
$ systemctl status getty@tty1.service
     Active: failed (Result: start-limit-hit)
    Process: 789 ExecStart=/sbin/agetty --autologin omarchy --noclear tty1 $TERM
```

agetty exits immediately on a VT that does not exist, five times, and systemd
gives up. `--headless` now keeps the virtio-gpu and withholds only the window
on the Mac, so the guest is byte-for-byte the same in both modes and the panel
geometry stays a host-side flag.

### The UEFI variables outlived the hardware

Adding the virtio-gpu shifted the PCI topology, and the persisted edk2 NVRAM
still held a boot order naming the old one:

```
>>Start PXE over IPv4.
  PXE-E16: No valid offer received.
BdsDxe: failed to load Boot0002 "UEFI PXEv4 (MAC:525400123456)" ... Not Found
```

Deleting `vm/out/edk2-vars-*.fd` fixes it. Nothing in this image depends on
NVRAM state — systemd-boot is installed at the removable-media path
(`/EFI/BOOT/BOOTAA64.EFI`) which the firmware finds by enumeration — so the
vars file is safe to delete whenever the device set changes.

### `hyprctl keyword` is gone in 0.56

Omarchy 4.x configures Hyprland in Lua, and 0.56 wires `hyprctl` to the same
parser:

```
$ hyprctl keyword monitor "Virtual-1,720x1440@75,0x0,2"
keyword can't work with non-legacy parsers. Use eval.

$ hyprctl eval 'hl.monitor({output="Virtual-1", mode="720x1440@75", position="0x0", scale=2})'
ok
```

Anything in this project that pokes the running compositor has to go through
`hyprctl eval` and the `hl.*` API, not the string-keyword syntax that most
Hyprland documentation still shows.

### What scale 1 looks like, and why the manifest now sets 2

Upstream ships `scale = "auto"`, which on this panel resolves to 1: a 26-pixel
bar on a 1440-pixel-tall screen, and a UI that is desktop-sized on a screen the
shape of a phone. moarchy measured the original PinePhone at 720x1440 with
`scale 2` -> 360x720 logical, and that is what `[vm] scale` now generates into
`~/.config/hypr/monitors.lua`:

![scale 2](screenshots/scale2-360x720.png)

That file is one upstream already ships as a user override and loads after its
own defaults (`require("hypr.monitors")`), so the geometry changes with nothing
patched. It is the same move moarchy makes with its Sway theme template — add a
file to a directory the upstream engine already reads — and it is the mechanism
the rest of the mobile overlay should be built on.
