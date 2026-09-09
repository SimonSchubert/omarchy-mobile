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
