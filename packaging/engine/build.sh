#!/usr/bin/env bash
# Run in an empty Debian 13 amd64 build container. Installs compiled engine files.
set -euo pipefail
build_root=${OPENWEB_ENGINE_BUILD:-/usr/src/openweb-engine}
script_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
apt-get update
apt-get install -y autoconf automake build-essential git libtool libtool-bin pkg-config cmake uuid-dev libssl-dev libpcre2-dev libsqlite3-dev libcurl4-openssl-dev libedit-dev libldns-dev libspeex-dev libspeexdsp-dev libopus-dev libsndfile1-dev libtiff-dev libjpeg-dev libpq-dev liblua5.2-dev libmemcached-dev libshout3-dev libmpg123-dev libmp3lame-dev libavformat-dev libswscale-dev libvpx-dev libyuv-dev yasm nasm zlib1g-dev
mkdir -p "$build_root"
build_dependency() {
 local name=$1 revision=$2
 git clone "https://github.com/freeswitch/$name.git" "$build_root/$name"
 git -C "$build_root/$name" checkout --detach "$revision"
 (cd "$build_root/$name"; sh autogen.sh; ./configure --enable-debug; make -j "$(nproc)"; make install)
 ldconfig
}
build_dependency sofia-sip ad36ac8f755308e8b87f98a505e83d4e408e5cc3
build_dependency spandsp 8f1e1646bdec99eac5fd2cd92c35563f736b9b89
git clone https://github.com/signalwire/freeswitch.git "$build_root/freeswitch"
git -C "$build_root/freeswitch" checkout --detach ef32e205295e29f034f1453ad245ba5efb07b94a
cd "$build_root/freeswitch"
./bootstrap.sh -j
cp "$script_root/modules.conf" modules.conf
export CPPFLAGS='-DHAVE_NUA_RELOAD_TLS'
./configure -C --enable-portable-binary --disable-dependency-tracking --enable-debug --prefix=/usr --localstatedir=/var --sysconfdir=/etc --with-openssl --enable-core-pgsql-support --with-modinstdir=/usr/lib/freeswitch/mod
make -j "$(nproc)"
make install
