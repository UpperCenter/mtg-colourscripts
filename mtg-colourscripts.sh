#!/usr/bin/env bash
# mtg-colorscript: random Magic: The Gathering card in the terminal.
# Inspired by pokemon-colorscripts. Index from Scryfall bulk data
# (https://scryfall.com/docs/api/bulk-data); art from their image CDN,
# cached locally so a normal run does not hit the API.
#
# Requires: bash 3.2+, awk, curl. jq and gzip for --update only. chafa for art.

set -uo pipefail

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf-8*|*UTF8*|*utf8*) ;;
  *) export LC_ALL=C.UTF-8 ;;
esac

VERSION="0.3.1"
API="https://api.scryfall.com"
UA="mtg-colorscript/$VERSION"
SEP=$'\x1f'

CACHE_DIR="${MTG_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/mtg-colorscript}"
BULK_TYPE="${MTG_BULK:-unique_artwork}"       # unique_artwork | oracle_cards
WIDTH="${MTG_WIDTH:-44}"
MODE="${MTG_MODE:-full}"                      # full | art | card
ART_CACHE="${MTG_ART_CACHE:-200}"             # max cached art images
QUEUE_SIZE="${MTG_QUEUE_SIZE:-5}"             # upcoming cards with art ready ahead of time
ART_FORMAT="${MTG_ART_FORMAT:-symbols}"       # symbols | sixels | kitty | iterm | auto
ART_SYMBOLS="${MTG_ART_SYMBOLS:-}"            # chafa --symbols classes; empty = chafa default
BACKGROUND=1

F_TYPE="${MTG_TYPE:-}" F_COLOR="${MTG_COLOR:-}" F_SET="${MTG_SET:-}" F_RARITY="${MTG_RARITY:-}"

INDEX="$CACHE_DIR/index.txt"
ART_DIR="$CACHE_DIR/art"
QUEUE="$CACHE_DIR/queue.txt"
LOCK="$CACHE_DIR/.lock"

usage() {
  cat <<EOF
mtg-colorscript $VERSION: a random MTG card for your terminal

Usage: mtg-colorscript [options]

Display (default: a random card)
  -a, --art            art only, with name and artist underneath
  -c, --card           card text only, no art
  -w, --width N        card width in columns (default: $WIDTH)
  -n, --name "NAME"    show a specific card (exact, then prefix, then substring)
      --no-refresh     don't download upcoming cards in the background

Filters (also settable as MTG_TYPE, MTG_COLOR, MTG_SET, MTG_RARITY)
  -t, --type TEXT      type line contains TEXT, e.g. "dragon" or "legendary creature"
  -C, --color LETTERS  card has all these colours (WUBRG), or C for colourless
  -s, --set CODE       set code, e.g. dmu
  -r, --rarity R       common, uncommon, rare, mythic, special, bonus

Data
  -u, --update [URL]   download Scryfall bulk data and rebuild the index
                       (optionally from a specific bulk file URL)
  -p, --prefetch [N]   download N art images now (default: 50)
      --clear          delete the cache

First run:   mtg-colorscript --update
EOF
}

