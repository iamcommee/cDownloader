#!/bin/zsh
# Puts the video tools cDownloader packs inside the app into a folder: yt-dlp (YouTube downloads), deno (which
# yt-dlp needs for YouTube), and ffmpeg with ffprobe (joining picture and sound). Each download is checked against
# its known checksum before it is used. Downloads are kept in .build/tools-cache, so later builds work offline.
# Usage: scripts/fetch-tools.sh <destination folder> <file for the yt-dlp version>
# To move to newer versions, change the versions, addresses and checksums below, and the versions named in
# "Resources/Licenses/Third-Party Notices.txt".
set -euo pipefail
cd "${0:A:h}/.."
DEST="${1:?Usage: scripts/fetch-tools.sh <destination folder> <file for the yt-dlp version>}"
VERSION_FILE="${2:?Usage: scripts/fetch-tools.sh <destination folder> <file for the yt-dlp version>}"
CACHE=".build/tools-cache"

# yt-dlp: one file for both Intel and Apple Silicon. The app keeps it current by itself after installing.
YTDLP_VERSION="2026.08.19"
YTDLP_SHA256="0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202"
DENO_VERSION="2.9.7"
# ffmpeg builds by Martin Riedl (https://ffmpeg.martin-riedl.de), signed and checked by Apple; the FFmpeg project
# publishes no Mac downloads itself.
FFMPEG_VERSION="9.0.2"

case "$(uname -m)" in
  arm64)
    DENO_ARCH="aarch64"
    DENO_SHA256="5cd46d6268f6f78f5d88bdc7159d20bd44cdaa4b3303474839f87ec6fe7ae25c"
    FFMPEG_BUILD="arm64/1789931890_9.0.2"
    FFMPEG_SHA256="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"
    FFPROBE_SHA256="fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6"
    ;;
  x86_64)
    DENO_ARCH="x86_64"
    DENO_SHA256="95daaff11c116a52ad54785e7914c8e9c9cdcaba793c5ed929c74ca2d8e6259a"
    FFMPEG_BUILD="amd64/1789931006_9.0.2"
    FFMPEG_SHA256="7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4"
    FFPROBE_SHA256="2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd"
    ;;
  *)
    echo "No tools known for this Mac's processor: $(uname -m)" >&2
    exit 1
    ;;
esac

# fetch <address> <name in the cache> <checksum>: downloads a file once, and checks it every time.
fetch() {
  local file="$CACHE/$2"
  if [[ ! -f "$file" ]] || ! echo "$3  $file" | shasum -a 256 -c --status; then
    mkdir -p "$CACHE"
    curl -fsSL --retry 3 -o "$file.part" "$1"
    mv "$file.part" "$file"
  fi
  if ! echo "$3  $file" | shasum -a 256 -c --status; then
    rm -f "$file"
    echo "$2 does not match its known checksum, so it is not packed. Was the download changed?" >&2
    exit 1
  fi
}

fetch "https://github.com/yt-dlp/yt-dlp/releases/download/$YTDLP_VERSION/yt-dlp_macos" "yt-dlp-$YTDLP_VERSION" "$YTDLP_SHA256"
fetch "https://github.com/denoland/deno/releases/download/v$DENO_VERSION/deno-$DENO_ARCH-apple-darwin.zip" "deno-$DENO_VERSION-$DENO_ARCH.zip" "$DENO_SHA256"
fetch "https://ffmpeg.martin-riedl.de/download/macos/$FFMPEG_BUILD/ffmpeg.zip" "ffmpeg-$FFMPEG_VERSION-$DENO_ARCH.zip" "$FFMPEG_SHA256"
fetch "https://ffmpeg.martin-riedl.de/download/macos/$FFMPEG_BUILD/ffprobe.zip" "ffprobe-$FFMPEG_VERSION-$DENO_ARCH.zip" "$FFPROBE_SHA256"

UNPACK="$(mktemp -d)"
trap 'rm -rf "$UNPACK"' EXIT
unzip -q "$CACHE/deno-$DENO_VERSION-$DENO_ARCH.zip" deno -d "$UNPACK"
unzip -q "$CACHE/ffmpeg-$FFMPEG_VERSION-$DENO_ARCH.zip" ffmpeg -d "$UNPACK"
unzip -q "$CACHE/ffprobe-$FFMPEG_VERSION-$DENO_ARCH.zip" ffprobe -d "$UNPACK"

mkdir -p "$DEST"
cp "$CACHE/yt-dlp-$YTDLP_VERSION" "$DEST/yt-dlp"
cp "$UNPACK/deno" "$UNPACK/ffmpeg" "$UNPACK/ffprobe" "$DEST/"
chmod 755 "$DEST/yt-dlp" "$DEST/deno" "$DEST/ffmpeg" "$DEST/ffprobe"
# The app compares this with its own updated copy, so a newer app never runs an older yt-dlp. It goes in a separate
# place because the app's programs folder may hold only programs.
mkdir -p "${VERSION_FILE:h}"
print -r -- "$YTDLP_VERSION" > "$VERSION_FILE"
echo "Packed yt-dlp $YTDLP_VERSION, deno $DENO_VERSION, ffmpeg and ffprobe $FFMPEG_VERSION into $DEST"
