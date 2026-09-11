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

---

## 2026-09-09 -- the full package set, and Docker's disk

`--session-only` is 546 packages. The full set is **853**, and building it hit
the one remaining resource limit:

```
==> assemble
dd: error writing '/work/omarchy-mobile-0.1.0.img': No space left on device
```

Docker Desktop's VM disk is 59 GB. The build was holding three copies of the
same bytes at once — the rootfs (8.8 GB), a full-size `root.img` (8.6 GB) and
the disk image being assembled from it (15 GB apparent). Fixed by writing the
root filesystem straight into the disk image at the partition's byte offset:

```bash
mkfs.ext4 -q -F -b 4096 -E offset=$(( ROOT_LBA * SECTOR )) \
  -L omarchy-root -d "$ROOTDIR" "$IMG" $(( ROOT_MIB * 1024 * 1024 / 4096 ))
rm -rf "$ROOTDIR"
```

`-E offset=` removes one copy and deleting the rootfs immediately afterwards
removes the other, so the peak is one rootfs plus one sparse image. The
explicit block count matters: without a size argument mke2fs takes the whole
file and the offset stops meaning anything. The package manifest
(`arch-chroot pacman -Q`) moved earlier in the script for the same reason —
anything that has to read the rootfs now has to read it before it is deleted.

### Verified end to end

```
$ cat /etc/omarchy-mobile/release
VERSION=0.1.0
COMMIT=716aeb55c2f302d7f956b6c23a79455df043efc1

$ hyprctl monitors
        720x1440@74.99900 at 0x0
        reserved: 0 26 0 0
        scale: 2

$ hyprctl layers
        namespace: omarchy-background,    xywh: 0 0 360 720
        namespace: omarchy-bar,           xywh: 0 0 360 26
        namespace: omarchy-notifications, xywh: 0 0 360 720
        namespace: omarchy-menu,          xywh: 0 0 360 720

$ pacman -Q | wc -l
853
```

Four layer surfaces, all at 360x720 logical, all from one pid — the quickshell
shell. The background, the bar, the notification stack and `omarchy-menu` are
each a layer surface rather than a window, which is why `hyprctl clients`
reports "no open windows" while the menu is plainly on screen. Worth knowing
before phase 2 starts adding layer surfaces of its own.

### `known_hosts` is /dev/null now

The guest's host key is regenerated on every image build and the address is
always `127.0.0.1` on a forwarded port, so a `known_hosts` entry is stale by
the next build and says so in the loudest possible terms:

```
Offending ED25519 key in vm/out/known_hosts:1
Password authentication is disabled to avoid man-in-the-middle attacks.
```

There is nothing for it to protect — the port is bound to loopback by the QEMU
this repo started, and the key belongs to an image this repo built minutes ago.
What it *does* protect is `~/.ssh/known_hosts`, which never gets an entry for a
`127.0.0.1` that will mean something different tomorrow.

---

## 2026-09-09 -- the app drawer, and two things Hyprland does not do

Phase 2's first surface: a band at the bottom edge that drags a full-screen app
grid up behind the finger. It ships as a plugin, `mobile.drawer`, in
`default/etc/skel/.config/omarchy/plugins/`.

### Where a plugin lives, and why not where moarchy puts it

moarchy installs its nine plugins to `/usr/share/moarchy/plugins`, which needs a
patch: upstream's `PluginRegistry` scans `$OMARCHY_PATH/shell/plugins` and
`~/.config/omarchy/plugins` and nowhere else, so `port-4x.patch` adds a
`systemPluginsDir` and a third `scan_thirdparty` call.

That is the right shape for a package that is upgraded independently of the
image. It is the wrong shape here, where the plugin ships *in* the image and the
user directory is seeded from `/etc/skel` anyway. So this uses the directory
upstream already scans, and the patch is not needed. It also buys something
moarchy has to work for: saving a file under `~/.config/omarchy/plugins`
hot-reloads the plugin, so iterating on the drawer is `scp` and nothing else.

Enabling is one jq call in `configure.sh` — a third-party plugin is on exactly
when its id appears in `shell.json` — and the id list is derived from the
directories that shipped rather than written out, so the second plugin is a
directory and not also an edit somewhere else.

### One plugin, not two, because 4.0.3 sandboxes them

moarchy splits the gesture from the drawer: `moarchy.gestures` owns every edge
and drives `moarchy.drawer` through the shell. That needs the trusted host
object, and 4.0.3 does not hand it to an installed plugin — `pluginShellFor()`
returns a facade whose `summon`/`hide` accept only the plugin's own id, with no
`panelLoaders` and no `callIfLoaded` at all. moarchy patches `shell.qml` to
trust its own namespace; this project would rather not, so the edge and the
sheet are one plugin and talk to each other directly.

### `kind: "menu"`, and the bug behind it

The manifest declares `"menu"` rather than `"panel"`, because that is the kind
that gets an application library: `pluginAppLibraryFor()` is handed to a plugin
whose manifest declares `menu` and to no other. Writing the app list without it
would mean re-implementing desktop-entry enumeration and the icon-theme fallback
index, and getting the second wrong is a grid of blank squares.

It did not work. `state` reported `apps=0` with no warning anywhere, and the
facade came through as `appLibrary: null` while the sibling `bar` facade on the
same `createObject` call arrived fine. A probe in the host said why:

```
PROBE omarchy.monitor  isArray= true   kinds= ["bar-widget"]  hasMenu= false
PROBE mobile.drawer    isArray= false  kinds= ["menu"]        hasMenu= false
```

The manifest reaches `pluginShellFor()` as an `Instantiator` model entry, which
round-trips through `QVariant`; a `QVariantList` returns to JavaScript as a
sequence wrapper, and `Array.isArray` on one is false. `manifestHasKind()` guards
on exactly that. `JSON.stringify` still prints `["menu"]`, which is why the
manifest injected into the plugin looked perfectly normal.

`patches/plugin-manifest-kinds.patch` reads the live manifest out of the registry
instead of the model's copy. One line, and every other consumer of that object is
repaired with it.

### Hyprland does not hold the implicit pointer grab across a layer surface

This is the one that cost a rewrite. Wayland says a press latches the pointer to
the surface it landed on and that motion keeps arriving there however far it
travels; moarchy's gesture strip is 20px tall and tracks a full-height swipe on
Sway because of it. Hyprland stops at the surface edge, to the pixel:

