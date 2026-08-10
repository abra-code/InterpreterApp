# lib.interp.models.sh - model catalog + RAM-aware curation for the Interpreter model chooser.
# Sourced by the chooser/download handlers. POSIX /bin/sh (bash 3.2). No Python: HF JSON is
# parsed with `plutil -p` + awk.
#
# The candidate set is data-driven: models.catalog.tsv lists every offered variant across all
# model FAMILIES (TranslateGemma, MiLMMT-46, ...), ranked best -> smallest within each family.
# The curation turns the machine's RAM and the live per-variant download sizes into grouped,
# outcome-framed SECTIONS - Best Quality / Recommended / Faster - with up to one card per
# family in each section, rather than exposing params/bit-width. Guiding rules: for a fixed
# memory budget, MORE PARAMETERS at modest bits beat FEWER at 8-bit, so a family's recommended
# pick is its highest-ranked variant at bits <= 6 that fits with comfortable headroom (6-bit
# earned parity with 8-bit in the quant bake-offs, so it outranks 4-bit for the same params;
# 8-bit is reserved for Best). Quant bits are never themselves the speed lever - a Faster pick
# earns its speed from fewer params, so within the smallest params class the HIGHEST quant
# that still fits comfortably wins (a 4B 8-bit translates visibly better than a 4B 4-bit at
# nearly the same speed).

[ -n "${__INTERP_MODELS_LIB:-}" ] && return 0
__INTERP_MODELS_LIB=1

INTERP_CATALOG_TSV="$OMC_APP_BUNDLE_PATH/Contents/Resources/models.catalog.tsv"

# The two substitutable binaries this library reaches for. Every handler sources
# lib.interp.sh first, which already defines both to the same thing; they are
# repeated here so that sourcing this file ALONE still yields a working library
# rather than an empty command name - the failure mode of a bare "$curl_tool"
# being a silent success with no output, which reads as an empty catalog.
: "${curl_tool:=${INTERP_CURL_TOOL:-/usr/bin/curl}}"
: "${sysctl_tool:=${INTERP_SYSCTL_TOOL:-/usr/sbin/sysctl}}"

machine_ram_bytes() { "$sysctl_tool" -n hw.memsize 2>/dev/null; }

bytes_to_gb() { /usr/bin/awk -v b="$1" 'BEGIN{ if(b+0<=0){print "?"} else printf "%.1f GB", b/1000000000 }'; }

# Human name of a model family (catalog `family` column value -> display string).
family_display_name() { case "$1" in translategemma) echo "TranslateGemma";; milmmt) echo "MiLMMT-46";; hymt) echo "Hy-MT2";; *) echo "$1";; esac; }

# One-sentence model-specific guidance for a family, shown on every curated card (prepended to
# the section rationale) and in the info sheet, so a user can pick BETWEEN families, not just
# between sizes. Grounded in 34-translation quality batteries run across the families: keep
# these claims in sync with what testing actually showed. Card fields must stay free of double
# quotes and backslashes (they are interpolated into JSON - see insert_cards).
family_blurb() {   # $1 = family
    case "$1" in
        translategemma) echo "Google's all-round translator: every app language, strongest European coverage." ;;
        milmmt)         echo "Xiaomi's translator: matches TranslateGemma on European languages, but fewer languages." ;;
        hymt)           echo "Tencent's translator: the top pick for Chinese and Japanese; for European languages prefer the other families." ;;
        *)              echo "" ;;
    esac
}

