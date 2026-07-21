# exFATorcist

Formats whole USB block devices as exFAT, with a small watcher service for the
dedicated `exorcist` user.

## Layout

This repository contains a GNU Stow package in `stow/exFATorcist`.

When stowed into `/`, it installs:

- `stow/exFATorcist/usr/local/sbin/exFATorcist`
  to `/usr/local/sbin/exFATorcist`
- `stow/exFATorcist/home/exorcist/.local/bin/usb-exorcist-watch`
  to `/home/exorcist/.local/bin/usb-exorcist-watch`
- `stow/exFATorcist/home/exorcist/.config/systemd/user/usb-exorcist-watch.service`
  to `/home/exorcist/.config/systemd/user/usb-exorcist-watch.service`

The sudoers fragment is kept outside the stow package at `sudoers/exorcist`.
It should be copied into `/etc/sudoers.d/exorcist` as a root-owned `0440`
regular file after validation with `visudo`.

## Install

Run the installer as root:

```sh
sudo sh install.sh
```

The installer creates the `exorcist` user if needed, prepares that user's home
directories, runs:

```sh
stow -d stow -t / --restow exFATorcist
```

Then it validates and installs the sudoers fragment, enables linger for the
`exorcist` user, and tries to enable and start the user service.

To install the files without enabling the service:

```sh
sudo sh install.sh --no-enable
```

Because Stow deploys symlinks, keep this repository in a location that remains
available and readable after installation, such as `/usr/local/stow-src` or
`/opt`.