```
press at surface-local y=19, drag up 58px   ->  last motion at dy = -18
press at surface-local y=13, drag up 300px  ->  last motion at dy = -10
```

The button release still arrives, so the gesture ends having seen 18px of a
300px drag — which reads as a tap every time, and the drawer sprang back on a
swipe that had crossed the whole screen.

So the surface that owns a gesture has to be as large as the gesture. It cannot
be a permanently full-screen input region, which would eat every touch meant for
an app, so the region grows for the length of the drag: the bottom band at rest,
the whole surface from press to release. A `mask` does that without a resize, so
no configure round trip and the exclusive zone never moves. `dragWatchdog` puts
it back if a release never comes, because a stuck mask is a screen that answers
nothing.

The strip that draws the pill and reserves the band is now input-transparent
(`mask: Region {}`) and the drawer surface underneath owns the gesture, because
the drawer is the one that can grow.

### A layer surface with exclusive keyboard focus takes every pointer event

Every full-screen overlay in the Omarchy shell asks for
`WlrKeyboardFocus.Exclusive`, and so does moarchy's drawer. Under it, a press on
the bottom edge while the drawer was open produced no press, no release and no
log line at all — the edge was deaf for as long as the sheet was mapped. Under
`OnDemand` the same press arrives and the swipe dismisses.

It is not a cosmetic choice: the carousel, the shade and the back swipe all live
on edges, and Exclusive would make every one of them deaf whenever the drawer is
open. What it costs is that Qt's focus stays on the sheet rather than the search
field until the field is tapped — which on a phone is wanted anyway, since
opening the drawer should not raise the on-screen keyboard.

Keyboard focus is keyed on the settled state rather than on `progress`, so it
never changes mid-gesture: a focus change moves the pointer focus with it, and
that cancels the drag being delivered.

### A Region's own properties do not re-apply the mask

Written the obvious way — one `Region` whose `y`/`height` are bound to a
`inputFull` flag — the surface kept the region it measured when it was first
attached. The band worked, because the band is the state it was created in, and
nothing else on the sheet answered a press: the drawer could be dragged up and
then its handle could not be pressed.

Two `Region` objects, swapped by assigning `mask`, re-apply.

### `Date.now()` is not a good enough clock for a fling

The velocity term is moarchy's, smoothed over `dt = max(1, now - lastT)`. On a
compositor handing on a pointer stream, two motion events land in the same
millisecond often enough that the clamp turns a 3px step into 3 px/ms — five
times the fling threshold — off a finger that has barely moved. Measured: a 41px
drag over 120ms reported **2.98 px/ms** and opened the drawer on what should have
been a spring-back.

Speed is now sampled at most once per 8ms, over real elapsed time. A phone
touchscreen samples at 60-120Hz and would never have shown this.

### Testing a gesture with no hands

The guest's pointer is the `usb-tablet` QEMU forwards from the host, and nothing
in the guest can drive it. `scripts/vm-drag.sh` creates a second, relative
pointer through `/dev/uinput` for the length of one gesture and destroys it
afterwards; the drawer answers `omarchy-shell shell call mobile.drawer state ""`
with one line, so each criterion is checkable from a terminal:

```
A  edge up 40px  (<35%)     closed progress=0 apps=13
B  edge up 300px (>35%)     open progress=100 apps=13
C  edge up while open       closed progress=0 apps=13
D  handle down 400px        closed progress=0 apps=13
E  handle down 60px         open progress=100 apps=13
F  grid drag down 400px     closed progress=0 apps=13
G  tap the field, "libre"   open progress=100 apps=3
H  Escape clears the query  open progress=100 apps=13
I  Escape again closes      closed progress=0 apps=13
J  tap Foot                 closed, and `hyprctl clients` has a foot window
K  edge up over an app      open progress=100 apps=13
```

G is where the keyboard focus decision shows up. Escape does nothing on a
freshly opened drawer and works from the first tap on the sheet onwards, because
OnDemand means the compositor hands focus over on a CLICK and this surface is
mapped from startup -- opening the drawer is not an event it acts on. On a phone
that is nearly the wanted behaviour anyway (no Escape key, and the drawer must
not raise the on-screen keyboard); on a VM with a real keyboard it is the price
of keeping the edge alive.

Two things the harness taught about itself, both of which looked like product
bugs first. Correcting the pointer against `hyprctl cursorpos` *during* the drag
makes the correction's own jitter read as a downward fling on release, so the
drag is open loop with `accel_profile flat` set first — one relative unit, one
logical pixel. And a single relative jump of 180 units lands at the far edge of
the screen rather than the middle, because libinput accelerates it; the start
position is walked to in small steps instead.

Repeatedly rewriting the plugin file in place also segfaulted quickshell three
times, in `QQmlComponent::createObject` under "Local plugin changed, reloading".
Writing to a temp file and renaming stopped it: the inotify watcher was reading
a file that was still being written. Not a shipping concern -- the file changes
once, at build time -- but worth knowing before iterating on device.

---

## 2026-09-10 -- a sweep for the rest of the notification bug

`notification-card-max-width.patch` was found by looking at one surface. The
question this session asks is how many others are wrong the same way, so every
surface the shell can put on screen got opened over IPC and captured with
`grim`:

```
for t in omarchy.power omarchy.monitor omarchy.bluetooth omarchy.network \
         omarchy.agents omarchy.clock omarchy.weather omarchy.audio; do
  omarchy-shell $t open; sleep 2; ./scripts/vm-screenshot.sh shots/$t.png
  omarchy-shell $t close
done
```

plus the menu, the emoji and clipboard pickers, the OSD, the notification
history, the lock preview, the background switcher and the keybindings
cheatsheet. Five surfaces are wrong at 360 logical, and screenshots only say
*that* they are wrong, not by how much — so the guest's copy of the shell got
temporary probes, the same trick that found the manifest bug:

```qml
Timer { running: true; interval: 1500; repeat: true; onTriggered:
  console.log("PROBE weather-hero avail=" + heroProbe.width + ...) }
```

`console.log` from the shell lands in the compositor's own unit, which is where
to look for it:

```
journalctl --user -u 'wayland-wm@hyprland\x2duwsm.desktop.service'
```

The five, measured:

