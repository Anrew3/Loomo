#!/usr/bin/env bash
# Renders the app icon from its vector master (Design/Icon/loomo-icon.svg) into every size the
# asset catalog needs, with librsvg. The SVG is the only source: edit it, then run this.
#
#   scripts/make-icon.sh            # writes App/Resources/Assets.xcassets/AppIcon.appiconset
#   scripts/make-icon.sh <out-dir>  # writes somewhere else (for previews)
#
# Needs rsvg-convert:  brew install librsvg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Design/Icon/loomo-icon.svg"
OUT="${1:-$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset}"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found: brew install librsvg" >&2; exit 1; }
mkdir -p "$OUT"

images=""
for base in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((base * scale))
    suffix=""; [ "$scale" = 2 ] && suffix="@2x"
    name="icon_${base}x${base}${suffix}.png"
    rsvg-convert --width "$px" --height "$px" --keep-aspect-ratio "$SVG" --output "$OUT/$name"
    images+="    { \"filename\" : \"$name\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${base}x${base}\" },"$'\n'
  done
done

cat > "$OUT/Contents.json" <<EOF
{
  "images" : [
${images%,$'\n'}
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
EOF

# A 1024 px preview next to the master, for the README and for checking.
rsvg-convert --width 1024 --height 1024 "$SVG" --output "$ROOT/Design/Icon/loomo-icon-1024.png"
echo "Rendered $(ls "$OUT"/*.png | wc -l | tr -d ' ') sizes into $OUT"
