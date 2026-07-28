# exFATorcist

Formats whole USB block devices as exFAT, with a tty-bound watcher for the
dedicated `exorcist` user.

## Layout

This repository contains a GNU Stow package in `stow/exFATorcist`.

When stowed into `/`, it installs:

- `stow/exFATorcist/usr/local/sbin/exFATorcist`
  to `/usr/local/sbin/exFATorcist`
- `stow/exFATorcist/home/exorcist/.local/bin/usb-exorcist-watch`
  to `/home/exorcist/.local/bin/usb-exorcist-watch`

The sudoers and systemd unit files are kept outside the stow package:

- `sudoers/exorcist`
  to `/etc/sudoers.d/exorcist`
- `systemd/usb-exorcist-watch.service`
  to `/etc/systemd/system/usb-exorcist-watch.service`

Both should be installed as root-owned regular files, not symlinks. The
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

Then it validates and installs the sudoers fragment, removes leftovers from the
older tty1/profile setup, masks `getty@tty2.service` and `autovt@tty2.service`,
and enables `usb-exorcist-watch.service`.

The service runs as `exorcist`, owns `/dev/tty2`, and starts the watcher there.
When a USB flash drive appears, the watcher launches `exFATorcist`; the
formatter still asks for explicit confirmation before destroying data.

To install files without reserving tty2 or starting the service:

```sh
sudo sh install.sh --no-enable
```

## Uninstall

Run the uninstaller as root:

```sh
sudo sh uninstall.sh
```

This stops and disables `usb-exorcist-watch.service`, removes legacy tty1
profile/user-service hooks if present, removes `/etc/sudoers.d/exorcist`,
unstows the package from `/`, and unmasks/restores the normal tty2 login getty.

To also remove the dedicated user and its home directory:

```sh
sudo sh uninstall.sh --remove-user
```

Because Stow deploys symlinks, keep this repository in a location that remains
available and readable after installation, such as `/usr/local/stow-src` or
`/opt`.
