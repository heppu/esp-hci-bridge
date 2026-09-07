#!/bin/sh
# Builds the apt, rpm, and apk repositories from a directory of packages.
# Usage: packaging/make-repos.sh <packages dir> <repo dir> <keys dir>
# Needs dpkg-scanpackages, apt-ftparchive, createrepo_c, gpg, openssl, and
# docker for apk-tools.
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

# apk: one directory per arch, index signed the way abuild-sign does it
AKEY=heppu-esp-hci-bridge
APK="$REPO/alpine"
mkdir -p "$APK"
cp "$KEYS/$AKEY.rsa.pub" "$APK/"
for f in "$PKGS"/hcibridge_*_*.apk; do
    [ -f "$f" ] || continue
    base=$(basename "$f" .apk)
    # hcibridge_<ver>_<arch>.apk, and x86_64 has its own underscore
    case "$base" in
        *_x86_64) arch=x86_64 ;;
        *_aarch64) arch=aarch64 ;;
        *_armv7) arch=armv7 ;;
        *) echo "unknown apk arch in $base" >&2; exit 1 ;;
    esac
    ver=${base#hcibridge_}; ver=${ver%_$arch}
    mkdir -p "$APK/$arch"
    # apk fetches <name>-<version>.apk, whatever the file was called at build time
    cp "$f" "$APK/$arch/hcibridge-$ver.apk"
done
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$(cd "$APK" && pwd):/r" -v "$(cd "$KEYS" && pwd):/keys:ro" alpine:3.22 \
    sh -c 'for d in /r/*/; do cd "$d" && apk index --keys-dir /keys -o unsigned.tar.gz *.apk; done'
for d in "$APK"/*/; do
    ( cd "$d"
      openssl dgst -sha1 -sign "$OLDPWD/$KEYS/$AKEY.rsa" -out ".SIGN.RSA.$AKEY.rsa.pub" unsigned.tar.gz
      tar -c --owner=0 --group=0 --numeric-owner ".SIGN.RSA.$AKEY.rsa.pub" | head -c 1536 | gzip -9 > sig.tar.gz
      cat sig.tar.gz unsigned.tar.gz > APKINDEX.tar.gz
      rm -f sig.tar.gz unsigned.tar.gz ".SIGN.RSA.$AKEY.rsa.pub" )
done

find "$REPO" -type f | sort