```
PROBE lock-field         screen=360 fieldW=381 x=-11 right=370
PROBE weather-hero       avail=318 leftEnd=185.36 rightX=99.72 overlap=85.64
PROBE weather-forecast   avail=318 rowW=329.3 rowX=-6 cut=11.3
PROBE bar                width=360 leftEnd=140.5 rightStart=271 freeMiddle=130.5
PROBE bar-center         anchorX=121 anchorW=118.125
PROBE clock-calendar     viewport=318 content=426 grid=426 flickable=true
```

Two are the notification bug exactly — a fixed desktop width on a surface
narrower than it — and both are patched: `lock-field-max-width.patch` and
`weather-forecast-fit.patch`, described in the README.

Two are a different fault, and are not patched. The weather hero and the bar
both anchor one child to the left edge and another to the right and never ask
whether the two fit; the hero overlaps by 85px and the bar's centred clock
starts 19.5px inside the workspace list. Neither can be fixed by clamping,
because in both cases the content genuinely does not fit — they need to reflow
or to give something up, which is a design decision rather than a robustness
fix.

The fifth is not a defect. The calendar grid is 426 wide in a 318 viewport, but
`flickable=true` and upstream's own comment says the grid is meant to scroll
rather than shrink. It is merely a poor thing to do with a thumb, inside a panel
that also scrolls vertically.

### The A/B at desktop width, and why the first one lied

The notification patch was held to "measured in the VM at both ends", so these
were too. The first attempt to widen the screen produced two identical
screenshots and a conclusion that was nonsense, because

```
$ hyprctl keyword monitor Virtual-1,1920x1080@60,0x0,1
keyword can't work with non-legacy parsers. Use eval.
```

prints its complaint on stdout and exits **0**. Redirected into `/dev/null` next
to the rest of the setup, a silent no-op looks exactly like a successful mode
change. `hyprctl eval` and `hl.monitor({...})` is the working form, already
noted above; it needs to be checked with `hyprctl monitors`, not assumed.

With the mode actually changed, upstream and patched captures at 1920×1080
differ by at most **2/255 on 33 of 32,219 pixels** in the weather hero, and by
the same margin over a 24×4 patch of the lock screen's mouse cursor. That is
llvmpipe's anti-aliasing between two renders, not a layout change — which is
what both patches predict, since `Math.min` returns the upstream value on every
screen wide enough to hold it.

### The hero after all, and a binding loop on the way

The hero overlap was left unpatched above as a design call. The PR's "after"
image settled it — the popup still overlapped as badly as the "before" did,
and a fix nobody can see in its own screenshot is not a fix anyone will take —
so it joins the forecast in one patch, now `weather-panel-fit.patch`.

The first version bound the anchors to conditionals, the pattern `Button.qml`
uses:

```qml
anchors.left: hero.stacked ? undefined : parent.left
anchors.horizontalCenter: hero.stacked ? parent.horizontalCenter : undefined
```

It looked right at 360 and was wrong at 1920, where the hero's halves piled up
at the left edge. The journal said why:

```
Binding loop detected for property "stacked"
Binding loop detected for property "height"
```

`stacked` flips on every open, because the popup's width starts at 0. The anchor
bindings that depend on it re-evaluate in no fixed order, so for a moment the
row can hold both `left` and `horizontalCenter`, and Qt reads that pair as a
stretch: it sizes the row to twice the distance between them. The row's width
feeds `stacked`, which is the loop, and QML breaks it wherever the values happen
to stand. `Button.qml`'s condition does not depend on the button's own width, so
there it has nothing to feed back into.

`State` plus `AnchorChanges` is Qt's answer — it clears the old anchors before it
sets the new ones — and it leaves the default state as upstream's own anchor
lines. With it, a fresh start and a live switch in either direction land in the
same place, within 3/255 on at most 49 pixels, and the journal is clean.

One capture pass on the way was worthless, and it is worth saying how: the
Bash tool's shell is zsh, which does not word-split an unquoted `$SSHO`, so
`scp $SSHO file host:` failed, the upstream file never reached the guest, and
the "upstream" captures were of the patched code. The helper scripts are bash
with an array now.

### Smaller, in the end

The `State` version worked and was 26 lines, which is a lot to ask a reviewer
to read for a popup that only misbehaves on a small screen. The forecast fix
already had the idiom — lay the row out at the size it wants and scale it to
the room it gets — and the hero takes the same thing in four lines: its width
becomes `max(parent.width, what the halves need)` and it scales from its left
edge. The PR drops to +6 −1.

The trade is that at 360 logical the hero renders at about 76% instead of
stacking at full size. What it buys is that the desktop layout keeps its shape
on a phone, the popup does not grow taller, and there is nothing to loop on:
the width it reads is the halves' own, not anything positioned.

Re-verified the same way: 38 pixels at 3/255 against upstream at 1920×1080,
live switches landing where fresh starts do, and a clean journal.

### A patch that carried half of upstream with it

The lock fix is branched from today's `quattro` for the PR, and
`patches/lock-field-max-width.patch` was then regenerated by diffing the pinned
v4.0.3 file against the fork's copy. But `LockView.qml` has moved on `quattro`
since v4.0.3 — video wallpapers arrived, through a new `BackgroundMedia` — so
that diff was the one-line fix *plus* three hunks of upstream's wallpaper work.

It applied cleanly, because it was a perfectly valid diff from v4.0.3. The VM
is what caught it: the lock plugin stopped loading altogether,

```
LockView.qml:90:5: BackgroundMedia is not a type
service plugin load failed for omarchy.lock: ... Type LockView unavailable
```

and with it went the `lock` IPC target, which is to say the lock screen. A
build from that patch would have shipped exactly that.

`--fuzz=0` guarantees a patch lands where it was aimed; it says nothing about
what the patch contains. So the rule this leaves behind: `patches/` are
generated from the pinned tree plus the change, never from a file that came
from `quattro`, and a patch's hunk count gets looked at, not just its exit code.
The weather patch was not affected — `Panel.qml` is identical on both — but it
was checked again for the same reason.

---

## 2026-09-11 -- moarchy's criteria, and the carousel

moarchy's UI specs are now this project's: `docs/spec/` holds `gestures.md`,
`shade.md`, `windows.md`, `style.md` and `settings.md` copied at `d0e5dd2` with
every id and every line unchanged, and `docs/acceptance.md` is the ledger of
which ones hold here. Copied rather than rewritten, so an id means the same
thing in both projects, and so the places where Hyprland changes the answer are
written down as changes rather than silently absorbed.

