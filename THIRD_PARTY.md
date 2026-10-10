# Included projects

The repository's MIT license covers its own container configuration, scripts, and tests. Components inside the image retain their upstream licenses and notices.

| Component | Source |
| --- | --- |
| Brave Origin | [Brave Browser](https://github.com/brave/brave-browser) and [Brave Core](https://github.com/brave/brave-core); installed from Brave's official stable APT repository. |
| Selkies backend and web client | [Pinned source](https://github.com/selkies-project/selkies/tree/92dea42fc70bfcb52e6d98c4e6854872badfe621). Local modifications are in `patches/`; JavaScript dependency versions are in `dependencies/`. |
| Labwc window manager (stock and modified builds) | [Labwc 0.8.3](https://github.com/labwc/labwc/tree/0.8.3), licensed GPL-2.0-only, built without Xwayland. The image includes the source, the applied patch, license, and build recipe at `/usr/local/share/brave-origin/labwc-source.tar.xz`. See [modification details](patches/labwc/README.md). |
| Pixelflux and pcmflux | Supplied by the pinned [LinuxServer Selkies base image](https://github.com/linuxserver/docker-baseimage-selkies). |
| Debian packages | Debian 13 Trixie repositories. Package notices are installed under `/usr/share/doc/`. |

The Dockerfile identifies the source archive, checksum, and library image digest used to build the release. Installed Selkies Python modules include the patched backend source. The web client's corresponding source can be reconstructed from the pinned archive, repository patches, and dependency lockfiles.