# Download size (bytes) of a repo's main revision: the whole repo, or - when $2 names a file -
# just that one file (a GGUF catalog row downloads a single quant file, not the repo). Each
# file object in the tree API reports a top-level "size" (the real size, for both LFS weights
# and small files) AND, for LFS files, a duplicate nested lfs."size" - so we count only the
# FIRST "size" per file object (reset at each array-element header `N => {`) to avoid
# double-counting the weights. Prints 0 on failure / nonexistent repo / file not in the tree.
#
# A nonexistent repo is the NORMAL case for planned-but-unpublished catalog entries, so it must
# fail FAST: --retry-all-errors would burn 3 retries x 2 s on every 404, several times per load.
# One un-retried probe classifies the repo first; only a live repo (200) proceeds to the retried
# fetch, whose --retry-all-errors still covers the transient 401/429s the HF CDN throws.
hf_repo_size_bytes() {   # $1 = author/name, $2 = optional single file path within the repo
    local _url="https://huggingface.co/api/models/$1/tree/main?recursive=true"

    # mktemp, not a $$-suffixed name: interp_fetch_catalog runs these probes in parallel
    # subshells, which all share the parent's $$ and would clobber one body file.
    local _body=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/interp.tree.XXXXXX") || { echo 0; return 0; }
    # Timeouts are deliberately tight (8 s connect / 20 s total, one short retry round): the
    # chooser blocks its card list on the slowest probe, so on a bad network fast-missing beats
    # slow-complete - a missed row just omits a card until Refresh.
    local _code=$("$curl_tool" -sSL -o "$_body" -w '%{http_code}' --connect-timeout 8 --max-time 20 \
        "$_url" 2>/dev/null)
    case "$_code" in
        200) ;;   # got the tree in one shot - parse it below
        404|403)
            # Repo absent (or gated): a definitive no.
            /bin/rm -f "$_body"; echo 0; return 0 ;;
        *)
            # Transient (429/5xx/network, code 000): retry properly.
            "$curl_tool" -fsSL -o "$_body" --connect-timeout 8 --max-time 30 \
                --retry 2 --retry-delay 1 --retry-all-errors "$_url" 2>/dev/null \
                || { /bin/rm -f "$_body"; echo 0; return 0; } ;;
    esac
    # Per-object accumulate-then-flush (same pattern as the download worker's enumeration):
    # plutil prints keys ALPHABETICALLY, so an LFS object's nested lfs."size" precedes its
    # "path" - a match-as-you-stream filter would miss every LFS file. Collect each object's
    # first "size" and its "path", and only decide at the object boundary.
    # Only "file" objects count (a directory whose path matched $2 would otherwise satisfy the
    # single-file filter) - same type gate as the download worker's enumeration.
    /usr/bin/plutil -p "$_body" 2>/dev/null \
        | /usr/bin/awk -v want="${2:-}" '
            function flush() { if (started && t == "file" && (want == "" || p == want)) tot += sz }
            /^[[:space:]]*[0-9]+ => \{/ { flush(); started=1; sz=0; counted=0; p=""; t="" }
            /"path" =>/ { v=$0; sub(/.*"path" => "/,"",v); sub(/".*/,"",v); p=v }
            /"type" =>/ { v=$0; sub(/.*"type" => "/,"",v); sub(/".*/,"",v); t=v }
            /"size" =>/ { if (!counted) { n=$3; gsub(/[^0-9]/,"",n); sz=n; counted=1 } }
            END { flush(); print tot+0 }'
    /bin/rm -f "$_body"
}

# Fetch each catalog variant's size into a cache file (existing repos only):
#   family <TAB> author <TAB> repo <TAB> params <TAB> bits <TAB> size_bytes
# A repo the API does not know (a planned-but-unpublished conversion) is skipped silently.
# Succeeds (0) if at least one variant exists.
#
# The per-repo probes run in PARALLEL subshells (each writing its own .part file, reassembled
# in catalog order afterwards): sequentially, the chooser's blank time was the SUM of the
# probes - ~1.5 s when the network is good, but a single flaky probe (timeout/retry, up to
# ~30 s) stalled everything behind it. In parallel the wall time is one probe, worst case one
# slow one. Each subshell does one small curl + awk; with a catalog of ~10 rows the process
# burst is trivial.
interp_fetch_catalog() {   # $1 = output cache file
    local _out="$1" _tab=$(/usr/bin/printf '\t')
    local _fam _auth _name _par _bits _eng _gf _i=0 _n
    /bin/rm -f "$_out" "$_out".*.part 2>/dev/null
    : > "$_out"
    # Columns 6/7 (engine, gguf_file) are optional - a 5-column mlx row reads them as empty. A
    # gguf row prices ONLY its named quant file (that is all the worker downloads); the cache
    # keeps the original 6-column shape because nothing downstream needs the engine - installs
    # are engine-detected by shape, and the worker re-reads the catalog for the file name.
    while IFS="$_tab" read -r _fam _auth _name _par _bits _eng _gf; do
        case "$_fam" in ''|'#'*) continue ;; esac
        [ -n "$_auth" ] && [ -n "$_name" ] || continue
        [ "$_eng" = gguf ] || _gf=""
        _i=$((_i + 1))
        (
            # A gguf_file of the form "repo/file.gguf" prices that file in THAT repo (col 3 is
            # then just the install name); without a "/" the row's own name column is the repo.
            # A malformed "Repo/" (empty file component) yields NO card - pricing the whole repo
            # would show a plausible size for a row whose download must then fail.
            _repo="$_auth/$_name"
            case "$_gf" in
                */*) _repo="$_auth/${_gf%%/*}"; _gf="${_gf#*/}"
                     [ -n "$_gf" ] || exit 0 ;;
            esac
            _sz=$(hf_repo_size_bytes "$_repo" "$_gf")
            [ -n "$_sz" ] && [ "$_sz" -gt 0 ] 2>/dev/null || exit 0
            /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$_fam" "$_auth" "$_name" "$_par" "$_bits" "$_sz" > "$_out.$_i.part"
        ) &
    done < "$INTERP_CATALOG_TSV"
    wait
    _n=$_i
    _i=0
    while [ "$_i" -lt "$_n" ]; do
        _i=$((_i + 1))
        [ -f "$_out.$_i.part" ] || continue
        /bin/cat "$_out.$_i.part" >> "$_out"
        /bin/rm -f "$_out.$_i.part"
    done
    [ -s "$_out" ]
}

