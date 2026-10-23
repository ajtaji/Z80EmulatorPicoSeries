f="$1"; n=$(basename "$f"); out="head/$n"
[ -s "$out" ] && exit 0
u=$(printf '%s' "$f" | sed 's/ /%20/g')
curl -sS -r 0-16383 "https://raw.githubusercontent.com/SingleStepTests/z80/main/$u" -o "$out"