The first slice is gestures.md A to F plus windows.md W1-W5: the strip, the
carousel, going home, the home screen, and the drawer moved off the edge.
`scripts/vm-selftest.sh` checks 38 of them and all 38 pass.

### One plugin, `mobile.shell`

`mobile.drawer` became `mobile.shell`, with the edge, the carousel and the
drawer as three files under one entry point. The reasons are the 4.0.3 sandbox
(a plugin can drive only its own id) and the two Hyprland input findings from
the drawer, and they arrive at the same layout from opposite ends: one surface
owns the edges and writes every sheet's `progress` directly.

The edge is its own full-screen Overlay surface now, rather than the drawer's
input region. That is what lets the strip work over both sheets (A6, A7): the
drawer and the carousel are Top, and every Overlay surface is above every Top
one. The drawer takes no input while the home screen drags it up, for the grab
reason -- a region opening under the finger would take the rest of the drag.

### Dispatching under Lua

```
$ hyprctl dispatch workspace 3
error: [string "return hl.dispatch(workspace 3)"]:1: ')' expected near '3'
```

0.56 wraps a dispatch request in `return hl.dispatch(...)`, so the request has
to be an `hl.dsp` expression. That also works through Quickshell's socket:
`Hyprland.dispatch('hl.dsp.focus({ workspace = "e+1" })')` from QML switches
workspace, measured, and nothing forks.

### One app per workspace is a window rule

moarchy needs `bin/moarchy-one-app-per-workspace`, a Python loop on Sway's IPC.
Hyprland's rule engine does it at map time:

```lua
hl.window_rule({ match = { class = ".*", float = false }, workspace = "empty" })
```

Three foots opened from one workspace landed on 1, 2 and 3, with focus following
the last. And `empty` is moarchy's F1 rule exactly: with windows on 1 and 3,
`focus({ workspace = "empty" })` from 3 went to 2, the hole. The home gesture
dispatches the same word, so the "two implementations that drifted" defect
moarchy's F1 records has nothing to drift between.

W1 in numbers: upstream's `gaps_out = 10` and `border_size = 2` left a lone foot
at `[12,38] 336x650` inside a `360x674` usable area. With `hypr/mobile.lua` it
is `[0,26] 360x674` exactly. The border rule is `match = { workspace = "w[tv1]" }`,
so it comes back on a split workspace (W3). `hyprland.lua` gets
`require("hypr.mobile")` appended by `configure.sh` -- the file's own last
comment is where it says personal configuration goes.

### `Toplevel.activate()` works here

moarchy's E2 comment records the foreign-toplevel activate request doing nothing
on Sway, silently, for as long as the carousel existed. On Hyprland it switches
to the window's workspace and focuses it (`misc:focus_on_activate` is on
upstream), so tapping a card is `activate()` and nothing else.

### Two QML traps

The edge component was first called `Edges.qml`. Quickshell exports an
uncreatable `Edges` enum, and an explicit import outranks a file in the plugin's
own directory, so the whole plugin failed with

```
Shell.qml[181:3]: Element is not creatable.
```

and what stayed on screen was the *old* `mobile.drawer`, which the push had not
removed -- a working drawer on screen, from the wrong plugin. It is
`EdgeGestures.qml` now.

The carousel card's press veil read `parent.color.a` inside a `Behavior`. A
Behavior is not an Item, `parent` there does not reach the Rectangle, and it
threw `Cannot read property 'a' of undefined` once per card.

### A toast is not a test fixture

The first full selftest run was 37 of 38: H6, dragging the drawer's handle,
failed. Probing by start position found a clean line -- drags from y ≤ 160
never reached the drawer, from y ≥ 200 they closed it -- which looked like an
input-region bug in upstream's notification surface. It was not. That surface
is `visible: popupModel.count > 0`, and a screenshot showed why it was mapped:
upstream's two first-run toasts, "Update System" and "Learn Keybindings", which
do not time out and sit on Overlay from y 26 to about 174.

So H6 was test isolation, and `reset_session` now calls
`omarchy-shell notifications dismissAll`. But it is a real phone finding too:
until those toasts are dismissed, the top of every sheet is dead to touch. That
is the shade's job (S18, S19) and is recorded in `docs/acceptance.md`.

### Iterating without a rebuild

`scripts/vm-push.sh` copies the overlay into the running guest's home, does what
`configure.sh` does at build time, reloads Hyprland and restarts the shell. A
restart rather than the shell's own hot reload, which segfaulted three times
while a file was mid-write (above), and a plugin that is four files is four
windows for that race.

---

## 2026-09-11 -- the bar, the shade, and two screens that are windows

shade.md next, and it needed two decisions before any code. How the shade shares
the top edge with upstream's bar -- Wayland cannot hand a tap on to the surface
underneath, so whatever owns the pull-down loses the bar's taps -- was settled as
*replace the bar*, moarchy's route. And the screens behind the shade's gear,
power button and long presses were settled as *port moarchy's*: Wi-Fi and
Bluetooth now, Settings later.

### The bar kind is a bigger grant than it looks

Replacing the bar is sanctioned: shell.json's `bar.id` picks any plugin that
declares kind `bar`. Reading how the host treats one turned up three things:

- `PluginRegistry.isEnabled` answers for a bar-kind plugin from `bar.id` alone,
  ignoring the plugins list -- for every entry point the plugin has.
- `barPluginMayControl` lets a bar-kind plugin summon and hide any plugin with a
  UI kind. `omarchy.menu` is one, so the gear can open it.
- `firstPartyServiceFor` hands a bar-kind plugin proxies for the notifications
  and media services -- Do Not Disturb and the active player, which the shade
  needs and a sandboxed plugin cannot reach.

So `mobile.shell` declares `["menu", "bar"]` with Bar.qml as the second entry
point, and gets all three with no patch. The first bullet is also a feature:
`bar.id` is now the switch between the phone UI and stock desktop Omarchy.

The proxy has no `clearPopups` or `clearHistory`, so Clear all and absorbing
toasts on open go through the service's public IPC: `notifications dismissAll`,
which archives the toasts into the history, then `notifications clear`, in one
process, because two could clear the history before the archive landed in it.

### A8, three designs later

The shade is a full-screen Overlay surface, always mapped, whose input region
grows: the bar's band at rest, everything from the press on -- the edge
surface's pattern, for the grab reason. moarchy's answer to A8 is a third
state: open, with the home pill's band cut out, so an up-swipe from the pill
falls through to the strip. It failed, twice over:

