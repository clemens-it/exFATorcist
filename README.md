# exFATorcist

Formats whole USB block devices as exFAT, with a tty-bound watcher for the
dedicated `exorcist` user and a separate kernel diagnostic console.

## Layout

This repository contains a GNU Stow package in `stow/exFATorcist`.

When stowed into `/`, it installs:

- `stow/exFATorcist/usr/local/sbin/exFATorcist`
  to `/usr/local/sbin/exFATorcist`
- `stow/exFATorcist/home/exorcist/.local/bin/usb-exorcist-watch`
  to `/home/exorcist/.local/bin/usb-exorcist-watch`

The sudoers, systemd, and sysctl files are kept outside the stow package:

- `sudoers/exorcist`
  to `/etc/sudoers.d/exorcist`
- `systemd/usb-exorcist-watch.service`
  to `/etc/systemd/system/usb-exorcist-watch.service`
- `systemd/kernel-diagnostics.service`
  to `/etc/systemd/system/kernel-diagnostics.service`
- `sysctl/90-exFATorcist-console.conf`
  to `/etc/sysctl.d/90-exFATorcist-console.conf`

These should be installed as root-owned regular files, not symlinks. The
installer validates the sudoers fragment with `visudo`.

## Install

Run the installer as root:

```sh
sudo sh install.sh
```

The installer creates the `exorcist` user if needed, prepares the target
directories, runs:

```sh
stow -d stow -t / --restow exFATorcist
```

Then it validates and installs the sudoers fragment, installs the console
loglevel policy, reserves tty2 and tty8, and enables both system services.

The service runs as `exorcist`, owns `/dev/tty2`, and starts the watcher there.
When a USB flash drive appears, the watcher launches `exFATorcist`; the
formatter still asks for explicit confirmation before destroying data.
Cancelling the confirmation or encountering a per-device formatter error
returns the watcher to its waiting state for the next USB flash drive.

`kernel.printk = 4 4 1 4` keeps informational, notice, and warning messages
off normal kernel consoles while leaving errors and more severe events visible.
The root-owned `kernel-diagnostics.service` follows all current-boot kernel
journal messages on `/dev/tty8`, including the lower-priority messages hidden
elsewhere. Switch to it with `Alt+F8` from another text console, or
`Ctrl+Alt+F8` from a graphical session.

To install files without reserving either TTY, applying the live console
policy, or starting the services:

```sh
sudo sh install.sh --no-enable
```

The sysctl fragment is still installed in this mode and will be loaded during
the next boot. Running the normal installer later applies it immediately and
activates both TTY services.

## Uninstall

Run the uninstaller as root:

```sh
sudo sh uninstall.sh
```

This stops and disables both services, removes the installed root-owned files,
unstows the package from `/`, restores the previous live `kernel.printk`
setting, and releases tty2 and tty8. The normal tty2 login getty is restored;
tty8 returns to the system's normal automatic virtual-terminal handling.

To also remove the dedicated user and its home directory:

```sh
sudo sh uninstall.sh --remove-user
```

Because Stow deploys symlinks, keep this repository in a location that remains
available and readable after installation, such as `/usr/local/stow-src` or
`/opt`.
