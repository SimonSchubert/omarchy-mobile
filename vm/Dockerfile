# The disk builder: an aarch64 Arch container that assembles the VM's disk
# image. It runs NATIVELY on Apple Silicon (linux/arm64), so pacstrap installs
# real aarch64 packages at full speed with no emulation anywhere.
#
#   docker build --platform linux/arm64 -f vm/Dockerfile -t omarchy-mobile-builder .
#   docker run --rm --privileged -v "$PWD/vm/out:/out" omarchy-mobile-builder
#
# Needs --privileged, because arch-chroot bind-mounts /proc, /sys and /dev to
# run mkinitcpio inside the rootfs. Everything else avoids loop devices on
# purpose -- `mkfs.ext4 -d` and `mcopy` populate a filesystem image from a
# directory without mounting it, which Docker Desktop's VM cannot do reliably.
# That is moarchy's technique and it is here for moarchy's reason.
#
# Pinned by digest; the tag and the command to re-resolve it are in
# manifest.toml under [builder]. Dockerfiles cannot read a file at FROM time,
# so this is the one pin written twice -- keep the two in step.
FROM --platform=linux/arm64 menci/archlinuxarm@sha256:f7c6f64c0f246f41775e01793340c49f8e9abf3991141c25405361d56b100ccb

# Docker Desktop's Linux VM kernel does not expose Landlock, which pacman 7
# uses to sandbox downloads; without this every transaction fails with
#   "restricting filesystem access failed because Landlock is not supported"
RUN sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf

RUN pacman-key --init && pacman-key --populate archlinuxarm && \
    pacman -Syu --noconfirm \
      arch-install-scripts dosfstools e2fsprogs mtools util-linux \
      gptfdisk parted git

# The pins and their reader travel with the builder, so the image is
# self-contained: `docker run` needs no bind mount to know what to build.
COPY manifest.toml scripts/manifest.sh /usr/local/share/omarchy-mobile/

# makepkg refuses to run as root, so vm/build-packages.sh runs as `builder`.
# It needs passwordless sudo because makepkg -s installs build dependencies.
RUN useradd -m builder && \
    echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder

COPY vm/build-disk.sh     /usr/local/bin/build-disk
COPY vm/build-packages.sh /usr/local/bin/build-packages
COPY vm/configure.sh      /usr/local/share/omarchy-mobile/configure.sh

# The repo itself, last: it changes on every commit and everything above it
# does not, so the expensive pacman layer survives an edit.
COPY . /repo

ENTRYPOINT ["/usr/local/bin/build-disk"]