- The press reached nothing at all after an open, by IPC or by drag. Polled
  through a held drag, the edge surface never saw it and neither did the shade.
  After two taps on a tile it did reach the edge -- so the cut-out region,
  applied as the open animation ended, stayed uncommitted until something
  repainted.
- Once it reached the edge, the drag still stopped dead. It has to travel up
  over the shade, and Hyprland hands a drag to whichever surface is topmost under
  the finger: the grab finding again, from the other side.

The one that works: the shade keeps the band and forwards the gesture to
EdgeGestures' own functions, with a `borrowed` flag so the edge surface does not
open its own region and take the drag back. B3 comes with it -- a sideways swipe
with the shade down is the strip's sideways swipe.

Probing it took two tries of its own. A fixed sleep before reading "mid-hold"
state read it before vm-drag.sh had pressed at all -- `hyprctl cursorpos` still
showed the start position. Polling inside the guest every 200ms while the drag
ran is what finally showed who got the press.

### H2 cancelled by its own sheet

A close drag on the scrim delivered eleven samples and left the shade open. The
drag took progress to 0, the scrim and the sheet are `visible: progress > 0`,
and Qt cancels the grab of a MouseArea whose item disappears under it --
`sheetCancel` put the sheet back up. Both stay visible for the length of a drag
now.

### Glyphs lost in transit, by range

The gear and power buttons drew as empty circles. Every other glyph in the file
rendered. The two that vanished are U+E615 and U+F011, in the Basic
Multilingual Plane's private-use area; the ones that survived are all U+F0xxx,
in plane 15. Whatever the cause in the toolchain, the rule is now: private-use
glyphs are written as escapes -- `"\uF104"`, `"\u{F092F}"` -- in every file this
project writes.

### The screens, and `activate()` on the shell's own windows

Wi-Fi and Bluetooth are FloatingWindows (gestures.md K). The window rule gives
each a workspace -- `org.quickshell`, `[0,26] 360x674`, alone on it -- and the
carousel lists them as `mobile.wifi` and `mobile.bluetooth`.

K12 failed: summoning Wi-Fi while Bluetooth was focused left Bluetooth focused.
The handle was resolved -- `recents list` named the screen through it -- so the
foreign-toplevel `activate()` that focused foot in E2 does nothing for the
shell's *own* windows. Focusing by Hyprland address,
`hl.dsp.focus({ window = "address:0x…" })`, moved focus across workspaces, and
every focus goes that way now, with `activate()` as the fallback. (A `title:^…`
selector answered "window not found".) moarchy's `show()` -- visible false, then
true -- reopens a screen the compositor closed from outside, measured by closing
Bluetooth through `hl.dsp.window.close()` and summoning it again.

### The selftest nearly closed someone's Moonlight

A Moonlight window appeared on workspace 1 mid-session: the user's. The suite's
reset killed every client, and E3 and E6 flicked card 0 blind. It now opens its
own windows as `sel-*`, closes only those and the shell's screens, skips the two
criteria that need an empty phone while anything else is up, and will not flick
a card that is not its own.

### Hyprland's debug overlay deadlocked Hyprland

The drag traces had fallen from 13-14 samples to 3-4, and `debug:overlay` was
the obvious way to read frame times. It showed them -- 4 FPS, ~270ms average
render time mid-drag -- and shortly after it was switched off Hyprland stopped:
every thread in `__futex_wait`, IPC and screencopy dead, the log silent. A new
`[pango] fontcon` thread had appeared, and pango draws the overlay's text.
SIGTERM was ignored; SIGKILL, then a reboot at the user's word. Not again.

### What the slowdown was not

Two suspects, each tested on its own:

- **Pointer churn.** vm-drag.sh creates a uinput device per gesture, 87 so far,
  each removal logging libseat's "Could not close device: Device not taken". A
  fresh session read 4 samples with none, and 4 again after 20 more.
- **The shade's always-mapped surface.** Pushed with it unmapped, then with the
  drawer unmapped too: 3-4 and 3-7 samples, the same as with both mapped. An idle
  transparent surface costs nothing measurable here.

What did change is the environment. The fast numbers were taken with QEMU
headless; every slow one with it windowed, and with macOS's `mediaanalysisd` at
269% CPU on the host. The trace-count checks now drag over 720ms instead of 360,
which proves "follows the finger" at any frame rate.

### Every push crashed the shell

The stray cards were the tell. After a reboot, with nothing opened, the carousel
listed two `org.quickshell` windows titled "quickshell" that belonged to no
screen, and E6 could never empty the phone past them. They belonged to two extra
quickshell processes, children of the shell the session had started, and the
shell's own log said where they came from, once per push:

```
Local plugin changed, reloading: mobile.shell
Local plugin changed, reloading: mobile.shell
ERROR: Quickshell has crashed under pid 17595 (Coredumps will be available under that pid.)
ERROR: Quickshell has been restarted.
```

with a SIGSEGV core for each in `coredumpctl`. vm-push.sh swapped the plugin's
files in first and restarted the shell afterwards, so the running shell saw its
plugin change mid-copy and hot-reloaded it -- the reload that segfaulted three
times in the drawer's first session, when a file was being written in place.
Quickshell restarted itself each time, and not always cleanly: an earlier child
kept running beside the new one, with its window mapped, its surfaces drawn and
its IPC answering or not depending on which instance a call reached. That is a
fair account of every "flaky" check this session.

The push now stops the shell with upstream's own kill loop before it touches a
file, and launches it again through the compositor afterwards, as
`omarchy-restart-shell` does.

One thing came out of the frame-rate work: `hypr/mobile.lua` turns layer animation off for
`omarchy-mobile-*`, as upstream does for its own surfaces -- every sheet here
animates itself. Keeping the carousel mapped all the time, like the drawer, was
tried as well, to win back the frames a per-gesture map costs. It won none (5
samples still) and a card from an earlier gesture showed through the shade in
the next screenshot, so it went back.

Two failures in that run were the suite's own. Its guest helper is called
through ssh, which hands the remote shell one string to re-split, so
`notify "selftest 3" "Body"` arrived as four words: every notification was
summarised "selftest", and S18's "newest first" had nothing to tell apart. And
the trace drags run for 1.5 seconds now -- at the frame rates this VM reached
windowed, 720ms still left fewer than eight frames to count.

