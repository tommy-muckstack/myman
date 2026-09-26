#!/usr/bin/env bash
# Point the AUR package at a MyMan release: ./update.sh 1.2.0
set -euo pipefail
version="${1:?usage: ./update.sh VERSION}"
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
sum="$(curl -fsSL "https://github.com/tommy-muckstack/myman/releases/download/v${version}/myman-linux-x64.tar.gz.sha256" | cut -d' ' -f1)"
[[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "No checksum found for v${version}." >&2; exit 1; }
sed -i -e "s/^pkgver=.*/pkgver=${version}/" -e "s/^pkgrel=.*/pkgrel=1/" -e "s/^sha256sums=.*/sha256sums=('${sum}')/" PKGBUILD
if command -v makepkg >/dev/null; then makepkg --printsrcinfo > .SRCINFO; else echo 'Run makepkg --printsrcinfo > .SRCINFO on Arch.' >&2; fi
