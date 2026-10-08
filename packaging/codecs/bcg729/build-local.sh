#!/usr/bin/env bash
# Build only: never install a module, change its autoload, or contact the engine.
set -euo pipefail
codec_recipe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
codec_repo_dir=$(cd -- "$codec_recipe_dir/../../.." && pwd)
codec_build_dir=/usr/local/src/openwebpbx-bcg729
codec_install_dependencies=true
if [[ ${1:-} == --no-dependencies ]]; then codec_install_dependencies=false; shift; fi
if [[ $# -gt 1 ]]; then echo 'Usage: build-local.sh [--no-dependencies] [absolute-build-directory]' >&2; exit 1; fi
if [[ $# == 1 ]]; then codec_build_dir=$1; fi
if [[ "$codec_build_dir" != /* || "$codec_build_dir" == / ]]; then echo 'Use a dedicated absolute build directory.' >&2; exit 1; fi
source /etc/os-release
if [[ "$ID" != debian || "$VERSION_ID" != 13 || $(dpkg --print-architecture) != amd64 ]]; then
    echo 'This recipe is qualified only for Debian 13 amd64.' >&2; exit 1
fi
if $codec_install_dependencies; then
    if [[ $EUID != 0 ]]; then echo 'Run as root to install dependencies, or use --no-dependencies.' >&2; exit 1; fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends build-essential pkg-config git ca-certificates libbcg729-dev
fi
if ! pkg-config --exists freeswitch libbcg729; then
    echo 'Matching installed FreeSWITCH development headers and libbcg729-dev are required.' >&2; exit 1
fi
for codec_command in git patch cc; do command -v "$codec_command" >/dev/null; done
readonly codec_revision=4203247dee4719545005ec7ab9ea536fc83df1d8
readonly codec_url=https://github.com/xadhoom/mod_bcg729.git
mkdir -p -- "$codec_build_dir"
codec_build_dir=$(cd -- "$codec_build_dir" && pwd)
codec_upstream="$codec_build_dir/upstream"
codec_source="$codec_build_dir/reviewed"
if [[ ! -d "$codec_upstream/.git" ]]; then
    if [[ -e "$codec_upstream" ]]; then echo 'Existing upstream directory is not a Git checkout.' >&2; exit 1; fi
    git init -q "$codec_upstream"
    git -C "$codec_upstream" remote add origin "$codec_url"
fi
if [[ $(git -C "$codec_upstream" remote get-url origin) != "$codec_url" ]]; then
    echo 'Build source origin does not match the reviewed upstream.' >&2; exit 1
fi
if ! git -C "$codec_upstream" cat-file -e "$codec_revision^{commit}" 2>/dev/null; then
    git -C "$codec_upstream" fetch --depth=1 origin "$codec_revision"
fi
[[ $(git -C "$codec_upstream" rev-parse "$codec_revision^{commit}") == "$codec_revision" ]]
mkdir -p -- "$codec_source"
git -C "$codec_upstream" show "$codec_revision:mod_bcg729.c" > "$codec_source/mod_bcg729.c"
git -C "$codec_upstream" show "$codec_revision:LICENSE" > "$codec_source/LICENSE"
patch --batch --forward --ignore-whitespace -d "$codec_source" -p1 < "$codec_recipe_dir/buffer-safety.patch"
read -r -a codec_cflags <<< "$(pkg-config --cflags freeswitch libbcg729)"
read -r -a codec_libs <<< "$(pkg-config --libs freeswitch libbcg729)"
cc -fPIC -O2 -Wall -Wextra -Wno-unused-parameter -Werror -std=c99 \
    "${codec_cflags[@]}" -shared "$codec_source/mod_bcg729.c" \
    "${codec_libs[@]}" -Wl,-z,defs,-z,relro,-z,now -o "$codec_build_dir/mod_bcg729.so"
cc -O1 -g -Wall -Wextra -Wno-unused-parameter -Werror -std=c99 \
    -fsanitize=address,undefined "${codec_cflags[@]}" \
    "-DOPENWEB_BCG729_SOURCE=\"$codec_source/mod_bcg729.c\"" \
    "$codec_repo_dir/tests/pbx_bcg729_codec.c" "${codec_libs[@]}" -lm \
    -o "$codec_build_dir/codec-check"
"$codec_build_dir/codec-check"
cp -- "$codec_recipe_dir/BCG729-COPYRIGHT.txt" "$codec_recipe_dir/BCG729-GPL-3.txt" "$codec_build_dir/"
cp -- "$codec_recipe_dir/NOTICES.md" "$codec_build_dir/"
{
    printf 'module_source_revision=%s\n' "$codec_revision"
    printf 'bcg729_version=%s\n' "$(pkg-config --modversion libbcg729)"
    printf 'bcg729_debian_package=%s\n' "$(dpkg-query -W -f='${Version}' libbcg729-0)"
    printf 'freeswitch_version=%s\n' "$(pkg-config --modversion freeswitch)"
    sha256sum "$codec_recipe_dir/buffer-safety.patch" "$codec_source/mod_bcg729.c" "$codec_build_dir/mod_bcg729.so"
} > "$codec_build_dir/build-manifest.txt"
printf 'Reviewed module built: %s/mod_bcg729.so\n' "$codec_build_dir"
echo 'No running module, autoload configuration or service was changed.'
