# lib.interp.models.sh - model catalog + RAM-aware curation for the Interpreter model chooser.
# Sourced by the chooser/download handlers. POSIX /bin/sh (bash 3.2). No Python: HF JSON is
# parsed with `plutil -p` + awk.
#
# The curation turns the machine's RAM and the live per-model download sizes into a small
# outcome-framed set (Best quality / Balanced-recommended / Faster) rather than exposing
# params/bit-width. Guiding rule: for a fixed memory budget, MORE PARAMETERS at 4-bit beats
# FEWER at 8-bit, so the recommended pick is the largest-params 4-bit model that fits with
# comfortable headroom; 8-bit is offered as the top "best quality" option only when it fits.

[ -n "${__INTERP_MODELS_LIB:-}" ] && return 0
__INTERP_MODELS_LIB=1

HF_AUTHOR="mlx-community"
# Canonical candidates, ranked best -> smallest by (params, then bits). Oddball repos
# (mxfp4, bf16, immersive-translate) are intentionally excluded from the curated set.
INTERP_CANDIDATES="translategemma-27b-it-8bit translategemma-27b-it-4bit translategemma-12b-it-8bit translategemma-12b-it-4bit translategemma-4b-it-8bit translategemma-4b-it-4bit"

machine_ram_bytes() { /usr/sbin/sysctl -n hw.memsize 2>/dev/null; }

model_params_of() { case "$1" in *-27b-*) echo 27B;; *-12b-*) echo 12B;; *-4b-*) echo 4B;; *) echo "?";; esac; }
model_bits_of()   { case "$1" in *-8bit) echo 8;; *-4bit) echo 4;; *) echo "?";; esac; }
model_short_label() { echo "$(model_params_of "$1") ($(model_bits_of "$1")-bit)"; }
bytes_to_gb() { /usr/bin/awk -v b="$1" 'BEGIN{ if(b+0<=0){print "?"} else printf "%.1f GB", b/1000000000 }'; }

# Total download size (bytes) of a repo's main revision. Each file object in the tree API
# reports a top-level "size" (the real size, for both LFS weights and small files) AND, for
# LFS files, a duplicate nested lfs."size" - so we count only the FIRST "size" per file object
# (reset at each array-element header `N => {`) to avoid double-counting the weights. Prints 0
# on failure / nonexistent repo.
hf_repo_size_bytes() {   # $1 = author/name
    /usr/bin/curl -fsSL --connect-timeout 15 --max-time 60 --retry 3 --retry-delay 2 --retry-all-errors \
        "https://huggingface.co/api/models/$1/tree/main?recursive=true" 2>/dev/null \
        | /usr/bin/plutil -p - 2>/dev/null \
        | /usr/bin/awk '
            /^[[:space:]]*[0-9]+ => \{/ { counted=0 }
            /"size" =>/ { if (!counted) { n=$3; gsub(/[^0-9]/,"",n); tot+=n; counted=1 } }
            END { print tot+0 }'
}

# Fetch each candidate's size into a cache file "name<TAB>size_bytes" (existing repos only).
interp_fetch_catalog() {   # $1 = output cache file
    local _out="$1" _name _sz
    : > "$_out"
    for _name in $INTERP_CANDIDATES; do
        _sz=$(hf_repo_size_bytes "$HF_AUTHOR/$_name")
        [ -n "$_sz" ] && [ "$_sz" -gt 0 ] 2>/dev/null || continue
        /usr/bin/printf '%s\t%s\n' "$_name" "$_sz" >> "$_out"
    done
    [ -s "$_out" ]
}

# Curate the cached catalog for this machine's RAM. Emits, tab-separated, one row per tier:
#   tier <TAB> repo <TAB> label <TAB> size_bytes <TAB> recommended(1/0) <TAB> heavy(1/0) <TAB> description
# tier in {best,balanced,faster}. Only OFFERABLE models are curated (fewer than three yields
# fewer rows). `repo` is the bare name (no author).
#
# Memory model (all vs hw.memsize R): estimated peak = weights*1.15 + 1.5 GB (short-context
# KV/activations + runtime). OFFER if peak <= 92% R (it will load - below mlx-agent's 0.90
# weights gate - and leave the OS room). HEAVY (a caveat, still offered) if peak > 70% R.
# COMFORTABLE (eligible to be the recommended pick) if peak <= 55% R.
interp_curate_models() {   # $1 = cache file from interp_fetch_catalog
    local _cache="$1" _ram _rows _tier _idx _rec _heavy _repo _size _desc
    [ -s "$_cache" ] || return 1
    _ram=$(machine_ram_bytes); [ "$_ram" -gt 0 ] 2>/dev/null || return 1

    # Per-process side channel for the awk-emitted ROW records: two concurrent curations (a fast
    # double-Refresh, or a reopen mid-load) would otherwise both write and read this one fixed
    # file and see each other's truncated rows.
    _rows="${_cache}.$$.rows"

    /usr/bin/awk -F'\t' -v ram="$_ram" '
        function peak(sz) { return sz*1.15 + 1500000000 }
        { name[NR]=$1; size[NR]=$2; N=NR }
        END {
            offer_ceil = ram*0.92; comfy_ceil = ram*0.55; heavy_floor = ram*0.70; nf=0
            for (i=1;i<=N;i++) if (peak(size[i]) <= offer_ceil) { nf++; fit[nf]=i }
            if (nf==0) exit 1
            best=fit[1]; faster=fit[nf]; bal=0
            # recommended = highest-quality 4-bit that fits comfortably (never a heavy model).
            for (k=1;k<=nf;k++) { i=fit[k]; if (name[i] ~ /4bit/ && peak(size[i]) <= comfy_ceil) { bal=i; break } }
            if (bal==0) bal = (nf>=2 ? fit[2] : fit[1])
            heavy_of[best] = (peak(size[best]) > heavy_floor) ? 1 : 0
            heavy_of[bal]  = (peak(size[bal])  > heavy_floor) ? 1 : 0
            heavy_of[faster] = (peak(size[faster]) > heavy_floor) ? 1 : 0
            if (best!=bal)   { print "best\t" best "\t0\t" heavy_of[best]; seen[best]=1 }
            print "balanced\t" bal "\t1\t" heavy_of[bal]; seen[bal]=1
            if (!(faster in seen) && faster!=bal && faster!=best) print "faster\t" faster "\t0\t" heavy_of[faster]
            for (i=1;i<=N;i++) print "ROW\t" i "\t" name[i] "\t" size[i] > "/dev/stderr"
        }
    ' "$_cache" 2>"$_rows" | while IFS='	' read -r _tier _idx _rec _heavy; do
        _repo=$(/usr/bin/awk -F'\t' -v i="$_idx" '$1=="ROW" && $2==i {print $3; exit}' "$_rows")
        _size=$(/usr/bin/awk -F'\t' -v i="$_idx" '$1=="ROW" && $2==i {print $4; exit}' "$_rows")
        case "$_tier" in
            best)
                if [ "$_heavy" = 1 ]; then
                    _desc="Highest quality, but heavy - uses most of your memory, so other apps may slow down."
                else
                    _desc="Highest quality. A larger model - more memory and a little slower."
                fi ;;
            balanced) _desc="Recommended. Great quality with comfortable memory use and speed." ;;
            faster)   _desc="Fastest and smallest. Best for quick translations; a little weaker on nuanced text." ;;
        esac
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$_tier" "$_repo" "$(model_short_label "$_repo")" "$_size" "$_rec" "$_heavy" "$_desc"
    done
    /bin/rm -f "$_rows"
}