---

## 2026-09-11 -- Settings

settings.md, ported from `moarchy.settings`: a third screen that is a window,
beside Wi-Fi and Bluetooth. `SettingsScreen.qml` renders the tree in
`Pages.js`, `Guards.js` asks each page's questions in one `bash -lc`, and
`SettingsRow.qml` draws a row. The shade's gear opens it at the root and the
power glyph at Power, where both opened upstream's Omarchy menu before. The
native pages keep their helpers from moarchy, renamed `omarchy-mobile-*` and
shipped in `~/.local/bin` through skel: audio routing, reminders, time zone,
plugins, About, and the network name.

### Inside `mobile.shell`, for the usual reason

`moarchy.settings` is a plugin of its own and opens the Wi-Fi and Bluetooth
screens with `shell.summon()`. Under 4.0.3's sandbox a plugin can summon only
itself, so Settings is a screen of `mobile.shell` and a row that opens Wi-Fi
calls the host's `openScreen()`, with `returnTo: "settings"` so the Wi-Fi back
chevron comes back. Settings is still running on its own workspace when it
does, so it comes back on the page it was left on (A7), with nothing written
to make that happen. The IPC target is still `settings`, so every verb in
settings.md answers as written.

It loaded and mapped on the first push -- `class org.quickshell`, `360x674`,
the card reading `mobile.settings` -- which after the drawer's session is worth
writing down.

### Every terminal row was dead

The first bridged row tried in the VM mapped nothing, and the shell's log said
nothing about it. The user manager's journal did:

```
uwsm_app-daemon[901]: received: app -- xdg-terminal-exec --app-id=org.omarchy.terminal --title=Omarchy -e bash -c '...'
uwsm_app-daemon[901]: sent: error 'Error: Command not found: "xdg-terminal-exec"' 1
```

`omarchy-launch-floating-terminal-with-presentation` ends in
`uwsm-app -- xdg-terminal-exec`, and xdg-terminal-exec is an AUR package, so
`vm/packages/omitted` carried it. Nothing in the session needed it until forty
Settings rows did -- along with every terminal upstream's own menu opens, which
is to say this was broken before Settings and nobody had tapped anything that
showed it.

It is `[pkg.xdg-terminal-exec]` now, built by the loop that builds hyprland,
from the AUR's git at a pinned commit. The AUR keeps its PKGBUILD at the root
the way Arch's packaging repos do, so `vm/build-packages.sh` needed nothing new.
Docker was not running to build it, so the VM got the same v0.14.3 script by
hand, in `/usr/local` where a later package cannot collide with it, from the
tarball the PKGBUILD pins and checked against the PKGBUILD's sha256. The next
image build installs the package.

Two things came with it. `omarchy-default-terminal` reads through
`xdg-terminal-exec --print-id`, so the Terminal page ticked nothing before and
ticks Foot now. And the presentation terminal is not the float upstream asks
for. xdg-terminal-exec hands `--app-id` and `--title` on only to a terminal
whose desktop entry says how (`X-TerminalArgAppId`, `X-TerminalArgTitle`), and
foot's entry says nothing, so the window arrives as class `foot`, not
`org.omarchy.terminal`. Upstream's 875x600 float rule never matches it, and
the window rule tiles it into a workspace of its own:

```
{"class":"foot","title":"foot","floating":false,"at":[0,26],"size":[360,674],"ws":1}
```

875 pixels is 2.4 screens wide here, so the rule not matching is the better
outcome, and it is the one moarchy's E5 asks for on purpose.

### Upstream's commands, not moarchy's stand-ins

Most of moarchy's departures from upstream are Sway: nightlight on wlsunset,
lock on swaylock, logout through swaymsg, screenshots on bare grim, and a shell
restart that avoids Hyprland's socket. Here upstream's own command is the one
that works, so a bridged row runs upstream's action string. A static pass over
every row that claims a bridged id, against `omarchy-menu.jsonc` itself, finds
no difference but the ones declared at the row:

- **Screenshot** takes `fullscreen`. Upstream's bare call is `smart`, a region
  picker that wants a drag across the part to keep.
- **Change password** runs under sudo, as in moarchy: the account password is
  locked, so `passwd` has nothing to check the old one against.
- The three package rows lost moarchy's presentation wrapper, and are
  upstream's `xdg-terminal-exec --app-id=org.omarchy.terminal ...` byte for
  byte, now that the image has the command.

### Rows this image cannot run are not offered

Each is a `when:`, so the row comes back when what it needs does.

- **Lock.** Upstream's lock is the shell's own lock screen, which asks PAM, and
  the account ships with a locked password (`passwd -S` reads `L`). A lock
  nobody can lift, over a session you then reach only over ssh. Offered once
  the password is usable, which Change password is how you get.
- **AI agent.** `omarchy-default-agent` installs through `omarchy-mise-install`,
  and mise is not in the image.
- **Install from the AUR.** The picker searches and installs through yay, which
  is not in the image either.

### A version nobody could read

About's first row was "4.0.0.alpha". `omarchy-version` asks pacman for the
`omarchy` package, and this image vendors Omarchy from a commit rather than
installing it, so it exits 1 with nothing printed. Upstream's own version file
is what the fallback found, and at v4.0.3 it reads 4.0.0.alpha. The release
file now records the manifest's pin, `OMARCHY_VERSION` and `OMARCHY_REF`, and
About reads that first. The running VM predates it and will say 4.0.0.alpha
until it is rebuilt.

### Three changes to moarchy's machinery

- A choice's write runs as a process, and the page re-reads when it exits.
  moarchy started the write and re-read straight away, which races it:
  `omarchy-theme-set` takes seconds, and the tick stayed on the old theme. A
  second tap while one is running waits for it rather than killing it, because
  a theme stopped halfway is a theme half applied.
- A row a guard hides takes no space. The ListView's `spacing` was kept for
  every hidden row, so Power with Lock withdrawn began 6px lower than every
  other page, and More software, with most of its offers withdrawn, stacked
  those gaps up between the rows it did show.
- A choice page scrolls its ticked row into view once, when its reader
  answers. The theme in use was below the fold of a 22-row list.

Not ported: search from the drawer (settings.md O) and the coding-agent tile
(P), which needs mise; the back gesture that K7 and B3 ride on is not built.

### The run

