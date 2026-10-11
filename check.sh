#!/usr/bin/env bash
# Elixir Audits - daily website health check
# Public-facing only: no credentials required.
# Usage: bash check.sh [output_dir]
# Writes today's findings to <out>/latest.txt and a machine-readable state to <out>/state.tsv

set -uo pipefail
BASE="https://www.elixiraudits.com"
OUT="${1:-$(cd "$(dirname "$0")" && pwd)}"
STATE="$OUT/state.tsv"
PREV="$OUT/state-prev.tsv"
REPORT="$OUT/latest.txt"
TODAY=$(date +%Y-%m-%d)
UA="Mozilla/5.0 (compatible; ElixirAuditsSiteCheck/1.0)"

rm -rf "$OUT/pages"        # stale copies of URLs that have left the sitemap
mkdir -p "$OUT/pages"   # would otherwise be rescanned and reported forever
[ -f "$STATE" ] && cp "$STATE" "$PREV"
: > "$STATE"
: > "$REPORT"

say(){ printf '%s\n' "$*" >> "$REPORT"; }
fetch(){ curl -s --max-time 45 -A "$UA" "$@"; }

say "ELIXIR AUDITS - SITE CHECK  $TODAY"
say "=================================================="
say ""

# ---------- 1. discover URLs from the sitemap ----------
fetch "$BASE/sitemap.xml" -o "$OUT/sitemap.xml"
grep -oE '<loc>[^<]*' "$OUT/sitemap.xml" 2>/dev/null | sed 's|<loc>||' | sort -u > "$OUT/urls.txt"
NURL=$(wc -l < "$OUT/urls.txt" | tr -d ' ')
say "Pages in sitemap: $NURL"

if [ "$NURL" -lt 5 ]; then
  say ""
  say "!! CRITICAL: sitemap returned fewer than 5 URLs. Site or sitemap may be down."
  exit 0
fi

# ---------- 2. page status + timing + SEO fields ----------
BAD_STATUS=""; SLOW=""; NO_H1=""; NO_DESC=""; LONG_TITLE=""; DUP_CANON=""; CANON_MISMATCH=""
declare -a TITLES=() DESCS=()