die()  { printf 'mtg-colorscript: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "'$1' is required but not installed"; }

# ---------------------------------------------------------------- data

api_get() {  # api_get PATH: GET from api.scryfall.com, with a retry on 429
  local out code attempt
  out=$(mktemp) || return 1
  for attempt in 1 2; do
    code=$(curl -sS --max-time 20 -H "User-Agent: $UA" -H "Accept: application/json" \
      -o "$out" -w '%{http_code}' "$API$1") || code=000
    if [[ $code == 429 && $attempt == 1 ]]; then
      echo "Scryfall rate limit hit; waiting 30 seconds before one retry..." >&2
      sleep 31
      continue
    fi
    break
  done
  if [[ $code == 200 ]]; then cat "$out"; rm -f "$out"; return 0; fi
  rm -f "$out"
  echo "Scryfall API returned HTTP $code for $1" >&2
  return 1
}

# Flatten bulk JSON (array or JSON Lines) to one line per card, fields joined with \x1f:
# id, name, mana, type, text (\x1e = newline), stats, set, rarity, artist, colours, art url.
# Multi-faced cards keep the front face. Tokens, digital-only, and non-game cards are skipped.
JQ_BUILD='
  def face: if ((.card_faces // []) | length) > 0 then .card_faces[0] else . end;
  ["token","double_faced_token","emblem","art_series","planar","scheme","vanguard"] as $skip
  | (if type == "array" then .[] else . end)    # handles both .json arrays and .jsonl
  | select((.digital // false) | not)
  | select((.layout // "") as $l | $skip | map(. == $l) | any | not)
  | . as $c
  | ($c | face) as $f
  | ($c.image_uris.art_crop // $f.image_uris.art_crop // "") as $art
  | select($art != "")
  | [ $c.id,
      ($f.name // $c.name // ""),
      ($f.mana_cost // ""),
      ($f.type_line // $c.type_line // ""),
      (($f.oracle_text // "") | gsub("\n"; "\u001e")),
      (if   $f.power   != null then "\($f.power)/\($f.toughness)"
       elif $f.loyalty != null then "Loyalty: \($f.loyalty)"
       elif $f.defense != null then "Defense: \($f.defense)"
       else "" end),
      (($c.set // "") | ascii_upcase),
      (($c.rarity // "") | (.[0:1] | ascii_upcase) + .[1:]),
      ($f.artist // $c.artist // "Unknown"),
      (($c.colors // $f.colors // []) | join("")),
      $art ]
  | map(tostring | gsub("[\n\u001f]"; " ")) | join("\u001f")
'

cmd_update() {
  local meta uri tmp magic n
  need curl; need jq
  mkdir -p "$CACHE_DIR"
  uri=$BULK_URL
  if [[ -z $uri ]]; then
    echo "Looking up Scryfall's latest '$BULK_TYPE' bulk file..." >&2
    meta=$(api_get "/bulk-data/$BULK_TYPE") || die "couldn't get bulk data info"
    # Scryfall renamed download_uri to jsonl_download_uri when bulk moved to .jsonl.gz;
    # accept either, or any other field ending in download_uri.
    uri=$(jq -r '.jsonl_download_uri // .download_uri
                 // ([to_entries[] | select(.key | endswith("download_uri")) | .value][0])
                 // empty' <<<"$meta" 2>/dev/null)
    if [[ -z $uri ]]; then
      echo "Fields Scryfall returned: $(jq -r 'keys | join(", ")' <<<"$meta" 2>/dev/null)" >&2
      die "no download link found; you can pass one directly: --update URL"
    fi
  fi

  tmp="$CACHE_DIR/bulk.json.part"
  echo "Downloading ${uri##*/} (rerun --update weekly or after new sets)..." >&2
  curl -fL --compressed -# -H "User-Agent: $UA" -o "$tmp" "$uri" ||
    { rm -f "$tmp"; die "download failed"; }

  # Scryfall serves .jsonl.gz files; older bulk files were plain .json.
  # Check the first two bytes for the gzip signature rather than trusting the name.
  magic=$(head -c 2 "$tmp" | od -An -tx1 | tr -d ' \n')
  echo "Building index..." >&2
  if { if [[ $magic == 1f8b ]]; then gzip -dc "$tmp"; else cat "$tmp"; fi; } |
       jq -r "$JQ_BUILD" > "$INDEX.part" && [[ -s $INDEX.part ]]; then
    mv "$INDEX.part" "$INDEX"
  else
    rm -f "$INDEX.part" "$tmp"; die "couldn't build the index"
  fi
  rm -f "$tmp"
  rm -rf "$CACHE_DIR/cards"   # leftover from version 0.1
  n=$(wc -l < "$INDEX" | tr -d ' ')
  echo "Indexed $n cards." >&2

  if have chafa; then cmd_prefetch 50; queue_topup; fi
}

# pick_line OUT WHICH FILE: lines of FILE that match the filters.
# OUT is pick (one random line) or all. WHICH is any, cached (art downloaded),
# or missing (art not downloaded).
pick_line() {
  [[ -s $3 ]] || return 1
  ls -1 "$ART_DIR" 2>/dev/null | awk -F "$SEP" \
    -v out="$1" -v which="$2" -v t="$F_TYPE" -v col="$F_COLOR" -v s="$F_SET" -v r="$F_RARITY" \
    -v seed="$RANDOM$RANDOM" '
    BEGIN {
      if (which != "any") while ((getline l < "/dev/stdin") > 0) { sub(/\.jpg$/, "", l); have[l] = 1 }
      srand(seed); col = toupper(col)
    }
    function ok(  i) {
      if (t != "" && index(tolower($4), tolower(t)) == 0) return 0
      if (s != "" && toupper($7) != toupper(s)) return 0
      if (r != "" && tolower($8) != tolower(r)) return 0
      if (col == "C") { if ($10 != "") return 0 }
      else for (i = 1; i <= length(col); i++) if (index($10, substr(col, i, 1)) == 0) return 0
      if (which == "cached"  && !($1 in have)) return 0
      if (which == "missing" &&  ($1 in have)) return 0
      return 1
    }
    ok() { n++; if (out == "all") print; else if (rand() * n < 1) pick = $0 }
    END { if (out != "all" && n) print pick; if (!n) exit 1 }
  ' "$3"
}

find_name() {  # find_name NAME: exact, then prefix, then substring (random among ties)
  [[ -s $INDEX ]] || return 1
  awk -F "$SEP" -v q="$1" -v seed="$RANDOM$RANDOM" '
    BEGIN { srand(seed); q = tolower(q) }
    {
      nm = tolower($2); p = index(nm, q)
      tier = (nm == q) ? 1 : (p == 1) ? 2 : (p > 0) ? 3 : 0
      if (tier) { c[tier]++; if (rand() * c[tier] < 1) best[tier] = $0 }
    }
    END { for (i = 1; i <= 3; i++) if (c[i]) { print best[i]; exit } exit 1 }
  ' "$INDEX"
}

fetch_art() {  # fetch_art ID URL TIMEOUT: download from Scryfall's CDN (not rate-limited)
  local dest="$ART_DIR/$1.jpg"
  [[ -s $dest ]] && return 0
  mkdir -p "$ART_DIR"
  if curl -fsS --max-time "$3" -H "User-Agent: $UA" -o "$dest.part" "$2"; then
    mv "$dest.part" "$dest"
  else
    rm -f "$dest.part"; return 1
  fi
}

prune_art() {  # keep only the newest ART_CACHE images
  local f
  [[ -d $ART_DIR ]] || return 0
  ls -1t "$ART_DIR" 2>/dev/null | grep '\.jpg$' | tail -n +$((ART_CACHE + 1)) |
    while IFS= read -r f; do rm -f "$ART_DIR/$f"; done
}

prefetch() {  # prefetch N [show-progress]
  local n=$1 i ok=0 line id url
  for ((i = 1; i <= n; i++)); do
    line=$(pick_line pick missing "$INDEX") || break
    id=${line%%"$SEP"*}; url=${line##*"$SEP"}
    fetch_art "$id" "$url" 20 && ok=$((ok + 1))
    [[ -n ${2:-} ]] && printf '\rDownloaded art %d/%d' "$ok" "$n" >&2
    sleep 0.05
  done
  [[ -n ${2:-} ]] && printf '\n' >&2
  prune_art
}

cmd_prefetch() {
  need curl
  [[ $1 =~ ^[0-9]+$ ]] || die "--prefetch expects a number"
  [[ -s $INDEX ]] || die "no index yet; run 'mtg-colorscript --update' first"
  prefetch "$1" progress
}

queue_take() {  # print the first queued card that matches the filters, and dequeue it
  local line id
  line=$(pick_line all cached "$QUEUE" | head -n 1)
  [[ -n $line ]] || return 1
  id=${line%%"$SEP"*}
  grep -v -F "$id" "$QUEUE" > "$QUEUE.tmp" 2>/dev/null; mv "$QUEUE.tmp" "$QUEUE"
  printf '%s\n' "$line"
}

queue_topup() {  # download art for upcoming cards until QUEUE_SIZE matching ones are ready
  local line id url n tries=0
  mkdir -p "$CACHE_DIR"
  # One top-up at a time; a lock left by a killed run expires after 5 minutes.
  if ! mkdir "$LOCK" 2>/dev/null; then
    [[ -n $(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null) ]] || return 0
    rmdir "$LOCK" 2>/dev/null; mkdir "$LOCK" 2>/dev/null || return 0
  fi
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
  while (( tries++ < QUEUE_SIZE * 3 )); do
    n=$(pick_line all cached "$QUEUE" 2>/dev/null | wc -l | tr -d ' ')
    (( n < QUEUE_SIZE )) || break
    # Prefer cards whose art we have not seen yet.
    line=$(pick_line pick missing "$INDEX") || line=$(pick_line pick any "$INDEX") || break
    id=${line%%"$SEP"*}; url=${line##*"$SEP"}
    grep -qF "$id" "$QUEUE" 2>/dev/null && continue
    fetch_art "$id" "$url" 20 && printf '%s\n' "$line" >> "$QUEUE"
    sleep 0.05
  done
  # Entries left over from old filters should not pile up.
  tail -n 30 "$QUEUE" > "$QUEUE.tmp" 2>/dev/null && mv "$QUEUE.tmp" "$QUEUE"
  prune_art
}

start_topup() {
  (( BACKGROUND )) && have curl && have chafa || return 0
  ( queue_topup ) >/dev/null 2>&1 </dev/null &
  disown 2>/dev/null || true
}

# ---------------------------------------------------------------- rendering

setup_colors() {
  if [[ -n ${NO_COLOR:-} || ! -t 1 ]]; then
    RST="" DIM="" BOLD="" USE_COLOR=0
  else
    RST=$'\e[0m' DIM=$'\e[2m' BOLD=$'\e[1m' USE_COLOR=1
  fi
}

fg() { (( USE_COLOR )) && printf '\e[38;5;%sm' "$1"; }

rep() {  # rep CHAR COUNT
  local s
  (( $2 > 0 )) || return 0
  printf -v s '%*s' "$2" ''
  printf '%s' "${s// /$1}"
}

wrap() {  # wrap WIDTH TEXT: word-wrap by character count
  local w=$1 line="" word
  local -a words
  read -ra words <<<"$2"
  for word in ${words[@]+"${words[@]}"}; do
    if [[ -z $line ]]; then
      line=$word
    elif (( ${#line} + 1 + ${#word} <= w )); then
      line+=" $word"
    else
      printf '%s\n' "$line"; line=$word
    fi
    while (( ${#line} > w )); do
      printf '%s\n' "${line:0:w}"; line=${line:w}
    done
  done
  [[ -n $line ]] && printf '%s\n' "$line"
  return 0
}

row() {  # one line inside the frame; content must be plain text
  printf '%s│%s %s%*s %s│%s\n' "$BC" "$RST" "$1" $((INNER - ${#1})) '' "$BC" "$RST"
}

divider() { printf '%s├%s┤%s\n' "$BC" "$(rep ─ $((INNER + 2)))" "$RST"; }

colorize_mana() {  # colour {W} {U} {B} {R} {G} and other symbols in the frame text
  if (( ! USE_COLOR )); then cat; return; fi
  local e=$'\e'
  sed -E \
    -e "s/\{W\}/${e}[1;38;5;230m{W}${e}[0m/g" \
    -e "s/\{U\}/${e}[1;38;5;39m{U}${e}[0m/g" \
    -e "s/\{B\}/${e}[1;38;5;141m{B}${e}[0m/g" \
    -e "s/\{R\}/${e}[1;38;5;203m{R}${e}[0m/g" \
    -e "s/\{G\}/${e}[1;38;5;77m{G}${e}[0m/g" \
    -e "s/\{([0-9]+|[XYZTQSCE]|[^}/]*\/[^}]*)\}/${e}[1;38;5;250m{\1}${e}[0m/g"
}

border_color() {
  if (( ${#C_COLORS} > 1 )); then echo 178            # gold
  elif [[ $C_COLORS == W ]]; then echo 230
  elif [[ $C_COLORS == U ]]; then echo 39
  elif [[ $C_COLORS == B ]]; then echo 141
  elif [[ $C_COLORS == R ]]; then echo 203
  elif [[ $C_COLORS == G ]]; then echo 77
  elif [[ $C_TYPE == *Land* ]]; then echo 137         # brown
  else echo 250                                       # artifact silver
  fi
}

render_frame() {
  local name=$C_NAME max pad p line left right fill
  INNER=$((WIDTH - 4))

  # Title row: name on the left, mana cost on the right.
  max=$((INNER - ${#C_MANA} - (${#C_MANA} > 0 ? 1 : 0)))
  (( ${#name} > max )) && name="${name:0:max-1}…"
  pad=$((INNER - ${#name} - ${#C_MANA}))
  printf '%s╭%s╮%s\n' "$BC" "$(rep ─ $((INNER + 2)))" "$RST"
  printf '%s│%s %s%s%s%*s%s %s│%s\n' "$BC" "$RST" "$BOLD" "$name" "$RST" "$pad" '' "$C_MANA" "$BC" "$RST"

  divider
  while IFS= read -r line; do row "$line"; done < <(wrap "$INNER" "$C_TYPE")

  if [[ -n $C_TEXT ]]; then
    divider
    local IFS_SAVE=$IFS; IFS=$'\x1e'
    for p in $C_TEXT; do
      IFS=$IFS_SAVE
      while IFS= read -r line; do row "$line"; done < <(wrap "$INNER" "$p")
    done
    IFS=$IFS_SAVE
  fi

  if [[ -n $C_STATS ]]; then
    printf '%s│%s %*s%s%s%s %s│%s\n' "$BC" "$RST" $((INNER - ${#C_STATS})) '' "$BOLD" "$C_STATS" "$RST" "$BC" "$RST"
  fi

  # Bottom border: set, rarity, and artist credit.
  left=" $C_SET · $C_RARITY "
  right=" Illus. $C_ARTIST "
  fill=$((INNER - ${#left} - ${#right}))
  # When space is tight, drop rarity first, then the artist credit.
  if (( fill < 1 )); then left=" $C_SET "; fill=$((INNER - ${#left} - ${#right})); fi
  if (( fill < 1 )); then right=""; fill=$((INNER - ${#left})); fi
  printf '%s╰─%s%s%s%s%s%s%s─╯%s\n' "$BC" "$RST$DIM" "$left" "$RST$BC" "$(rep ─ "$fill")" \
    "$RST$DIM" "$right" "$RST$BC" "$RST"
}

render_art() {  # render_art IMAGE: prints art, or fails if it can't
  local img=$1 args=()
  have chafa && [[ -s $img ]] || return 1
  [[ $ART_FORMAT != auto ]] && args+=(--format="$ART_FORMAT")
  [[ -n $ART_SYMBOLS ]] && args+=(--symbols="$ART_SYMBOLS")
  case ${COLORTERM:-} in truecolor|24bit) args+=(--colors=full) ;; esac
  chafa ${args[@]+"${args[@]}"} --size="${WIDTH}x$((WIDTH * 3 / 8))" "$img" 2>/dev/null
}

show_line() {  # show_line INDEX_LINE
  local id url art
  IFS="$SEP" read -r id C_NAME C_MANA C_TYPE C_TEXT C_STATS C_SET C_RARITY C_ARTIST C_COLORS url <<<"$1"
  art="$ART_DIR/$id.jpg"
  BC=$(fg "$(border_color)")

  # Art not cached yet (e.g. after changing filters): one quick try from the CDN.
  if [[ $MODE != card ]] && have chafa && [[ ! -s $art ]] && have curl; then
    fetch_art "$id" "$url" 5 || true
  fi

  case $MODE in
    art)
      if render_art "$art"; then
        printf '%s%s%s %s- Illus. %s%s\n' "$BOLD" "$C_NAME" "$RST" "$DIM" "$C_ARTIST" "$RST"
      else
        render_frame | colorize_mana
      fi ;;
    card)
      render_frame | colorize_mana ;;
    *)
      render_art "$art" || true
      render_frame | colorize_mana ;;
  esac
}

# ---------------------------------------------------------------- main

ACTION=show NAME="" COUNT=50 BULK_URL=""
while (( $# )); do
  case $1 in
    -h|--help)     usage; exit 0 ;;
    -V|--version)  echo "$VERSION"; exit 0 ;;
    -a|--art)      MODE=art ;;
    -c|--card)     MODE=card ;;
    -w|--width)    WIDTH=${2:-}; shift ;;
    -n|--name)     ACTION=name; NAME=${2:-}; shift ;;
    -t|--type)     F_TYPE=${2:-}; shift ;;
    -C|--color)    F_COLOR=${2:-}; shift ;;
    -s|--set)      F_SET=${2:-}; shift ;;
    -r|--rarity)   F_RARITY=${2:-}; shift ;;
    -u|--update)   ACTION=update
                   if [[ ${2:-} == https://* ]]; then BULK_URL=$2; shift; fi ;;
    -p|--prefetch) ACTION=prefetch
                   if [[ ${2:-} =~ ^[0-9]+$ ]]; then COUNT=$2; shift; fi ;;
    --clear)       ACTION=clear ;;
    --no-refresh)  BACKGROUND=0 ;;
    *)             die "unknown option '$1' (see --help)" ;;
  esac
  shift
done

[[ $WIDTH =~ ^[0-9]+$ ]] && (( WIDTH >= 24 )) || die "--width must be a number, at least 24"
cols=$(tput cols 2>/dev/null || echo 0)
[[ $cols =~ ^[0-9]+$ ]] && (( cols >= 24 && cols < WIDTH )) && WIDTH=$cols

setup_colors

case $ACTION in
  update)   cmd_update ;;
  prefetch) cmd_prefetch "$COUNT" ;;
  clear)    rm -rf "$CACHE_DIR"; echo "Cache cleared." ;;
  name)
    [[ -n $NAME ]] || die "--name needs a card name"
    line=$(find_name "$NAME") || die "no card found matching '$NAME'"
    show_line "$line" ;;
  show)
    if [[ ! -s $INDEX ]]; then
      echo "mtg-colorscript: no card index yet. Run 'mtg-colorscript --update' first." >&2
      exit 0
    fi
    line=""
    if [[ $MODE != card ]] && have chafa; then
      line=$(queue_take) || line=$(pick_line pick cached "$INDEX") || line=""
    fi
    [[ -n $line ]] || line=$(pick_line pick any "$INDEX") || {
      echo "mtg-colorscript: no cards match your filters." >&2; exit 0; }
    show_line "$line"
    start_topup ;;
esac