`vm-selftest.sh S K settings`: 85 checks, all passing on the first run. 53 are
Settings' own, including real taps on the gear, the power glyph, a row and the
back chevron, one real terminal opened from a row and closed, and a reminder
set, listed, asked about and cancelled. The shade's S2 changed its answer from
the Omarchy menu to Settings and gained S3 for the power glyph.

## 2026-09-11 -- notifications live in the shade

Nothing toasts any more. Every notification goes straight into the shade's
list, each card leads with its sender's icon, and a bell beside the clock says
something is waiting (shade.md S24–S26).

### Why a patch

The toasts are upstream's: a popup model and an Overlay window inside
`notifications/Service.qml`. The first-party proxy a bar-kind plugin is handed
carries `doNotDisturb` and nothing else, so the plugin can reach neither. Two
ways round that were weighed and dropped:

- Watch the live-toast files and run `notifications dismissAll` as each one
  appears. No patch, but every toast is on screen for a fork and an IPC round
  trip first -- a flash over the app, every time.
- Leave Do Not Disturb on. It already writes a notification straight into
  history, but it drops the ephemeral ones outright, still toasts Omarchy's own
  confirmations and critical CLI alerts, and takes the Silent tile's meaning
  with it.

So `notification-popups-bar-opt-out.patch`. The service already reads
`shell.bar` by name to place its toasts under the bar; now it also reads
`notificationPopups`, and a `false` sends every notification down the path a
silenced one takes, into history. A bar that says nothing keeps its toasts, so
stock Omarchy is untouched and `bar.id` stays the one switch between the phone
and the desktop. Toasts already up when the bar says no -- restored across a
restart before the bar loaded -- are archived, not dropped, and `showHistory`,
which replays history as toasts, answers `none`.

### Silent still means something

The new branch comes after the DND one. With Silent on, upstream's rule for a
silenced notification still decides what is kept: a transient one, or a bare
`notify-send`, is dropped. With Silent off everything is kept, confirmations
included, because with no toast the list is the only place they can be seen.
The bar's bell hides while Silent is on and Silent's own glyph stands in.

### Where a card's icon comes from

A history row carries `image`, `appIcon` and `glyph`, and upstream already
copies file-backed images beside the history, so an avatar outlives the
sender's temp file. The card takes the first of those that resolves -- themed
names through `Quickshell.iconPath(name, true)`, the rule upstream's own card
uses -- then the icon of the desktop entry the app name matches, then a bell.
That lookup was the carousel's appId index, moved into Shell.qml so both read
one copy, and it now indexes entry names too: a notification says "Firefox",
not `firefox`.

### The bell counts files

There is no model to count: the proxy has no popup model, and history is a
directory. So Bar.qml counts `*.json` there and re-counts on a directory watch,
the toggles' pattern. It makes the directory before it watches it, because
FileView cannot watch a path that does not exist and a first boot can get here
before the service has made it.

### vm-push.sh applies the patches

The push only ever touched the user's home, and this change is in
`/usr/share/omarchy`. It now copies `patches/` over too and applies, with
sudo and `--fuzz=0`, each one that does not already reverse cleanly, dry-running
it first so a patch that fails part-way leaves nothing behind. A second push
onto a patched guest applies nothing and exits 0.

### The run

`vm-selftest.sh S H E` first: 38 checks, all passing, S24, S25 and S26 among
them. Then the whole suite, because Shell.qml and `patches/` reach every
section: 128 of 129. The one failure was S0, the shade reading closed after a
pull that had followed the finger. It passed on a rerun of H then S, the full
run's order, and that rerun lost S7, S10, S11 and S14 instead -- each found the
shade shut when it went to tap a tile.

Not this change, and not a flake either. Other sessions were driving the same
VM: when the rerun ended the guest held a Settings window no check had left
open, and the shell had restarted seconds before, from nobody's push in this
session. A shell restart, or any sheet opening, shuts the shade under a run. It
had happened the other way round already: this change's first push restarted
the shell in the middle of another session's `settings` section, and because
the selftest's dryRun guard does not survive a restart, that run's Restart row
rebooted the guest for real. One VM wants one driver at a time.

### Tap to run

Clicking a toast ran it, and the first cut of this change lost that: a card in
the shade only swiped away. Now a tap on a card does what the toast's click did,
in upstream's order (`invokePopupDefault`), then removes the card and closes the
shade (S27):

- Omarchy's own `--exec` argv, which upstream carries in the row as data
  precisely so a toast restored after a restart stays clickable. It survives
  into history the same way, so the first-run "Update System" still updates.
  Checked with upstream's own structural rule and run the way upstream runs it,
  `Util.execArgv`, as bash positional parameters rather than a shell string.
- Else the sender's window. Upstream asks `omarchy-hyprland-focus-app` to match
  a class; here it is the foreign-toplevel list the carousel already reads,
  matched on the app name, its reverse-DNS tail, or the id of the desktop entry
  the name matches, and focused through `focusToplevel` like any card.
- Else a launch of that desktop entry -- a step upstream does not have, because
  a desktop toast is about an app that is running. A phone's notification often
  is not.

The step history cannot keep is a sender's libnotify "default" action. It is a
method on the live notification, and `writeSilenced` lets that go once the row
is on disk -- which is also what tells a Chromium sender its notification is
gone. Keeping every notification live for as long as its card is listed would
fix it, and would mean the service tracking sender objects for the life of the
history, and ids that restart with every server; it is not attempted.
Focusing the sender is upstream's own fallback for the senders that register no
default action, which is most of them.

A card with nothing to run does not light under a finger, so it does not
promise a tap it will not keep. A swipe that springs back short of dismissing
still releases inside the card, so a tap is told apart by the card being where
it started.

`vm-selftest.sh S`: 30 checks, all passing. Three are S27's, every one a real
tap on card 0: a card with nothing to run stays, with the shade still up; an
`--exec touch` card creates its file, removes itself and closes the shade; a
card sent under a running window's app id focuses that window. H7a, a short
swipe that springs back, still dismisses nothing and runs nothing. The launch
branch has no check yet -- it needs a desktop entry whose app is not running.

## 2026-09-11 -- the on-screen keyboard

moarchy's keyboard, [moarchy-keyboard](https://github.com/SimonSchubert/moarchy-keyboard),
at the commit moarchy pins, and wired in the way moarchy wires it. The criteria
it brings in are gestures.md F3, I1a's keyboard half and I5-I6, and the typing
half of windows.md W5.