while read -r u; do
  [ -z "$u" ] && continue
  path="${u#$BASE}"
  f="$OUT/pages/$(echo "$path" | sed 's|[/:]|_|g').html"
  m=$(fetch -o "$f" -w '%{http_code}|%{time_total}' "$u")
  code="${m%%|*}"; tt="${m##*|}"
  printf 'PAGE\t%s\t%s\t%s\n' "$u" "$code" "$tt" >> "$STATE"

  [ "$code" != "200" ] && BAD_STATUS="$BAD_STATUS
  $code  $u"

  awk -v t="$tt" 'BEGIN{exit !(t+0 > 4.0)}' && SLOW="$SLOW
  ${tt}s  $u"

  [ "$code" = "200" ] || continue
  F=$(tr '\n\r' '  ' < "$f")

  # h1
  h1=$(printf '%s' "$F" | grep -o '<h1' | wc -l | tr -d ' ')
  [ "$h1" = "0" ] && NO_H1="$NO_H1
  $u"

  # title
  ttl=$(printf '%s' "$F" | grep -oE '<title>[^<]*' | head -1 | sed 's|<title>||')
  [ ${#ttl} -gt 65 ] && LONG_TITLE="$LONG_TITLE
  ${#ttl} chars  $u"
  TITLES+=("$ttl")

  # meta description
  d=$(printf '%s' "$F" | grep -oE '<meta name="description" content="[^"]*"' | head -1 | sed 's|.*content="||;s|"$||')
  [ -z "$d" ] && NO_DESC="$NO_DESC
  $u"
  DESCS+=("$d")

  # canonical
  nc=$(printf '%s' "$F" | grep -o 'rel="canonical"' | wc -l | tr -d ' ')
  [ "$nc" -gt 1 ] && DUP_CANON="$DUP_CANON
  ${nc}x  $u"
  can=$(printf '%s' "$F" | grep -oE 'rel="canonical" href="[^"]*"' | head -1 | sed 's|.*href="||;s|"$||')
  if [ -n "$can" ] && [ "$can" != "$u" ]; then
    CANON_MISMATCH="$CANON_MISMATCH
  $u
     -> $can"
  fi
done < "$OUT/urls.txt"

# ---------- 3. links ----------
strip(){ perl -0pe 's/<script\b.*?<\/script>//gis; s/<style\b.*?<\/style>//gis' "$OUT"/pages/*.html 2>/dev/null; }   # ignore code inside script/style blocks
strip | grep -oE 'href="[^"]+"' | sed 's|href="||;s|"$||' \
  | grep -vE '^(#|mailto:|tel:|javascript:)' \
  | grep -vE '\.(css|js|png|jpe?g|svg|ico|webp|woff2?)(\?|$)' \
  | sort -u > "$OUT/links.txt"

BAD_LINKS=""; SCHEMELESS=""
while read -r l; do
  [ -z "$l" ] && continue
  # ignore bare font-host preconnects: they are not navigable links
  case "$l" in
    https://fonts.googleapis.com|https://fonts.gstatic.com) continue ;;
    https://ghalii.org/*) continue ;;   # blocks automated requests with 403; check by hand in a browser
  esac
  case "$l" in
    /*)            target="$BASE$l" ;;
    http*)         target="$l" ;;
    \?*)           target="$BASE/insights/$l" ;;      # query-only links (pagination)
    ../*|./*)      target="$BASE/${l##*../}" ;;        # excess ../ collapses to root
    *)
      # genuinely scheme-less: looks like a host, or a bare path with no leading slash
      case "$l" in
        www.*|*.com|*.com/*) SCHEMELESS="$SCHEMELESS
  $l"; continue ;;
        *) target="$BASE/$l" ;;
      esac ;;
  esac
  c=$(curl -s -o /dev/null -L --max-time 25 -A "$UA" -w '%{http_code}' "$target" 2>/dev/null)
  printf 'LINK\t%s\t%s\n' "$target" "$c" >> "$STATE"
  case "$c" in 200|000|999) ;; *) BAD_LINKS="$BAD_LINKS
  $c  $target" ;; esac
done < "$OUT/links.txt"

# ---------- 3b. false platform signals ----------
FAKEGEN=""
for f in "$OUT"/pages/*.html; do
  [ -e "$f" ] || continue
  if grep -q 'name="generator" content="WordPress' "$f" 2>/dev/null; then
    FAKEGEN="$FAKEGEN
  $(basename "$f" .html | sed 's|_|/|g')"
  fi
done

# ---------- 4. images ----------
BAD_IMG=""
strip | grep -oE '<img[^>]*>' | grep -oE ' src="[^"]+"' \
  | sed 's| src="||;s|"$||' | grep -E '\.(png|jpe?g|svg|webp|gif)(\?|$)' \
  | sed -E "s|^/|$BASE/|" | grep -E '^https?://' | sort -u > "$OUT/imgs.txt"
while read -r i; do
  [ -z "$i" ] && continue
  c=$(curl -s -o /dev/null -L --max-time 20 -A "$UA" -w '%{http_code}' "$i" 2>/dev/null)
  printf 'IMG\t%s\t%s\n' "$i" "$c" >> "$STATE"
  [ "$c" != "200" ] && BAD_IMG="$BAD_IMG
  $c  $i"
done < "$OUT/imgs.txt"

# ---------- 5. known-issue regression watch ----------
WATCH=""
chk(){ # label url expected
  c=$(curl -s -o /dev/null --max-time 25 -A "$UA" -w '%{http_code}' "$2")
  printf 'WATCH\t%s\t%s\n' "$2" "$c" >> "$STATE"
  [ "$c" != "$3" ] && WATCH="$WATCH
  $1: expected $3, got $c  ($2)"
}
# Refreshed site (Oct 2026): old URLs 301 to the new sections; unknown new URLs must 404.
chk "Old /blog/ redirect"        "$BASE/blog/" "301"
chk "Old /blog/feed/ redirect"   "$BASE/blog/feed/" "301"
chk "Old /team/ redirect"        "$BASE/team/" "301"
chk "Unknown insights slug"      "$BASE/insights/zz-does-not-exist-zz/" "404"
chk "Unknown leadership slug"    "$BASE/about/leadership/zz-does-not-exist-zz/" "404"
chk "Unknown firm-news slug"     "$BASE/firm-news/zz-does-not-exist-zz/" "404"
chk "Unknown top-level path"     "$BASE/zz-does-not-exist-zz/" "404"
chk "Bare-domain subpath"        "https://elixiraudits.com/insights/" "301"

# footer email link (should not point off-domain)
FOOTMAIL=$(cat "$OUT"/pages/*.html 2>/dev/null | grep -oE 'mailto:[A-Za-z0-9@._-]+' | sort -u \
  | grep -viE 'elixiraudits\.com|gra\.gov\.gh' || true)
[ -n "$FOOTMAIL" ] && WATCH="$WATCH
  Off-domain mailto still present: $(echo "$FOOTMAIL" | tr '\n' ' ')"

# security headers
HDR=$(curl -sI --max-time 20 -A "$UA" "$BASE/" )
for h in Strict-Transport-Security X-Content-Type-Options X-Frame-Options; do
  printf '%s' "$HDR" | grep -qi "^$h" || WATCH="$WATCH
  Security header missing: $h"
done

# ---------- 6. duplicates ----------
DUP_TITLE=$(printf '%s\n' "${TITLES[@]}" | sort | uniq -d | grep -v '^$' || true)
DUP_DESC=$(printf '%s\n' "${DESCS[@]}" | sort | uniq -d | grep -v '^$' || true)

# ---------- 7. new / removed pages vs yesterday ----------
NEWP=""; GONEP=""
if [ -f "$PREV" ]; then
  comm -13 <(grep '^PAGE' "$PREV" | cut -f2 | sort -u) <(grep '^PAGE' "$STATE" | cut -f2 | sort -u) > /tmp/_new || true
  comm -23 <(grep '^PAGE' "$PREV" | cut -f2 | sort -u) <(grep '^PAGE' "$STATE" | cut -f2 | sort -u) > /tmp/_gone || true
  NEWP=$(sed 's/^/  /' /tmp/_new)
  GONEP=$(sed 's/^/  /' /tmp/_gone)
fi

# ---------- report ----------
sect(){ [ -n "$2" ] && { say ""; say "$1"; say "$2"; }; }

ISSUES=0
countnz(){ [ -n "$1" ] && ISSUES=$((ISSUES+1)); }
for v in "$BAD_STATUS" "$BAD_LINKS" "$BAD_IMG" "$WATCH" "$DUP_CANON" "$NO_DESC" "$SCHEMELESS"; do countnz "$v"; done

sect "!! PAGES NOT RETURNING 200" "$BAD_STATUS"
sect "!! BROKEN LINKS" "$BAD_LINKS"
sect "!! BROKEN IMAGES" "$BAD_IMG"
sect "!! REGRESSION WATCH (known issues / expected fixes)" "$WATCH"
sect "!! DUPLICATE CANONICAL TAGS" "$DUP_CANON"
sect "!! SCHEME-LESS LINKS (resolve relative, will 404)" "$SCHEMELESS"
sect "!! PAGE FALSELY ADVERTISES WORDPRESS (generator tag)" "$FAKEGEN"
sect "MISSING META DESCRIPTION" "$NO_DESC"
sect "MISSING H1" "$NO_H1"
sect "TITLE OVER 65 CHARS" "$LONG_TITLE"
sect "CANONICAL POINTS ELSEWHERE" "$CANON_MISMATCH"
sect "DUPLICATE TITLES" "$DUP_TITLE"
sect "DUPLICATE DESCRIPTIONS" "$DUP_DESC"
sect "SLOW PAGES (>4s)" "$SLOW"
sect "NEW PAGES SINCE LAST RUN" "$NEWP"
sect "PAGES REMOVED SINCE LAST RUN" "$GONEP"

say ""
say "=================================================="
say "Pages checked: $NURL   Links: $(wc -l < "$OUT/links.txt" | tr -d ' ')   Images: $(wc -l < "$OUT/imgs.txt" | tr -d ' ')"
say "Blocking-issue categories triggered: $ISSUES"
[ "$ISSUES" -eq 0 ] && say "No broken links, images or status errors." || true

cp "$REPORT" "$OUT/history-$TODAY.txt" 2>/dev/null || true
cat "$REPORT"

# Exit 1 when something needs attention, so a scheduler (GitHub Actions) can alert.
ALERT=0
for v in "$BAD_STATUS" "$BAD_LINKS" "$BAD_IMG" "$WATCH" "$DUP_CANON" "$NO_DESC" "$NO_H1" "$SCHEMELESS" "$FAKEGEN" "$NEWP" "$GONEP"; do [ -n "$v" ] && ALERT=1; done
echo "$SLOW" | awk '{ if ($1+0 > 8) bad=1 } END{ exit bad }' || ALERT=1
exit $ALERT
