# mtg-colourscripts

Shows a random Magic: The Gathering card in your terminal: framed text, optional art via [chafa](https://hpjansson.org/chafa/), and filters when you want them. Card data is cached locally so normal use does not hit the API.

Inspired by [pokemon-colorscripts](https://gitlab.com/phoneybadger/pokemon-colorscripts). Cards and art come from [Scryfall](https://scryfall.com/).

## Requirements

- bash 3.2+, awk, curl (always)
- [chafa](https://hpjansson.org/chafa/) (for art)
- jq and gzip (only for `--update`)

## Install

```bash
chmod +x mtg-colourscripts.sh
# optional: shorter name on your PATH
ln -s "$(pwd)/mtg-colourscripts.sh" ~/.local/bin/mtg-colorscript
```

The script refers to itself as `mtg-colorscript` in `--help`; either name is fine.

## First run

Download Scryfall bulk data and build the index. If chafa is installed, a few art images are prefetched as well.

```bash
mtg-colorscript --update
```

Re-run `--update` weekly or after new sets. After that:

```bash
mtg-colorscript
```

## Usage

```text
mtg-colorscript [options]
```

### Display

| Option | Description |
|--------|-------------|
| `-a`, `--art` | Art only, with name and illustrator underneath |
| `-c`, `--card` | Text frame only, no art |
| `-w`, `--width N` | Width in columns (default 44, minimum 24) |
| `-n`, `--name "NAME"` | Specific card (exact, then prefix, then substring) |
| `--no-refresh` | Do not prefetch upcoming cards in the background |

### Filters

Also available as env vars: `MTG_TYPE`, `MTG_COLOR`, `MTG_SET`, `MTG_RARITY`.

| Option | Description |
|--------|-------------|
| `-t`, `--type TEXT` | Type line contains TEXT (e.g. `dragon`) |
| `-C`, `--color LETTERS` | Has all of these colours (`WUBRG`), or `C` for colourless |
| `-s`, `--set CODE` | Set code, e.g. `dmu` |
| `-r`, `--rarity R` | `common`, `uncommon`, `rare`, `mythic`, etc. |

### Data

| Option | Description |
|--------|-------------|
| `-u`, `--update [URL]` | Download bulk data and rebuild the index |
| `-p`, `--prefetch [N]` | Download N art images now (default 50) |
| `--clear` | Delete the cache |

## Examples

```bash
mtg-colorscript -C R -t dragon          # red dragons
mtg-colorscript -s mh3 -r mythic        # MH3 mythics
mtg-colorscript -n "Lightning Bolt"
mtg-colorscript -a -w 60                # wider, art only
mtg-colorscript -c                      # text only
```

## Environment

| Variable | Default | Notes |
|----------|---------|-------|
| `MTG_CACHE_DIR` | `$XDG_CACHE_HOME/mtg-colorscript` (or `~/.cache/...`) | Cache directory |
| `MTG_BULK` | `unique_artwork` | Scryfall bulk type: `unique_artwork` or `oracle_cards` |
| `MTG_WIDTH` | `44` | Default width |
| `MTG_MODE` | `full` | `full`, `art`, or `card` |
| `MTG_ART_CACHE` | `200` | Max cached art files |
| `MTG_QUEUE_SIZE` | `5` | Cards with art ready ahead of time |
| `MTG_ART_FORMAT` | `symbols` | chafa format (`symbols`, `sixels`, `kitty`, `iterm`, `auto`) |
| `MTG_ART_SYMBOLS` | empty | Passed to `chafa --symbols` when set |
| `NO_COLOR` | unset | Disables ANSI colours when set |

## How it works

`--update` downloads Scryfall's bulk file, skips tokens / digital-only / non-game layouts, and writes a flat index to the cache. Art is fetched from their image CDN and stored on disk. A small queue of upcoming cards is topped up in the background so the next run is usually instant. If art is missing (new filters, first time, etc.), it may try a short CDN download; otherwise you get the text frame alone.

Uses bulk data for the index and only downloads art as needed. See Scryfall's [API docs](https://scryfall.com/docs/api) for their guidelines.

## Licence

Card names, rules text and imagery are (c) Wizards of the Coast. Data and images via Scryfall; personal / non-commercial use per their terms.