### The way moarchy does it

- **A pin, not a submodule.** `[pkg.moarchy-keyboard]` in `manifest.toml`, at
  `f1f2dda`, moarchy's ref. `vm/build-packages.sh` builds it in the same loop
  as hyprland and xdg-terminal-exec; it learned `pkgbuilddir`, moarchy's key,
  because this PKGBUILD lives in `packaging/`. It builds the checkout it sits
  in, so the ref pins the code too. 0.1.0-3 built on the first run.
- **In the session tier**, so a `--session-only` image can type.
- **Started by the compositor.** moarchy has `exec_always moarchy-keyboard` in
  Sway's autostart; here `hypr/mobile.lua` calls `o.launch_on_start`, the
  helper upstream's own autostart template names, which runs it through
  uwsm-app. A second instance exits on its own, since the protocol grants one
  input method per seat.
- **The toggle.** `omarchy-mobile-toggle-keyboard` is moarchy's
  `moarchy-toggle-keyboard` renamed, on the key moarchy binds, Super+I.
- **The shell's half**, ported from moarchy.gestures and moarchy.drawer: going
  home hides the keyboard (F3); the drawer drops its inset under the strip while
  the keyboard is up (I5a, I5e), lets go of its search field on close (I5c), and
  puts the keyboard away on close unless it is launching an app (I5d); and the
  band's fill gives way to the keyboard (I1a). Both surfaces tell whether the
  keyboard is up from their own configured height, as moarchy's do.

Not ported: `moarchy-has-keyboard`, which exists to stop the lock screen
stranding a phone that cannot type its password, and this image hides Lock. The
back gesture's keyboard branch waits for the back gesture. I5d's Settings and
theme-picker halves have nothing to act on here: Settings is a window, and the
theme picker is a page of it.

### The keyboard as shipped works on Hyprland

Hyprland advertises the three protocols it needs: input-method-v2,
virtual-keyboard-v1, and text-input-v3 for apps. It mapped 91 ms after start and
drew its first frame at 141. A focused `foot` raised it with nothing asking,
chose its terminal layout, and took a real tap through the VM's pointer: Esc
arrived as `1b`, then `q` as `q`. The pointer reaches it because its one
MultiPointTouchArea has `mouseEnabled`.

### Hyprland stacks exclusive zones the other way up

Measured with the keyboard forced up: the keys at y 520-720, the strip at
500-520, between the app and the keys. This is the "stranded pill" moarchy
records in `panel.cpp`, and moarchy's fix inverts here. Sway resolves exclusive
zones layer by layer from Overlay down, so the keyboard sits on Top and the
strip on Overlay keeps the edge. Hyprland arranges from Background up: on one
edge the lowest layer gets the screen's edge, and the Top keyboard beat the
Overlay strip to it.

The keyboard could not move without patching it. It sets its own layer, Top
while it is up and Overlay while it is down to a handle (its AC 52). So the
reservation moved instead. The strip still draws the pill from Overlay but
reserves nothing (`ExclusionMode.Ignore`), and a new surface,
`omarchy-mobile-band`, reserves the same 20px from Bottom. It is transparent
and takes no input: Bottom is below every window and every sheet, so nothing it
could draw would be seen. Measured after:

| | keyboard down | keyboard up |
| --- | --- | --- |
| strip | 700-720 | 700-720 |
| keyboard surface | 500-724, a handle | 500-724, keys 500-700 |
| reserved at the bottom | 20 | 220 |
| drawer | 694, inset -20 | 474, inset 0 |
| home | 694, band filled behind a window | 494, band off |

The keyboard's 24px of background below its keys runs under the pill, which is
what its `--gesture-strip-inset` is for; this strip is 20.

### The guest could not install it

Pushing the keyboard into a running guest failed on `layer-shell-qt`'s
signature, "unknown trust". No image carries `archlinuxarm-keyring`: the build
pacstraps against the builder's keyring, so every package in the image was
verified, and pacman in the guest trusts none of ALARM's signatures afterwards.
`layer-shell-qt` went in from the builder's pacman cache as a local file
instead. The keyring is left for its own change.

### The hide comes before the raise

moarchy puts the keyboard away on the way home and on an overlay's close, and
F3 records that on Sway a hide before the workspace switch sticks as well as
one after. Here it does not. From Settings or Wi-Fi to an empty workspace, the
keyboard's log reads `showing -- a text input activated` after the switch:
something activates a text input as one of the shell's own windows loses focus,
with nothing on the new workspace to type into. Leaving `foot` the same way
raises nothing. What activates is not found.

The drawer's close raced the same way. A drawer over a terminal, tapped so it
held the seat's keyboard and then closed: the terminal's text input re-entered
132ms after the close, and moarchy's second hide, 250ms after, caught it that
time. In the run before, the same check had failed 6 of 6.

So the second hide is not timed any more. `retreatKeyboard` in Shell.qml hides,
then for one second hides again whenever the keyboard comes up, read off the
home surface's height. `goHome` and every drawer close that is not a hand-off go
through it. The cost is moarchy's: a field tapped inside that second has its
keyboard put away once.

### The drawer's cell targets were 20px low

`drawer cellTarget` worked the surface's top out as the screen's height less
the surface's, plus a strip: 46, where Hyprland reports 26. An 80px cell
forgave that. With the keyboard up the surface is 474 tall and the same sum
gives 266, and s.A8's tap on the Settings tile missed. Both targets are
surface-local now, and the selftest adds the drawer layer's y from `hyprctl`.

### The run

`vm-selftest.sh` gains a `keyboard` section. The whole suite, before the last
round of fixes: 144 of 149. The five failures were I5, whose "gap unchanged" is
moarchy's and cannot hold for a grid sized to its apps; s.A8, on the cell
target; settings' home-screen I1a, on the raise that follows the hide; and E2,
which passed on a rerun of E. The keyboard section's other checks passed: the
raise for a terminal, a typed `q`, I6's placement and up-flick, I5b's 220,
I1a's keyboard half, F3 from a terminal, I5a, I5c and I5e, and I5d once.

A rerun of D, H, settings and keyboard after the I5 and cell-target fixes
passed both, and failed I1a on the home screen and I5d (6 of 6 up), the timed
hide losing its race. `retreatKeyboard` is the answer to both and is the one
part of this change no check has run: the last run, W to S, passed its 44
checks and was stopped before the settings and keyboard sections.
