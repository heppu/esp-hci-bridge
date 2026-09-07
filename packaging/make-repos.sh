#!/bin/sh
# Builds the apt and rpm repositories from a directory of packages.
# Usage: packaging/make-repos.sh <packages dir> <repo dir> <keys dir>
# Needs dpkg-scanpackages, apt-ftparchive, createrepo_c, gpg. The apk
# repository is built by the release workflow with apk-tools.
set -eu
PKGS=$1
REPO=$2
KEYS=$3
SITE=https://heppu.github.io/esp-hci-bridge

export GNUPGHOME=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME"' EXIT
gpg --batch --quiet --import "$KEYS/hcibridge.gpg"
FPR=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')

mkdir -p "$REPO"
cp "$KEYS/hcibridge.gpg.pub" "$REPO/hcibridge.gpg.pub"
gpg --batch --yes --dearmor -o "$REPO/hcibridge.gpg" "$KEYS/hcibridge.gpg.pub"

# apt: one suite, one component, a binary index per architecture
DEB="$REPO/deb"
mkdir -p "$DEB/pool/main"
cp "$PKGS"/*.deb "$DEB/pool/main/"
ARCHES="amd64 arm64 armhf"
for a in $ARCHES; do
    d="$DEB/dists/stable/main/binary-$a"
    mkdir -p "$d"
    ( cd "$DEB" && dpkg-scanpackages --arch "$a" pool/main > "dists/stable/main/binary-$a/Packages" )
    gzip -9 -k -f "$d/Packages"
done
( cd "$DEB/dists/stable" && apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=esp-hci-bridge \
    -o APT::FTPArchive::Release::Label=esp-hci-bridge \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures="$ARCHES" \
    -o APT::FTPArchive::Release::Components=main \
    release . > Release
  gpg --batch --yes --local-user "$FPR" --clearsign -o InRelease Release
  gpg --batch --yes --local-user "$FPR" -abs -o Release.gpg Release )

# rpm: one directory per dnf basearch, packages signed at build time by nfpm
RPM="$REPO/rpm"
for pair in "x86_64 x86_64" "aarch64 aarch64" "armv7hl armhfp"; do
    rpmarch=${pair% *}
    basearch=${pair#* }
    d="$RPM/$basearch"
    mkdir -p "$d"
    cp "$PKGS"/*."$rpmarch".rpm "$d/" 2>/dev/null || continue
    createrepo_c --quiet "$d"
    gpg --batch --yes --local-user "$FPR" --detach-sign --armor -o "$d/repodata/repomd.xml.asc" "$d/repodata/repomd.xml"
done
cat > "$RPM/hcibridge.repo" <<EOF
[hcibridge]
name=esp-hci-bridge
baseurl=$SITE/rpm/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$SITE/hcibridge.gpg.pub
EOF

find "$REPO" -type f | sort
