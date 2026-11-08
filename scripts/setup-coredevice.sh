#!/bin/bash
# Build only the pinned MIT-licensed CoreDevice input bridge in Application Support.
set -euo pipefail
destination="${1:?expected an absolute install path}"
revision=8c227a10710dad479852aa0203de729fed57471b
[[ "$destination" = /* ]] || exit 2
if [[ -x "$destination/bin/ipb" && -x "$destination/build/ipb-helper" ]]; then exit 0; fi
parent="$(dirname "$destination")"
mkdir -p "$parent"
stage="$(mktemp -d "$parent/.ipb-setup.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
if ! xcodebuild -version 2>/dev/null | /usr/bin/awk '/^Xcode / {ok=($2+0>=27)} END {exit !ok}'; then
    echo "Install and open Xcode 27 or later, then select it for command-line tools."
    exit 1
fi
if ! (
    export GIT_TERMINAL_PROMPT=0
    git init -q "$stage/source"
    git -C "$stage/source" fetch -q --depth=1 https://github.com/ipbtools/ipb.git "$revision"
    git -C "$stage/source" checkout -q --detach FETCH_HEAD
    [[ "$(git -C "$stage/source" rev-parse HEAD)" == "$revision" ]]
    /usr/bin/make -C "$stage/source" -j4 check-reports build/ipb-helper
); then
    echo "Could not build the Wired Control bridge. Check internet access and Xcode setup, then retry."
    exit 1
fi
mkdir -p "$stage/bridge/bin" "$stage/bridge/build"
cp "$stage/source/bin/ipb" "$stage/bridge/bin/"
cp "$stage/source/build/ipb-helper" "$stage/bridge/build/"
cp "$stage/source/LICENSE" "$stage/source/VERSION" "$stage/bridge/"
# Publish the complete bridge in one rename. Another successful setup may win.
if ! /bin/mv -n -h "$stage/bridge" "$destination" 2>/dev/null ||
   [[ ! -x "$destination/bin/ipb" || ! -x "$destination/build/ipb-helper" ]]; then
    echo "Could not install the Wired Control bridge in Application Support."
    exit 1
fi