# Curate the cached catalog for this machine's RAM. Emits, tab-separated, one row per CARD:
#   section <TAB> family <TAB> author <TAB> repo <TAB> label <TAB> size_bytes <TAB> heavy(1/0) <TAB> description
# section in {best,recommended,faster}, rows grouped by section in that order; within a
# section, catalog family order. Each family contributes at most one card per section, and a
# variant appears in exactly one section. Fewer offerable variants yield fewer rows; a family
# with nothing offerable contributes none.
#
# Memory model (all vs hw.memsize R): estimated peak = weights*1.15 + 1.5 GB (short-context
# KV/activations + runtime). OFFER if peak <= 92% R (it will load - below mlx-agent's 0.90
# weights gate - and leave the OS room). HEAVY (a caveat, still offered) if peak > 70% R.
# COMFORTABLE (eligible to be a recommended pick) if peak <= 55% R. Per family (variants in
# catalog order = best first): recommended = first comfortable 4-bit, else the second
# offerable (or the only one); best = the first offerable when it is not the recommended
# pick; faster = within the smallest-params offerable class, the first (= highest-quant)
# comfortable variant, else that class's smallest - when not already used.
interp_curate_models() {   # $1 = cache file from interp_fetch_catalog
    local _cache="$1" _tab=$(/usr/bin/printf '\t')
    local _sec _idx _heavy _fam _auth _repo _par _bits _size _desc _famdisp _blurb
    [ -s "$_cache" ] || return 1
    local _ram=$(machine_ram_bytes); [ "$_ram" -gt 0 ] 2>/dev/null || return 1

    # Per-process side channel for the awk-emitted ROW records: two concurrent curations (a fast
    # double-Refresh, or a reopen mid-load) would otherwise both write and read this one fixed
    # file and see each other's truncated rows.
    local _rows="${_cache}.$$.rows"

    /usr/bin/awk -F'\t' -v ram="$_ram" '
        function peak(sz) { return sz*1.15 + 1500000000 }
        { fam[NR]=$1; auth[NR]=$2; name[NR]=$3; par[NR]=$4; bits[NR]=$5; size[NR]=$6; N=NR
          if (!($1 in famseen)) { famseen[$1]=1; forder[++nfam]=$1 } }
        END {
            offer_ceil = ram*0.92; comfy_ceil = ram*0.55; heavy_floor = ram*0.70
            nout = 0
            for (f=1; f<=nfam; f++) {
                fname = forder[f]
                cnt = 0
                for (i=1; i<=N; i++) if (fam[i]==fname && peak(size[i]) <= offer_ceil) { cnt++; fit[cnt]=i }
                if (cnt==0) continue
                # Recommended = the highest-quality COMFORTABLE variant at bits <= 6 (catalog
                # order is the quality ranking, so first match wins). 6-bit is eligible because
                # the quant bake-offs showed it quality-indistinguishable from 8-bit at ~3/4 the
                # size; 8-bit stays Best-only so the two sections keep distinct meanings.
                # PARAMS FLOOR, ratio-bounded: dropping ONE params class below the second-best
                # offerable is fine - that is the Recommended slot doing its job as the fast
                # daily driver (a 27B is really much slower than a 12B; user-confirmed) - but
                # collapsing further (12B -> 4B is 3x fewer params) loses too much quality, so
                # a drop past 2.5x clamps back to the second-best offerable even though it sits
                # slightly over the comfort line. 2.5 divides the catalog class ratios (2.25 for
                # 27->12, 3+ for 12->4 and 7->1.8).
                rec = 0
                for (k=1; k<=cnt; k++) { i=fit[k]; if (bits[i]+0 <= 6 && peak(size[i]) <= comfy_ceil) { rec=i; break } }
                if (rec != 0 && cnt >= 2 && par[fit[2]] + 0 > 2.5 * (par[rec] + 0)) rec = fit[2]
                if (rec==0) rec = (cnt>=2 ? fit[2] : fit[1])
                best = (fit[1]!=rec ? fit[1] : 0)
                # Faster gets its speed from FEWER PARAMS, not fewer bits: within the
                # smallest-params offerable class take the first (= highest-quant, by catalog
                # order) variant that is still comfortable, falling back to the class smallest
                # only when nothing in it is comfortable.
                minpar = par[fit[1]] + 0
                for (k=2; k<=cnt; k++) if (par[fit[k]] + 0 < minpar) minpar = par[fit[k]] + 0
                fast = 0; fclass = 0
                for (k=1; k<=cnt; k++) { i=fit[k]; if (par[i] + 0 == minpar) { fclass=i; if (fast==0 && peak(size[i]) <= comfy_ceil) fast=i } }
                if (fast==0) fast = fclass
                if (fast==rec || fast==best) fast = 0
                if (best) { nout++; osec[nout]="best"; oidx[nout]=best }
                nout++; osec[nout]="recommended"; oidx[nout]=rec
                if (fast) { nout++; osec[nout]="faster"; oidx[nout]=fast }
            }
            if (nout==0) exit 1
            ns = split("best recommended faster", secs, " ")
            for (s=1; s<=ns; s++)
                for (o=1; o<=nout; o++)
                    if (osec[o]==secs[s]) {
                        i = oidx[o]
                        print secs[s] "\t" i "\t" ((peak(size[i]) > heavy_floor) ? 1 : 0)
                    }
            for (i=1; i<=N; i++) print "ROW\t" i "\t" fam[i] "\t" auth[i] "\t" name[i] "\t" par[i] "\t" bits[i] "\t" size[i] > "/dev/stderr"
        }
    ' "$_cache" 2>"$_rows" | while IFS="$_tab" read -r _sec _idx _heavy; do
        _fam=$(/usr/bin/awk -F'\t' -v i="$_idx" '$1=="ROW" && $2==i {print $3; exit}' "$_rows")
        _auth=$(/usr/bin/awk -F'\t' -v i="$_idx" '$1=="ROW" && $2==i {print $4; exit}' "$_rows")
        _repo=$(/usr/bin/awk -F'\t' -v i="$_idx" '$1=="ROW" && $2==i {print $5; exit}' "$_rows")
        _par=$(/usr/bin/awk -F'\t' -v i="$_idx" '$1=="ROW" && $2==i {print $6; exit}' "$_rows")
        _bits=$(/usr/bin/awk -F'\t' -v i="$_idx" '$1=="ROW" && $2==i {print $7; exit}' "$_rows")
        _size=$(/usr/bin/awk -F'\t' -v i="$_idx" '$1=="ROW" && $2==i {print $8; exit}' "$_rows")
        _famdisp=$(family_display_name "$_fam")
        # The card description is the family blurb ALONE: the section rationale ("Highest
        # quality, but...") is stated once under each section header in models.window.json
        # (ids 1103/1203/1303), not repeated on every card; the Heavy badge plus the Best
        # section's subtitle carry the memory caveat.
        _desc=$(family_blurb "$_fam")
        /usr/bin/printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$_sec" "$_fam" "$_auth" "$_repo" "$_famdisp ${_par}B (${_bits}-bit)" "$_size" "$_heavy" "$_desc"
    done
    /bin/rm -f "$_rows"
}

# True when the download worker recorded in a work dir is still running. The spawner writes the
# worker's pid to worker.pid; argv is re-verified so a recycled pid is never mistaken for a live
# worker. A missing/invalid pid file counts as dead - which also classifies work dirs from
# before this file existed as resumable, exactly right.
download_worker_alive() {   # $1 = work dir
    local _pid=$(/bin/cat "$1/worker.pid" 2>/dev/null)
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    # The pattern is derived from the spawned script rather than hardcoded, so a
    # substituted worker (the test seam) and this check cannot disagree about
    # what a live download looks like.
    local _leaf="$(/usr/bin/basename "${DOWNLOAD_WORKER_SCRIPT:-interp.download.worker.sh}")"
    case "$(/bin/ps -p "$_pid" -o args= 2>/dev/null)" in
        *"$_leaf"*) return 0 ;;
    esac
    return 1
}

# Look up one curated card row by its 1-based row number. Prints the row (8 tab-separated
# fields) or nothing. Card view ids encode this row number - see interp_card_base_id.
# INVARIANT: interp_curate_models emits exactly one non-empty line per card, so the row number
# the card builders/pollers count equals the raw line number this sed uses. Anything that adds
# blank/comment lines to curated.tsv must also teach this lookup to skip them.
curated_row() {   # $1 = curated tsv, $2 = 1-based row
    case "$2" in ''|*[!0-9]*) return 0 ;; esac
    /usr/bin/sed -n "${2}p" "$1"
}

# The chooser builds one card per curated row at runtime (omc_insert_element); all of a
# card's view ids derive from its row number so handlers can reverse-map a trigger id:
#   base = 2000 + row*10 ; title=base+1 badge=base+2 desc=base+3 size=base+4
#   download-button=base+5 info-button=base+6
interp_card_base_id() { echo $(( 2000 + $1 * 10 )); }
interp_card_row_of_id() { echo $(( ($1 - 2000) / 10 )); }
