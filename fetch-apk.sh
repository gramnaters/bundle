#!/bin/bash
# ============================================================
#  fetch-apk.sh v5.0 — JioHotstar APK Downloader
#
#  PRIMARY:   dietdroid.com curl proxy (no auth, no Python)
#  FALLBACK1: dietdroid.com SSE + curl (gets Google Play token)
#  FALLBACK2: apkeep Google Play (needs auth)
#  FALLBACK3: apkeep APKPure (legacy package only)
#
#  Handles split APKs: downloads base + all splits via
#  dietdroid proxy, merges using selective copy — no
#  duplicate zip entries (fixes classes.dex crash).
#
#  Usage: bash fetch-apk.sh [output_dir]
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-${SCRIPT_DIR}}"
OUTPUT_FILE="${OUTPUT_DIR}/jiohotstar_latest.apk"

# Package names
PRIMARY_PKG="in.startv.hotstar"         # Current JioHotstar
LEGACY_PKG="in.startv.hotstaronly"     # Legacy — max v26.03.30.2

# dietdroid.com API
DIETDROID_BASE="https://apkdl.dietdroid.com"
ARCH="arm64-v8a"

# Env file for CI (GitHub Actions)
ENV_FILE="${GITHUB_ENV:-}"

# Colors (safe for CI)
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; NC=''
fi

log_info()  { echo -e "${BLUE}[FETCH]${NC} $*" >&2; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Export version to CI env ────────────────────────────────
export_version() {
    local ver="$1"
    # Export to GitHub Actions env file for use in later steps
    if [ -n "$ENV_FILE" ] && [ -f "$ENV_FILE" ]; then
        echo "FETCHED_VERSION=${ver}" >> "$ENV_FILE"
    fi
    # Also export to current process env
    export FETCHED_VERSION="$ver"
}

# ── Merge split APKs (base + splits -> single APK) ──────────
# Selective merge: skip duplicate dex/manifest/resource files.
# Create FRESH zip — no duplicate zip entries possible.

merge_splits() {
    local work_dir="$1"
    local output_file="$2"

    log_info "Merging split APKs..."

    # Find base APK (largest file — typically 70-80MB)
    local base_apk=""
    local base_size=0
    for apk in "$work_dir"/*.apk; do
        [ ! -f "$apk" ] && continue
        local sz
        sz=$(stat -c%s "$apk" 2>/dev/null || echo 0)
        if [ "$sz" -gt "$base_size" ]; then
            base_size=$sz
            base_apk="$apk"
        fi
    done

    if [ -z "$base_apk" ]; then
        log_error "No APK found in work dir!"
        return 1
    fi

    log_info "  Base APK: $(basename "$base_apk") ($(du -h "$base_apk" | cut -f1))"

    # Extract base APK fully
    local base_dir="$work_dir/base_extracted"
    mkdir -p "$base_dir"
    # Redirect unzip output to stderr — must NOT leak to stdout
    # (stdout is captured by caller for file path + version parsing)
    (cd "$base_dir" && unzip -o "$base_apk" 2>&1 | tail -3 >&2)

    # Process each split APK (non-base)
    for apk in "$work_dir"/*.apk; do
        [ ! -f "$apk" ] && continue
        [ "$apk" = "$base_apk" ] && continue

        local split_name
        split_name=$(basename "$apk")
        log_info "  Merging split: $split_name"

        local split_dir="$work_dir/split_${split_name%.apk}"
        mkdir -p "$split_dir"
        (cd "$split_dir" && unzip -o "$apk" 2>&1 | tail -1 >&2)

        # Selective merge — skip files that create duplicates
        # Note: || true prevents pipefail from killing the subshell
        # (find | while read returns 1 on EOF, which pipefail propagates)
        (
            cd "$split_dir"
            find . -type f 2>/dev/null | while read -r file; do
                local dest="$base_dir/$file"
                local bname
                bname=$(basename "$file")

                case "$bname" in
                    classes*.dex)
                        if [ -f "$dest" ]; then
                            local src_sz dst_sz
                            src_sz=$(stat -c%s "$file" 2>/dev/null || echo 0)
                            dst_sz=$(stat -c%s "$dest" 2>/dev/null || echo 0)
                            if [ "$src_sz" = "$dst_sz" ]; then
                                continue  # Identical dex — skip
                            fi
                            # Different dex — rename to avoid collision
                            local ctr=2
                            while [ -f "$base_dir/$(dirname "$file")/classes${ctr}.dex" ]; do
                                ctr=$((ctr + 1))
                            done
                            mkdir -p "$(dirname "$dest")"
                            cp "$file" "$base_dir/$(dirname "$file")/classes${ctr}.dex" 2>/dev/null || true
                        else
                            mkdir -p "$(dirname "$dest")"
                            cp "$file" "$dest" 2>/dev/null || true
                        fi
                        ;;
                    AndroidManifest.xml|resources.arsc)
                        continue  # Keep base version
                        ;;
                    *.SF|*.RSA|*.MF|MANIFEST.MF)
                        continue  # Skip signing files
                        ;;
                    *)
                        mkdir -p "$(dirname "$dest")"
                        cp -f "$file" "$dest" 2>/dev/null || true
                        ;;
                esac
            done
        ) || true
    done

    # Remove signing metadata (will be re-signed by patch.sh)
    rm -rf "$base_dir/META-INF" 2>/dev/null || true

    # Create FRESH zip (no duplicate entries possible)
    log_info "  Repacking merged APK..."
    rm -f "$output_file"
    (cd "$base_dir" && zip -r -q "$output_file" . 2>&1 >/dev/null)

    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        log_error "  Failed to create merged APK!"
        return 1
    fi

    log_ok "  Merged APK: $(du -h "$output_file" | cut -f1)"
    return 0
}

# ── Strategy 1: dietdroid.com curl proxy (PRIMARY) ──────────
# Downloads base APK + split APKs via the site's proxy endpoint.
# No authentication, no Python, pure curl.

fetch_from_dietdroid_proxy() {
    local pkg="$1"
    local output_dir="$2"
    local output_file="$output_dir/jiohotstar_latest.apk"

    log_info "=== Strategy 1: dietdroid.com proxy (${pkg}) ==="

    # Step 1: Get app info (version, split count)
    local info_resp
    info_resp=$(curl -sS --max-time 30 \
        "${DIETDROID_BASE}/api/info/${pkg}" 2>/dev/null) || {
        log_warn "  Cannot reach dietdroid.com"
        return 1
    }

    # Info API returns: developer, package, playStoreUrl, title
    local title=""
    title=$(echo "$info_resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('title',''))" 2>/dev/null || echo "")

    if [ -z "$title" ]; then
        log_warn "  App not found on dietdroid.com"
        return 1
    fi

    log_info "  Found: ${title} (downloading...)"

    # Step 2: Create temp dir for downloads
    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Step 3: Download base APK via proxy
    local base_url="${DIETDROID_BASE}/download/${pkg}?arch=${ARCH}"
    log_info "  Downloading base APK..."
    if ! curl -sS -L --max-time 600 -o "${tmp_dir}/base.apk" "$base_url" 2>&1; then
        log_warn "  Base APK download failed"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Verify base APK
    local base_size
    base_size=$(stat -c%s "${tmp_dir}/base.apk" 2>/dev/null || echo 0)
    if [ "$base_size" -lt 1000000 ]; then
        log_warn "  Base APK too small (${base_size} bytes) — likely an error page"
        rm -rf "$tmp_dir"
        return 1
    fi

    log_ok "  Base APK: $(du -h "${tmp_dir}/base.apk" | cut -f1)"

    # Step 4: Download split APKs using SSE API to discover available splits
    # This avoids blindly downloading splits 0-9 which wastes ~550MB
    # (splits 3+ are duplicate base APKs returned by the server)
    local split_count=0

    # Try to get split info from SSE stream (parse JSON with Python, not regex)
    # The SSE line is ~2.6KB with Google Play tokens — grep regex fails on it
    local sse_split_data
    sse_split_data=$(timeout 20 curl -sS -N --max-time 15 "${DIETDROID_BASE}/api/download-info-stream/${pkg}?arch=${ARCH}" 2>/dev/null \
        | timeout 10 python3 -c "
import sys, json
for line in sys.stdin:
    if line.startswith('data: '):
        try:
            d = json.loads(line[6:])
            splits = d.get('splits', [])
            if splits:
                print(f'SPLIT_COUNT={len(splits)}')
                for s in splits:
                    print(f\"SPLIT|{s.get('name','')}|{s.get('downloadUrl','')}|{s.get('size',0)}\")
        except:
            pass
" 2>/dev/null) || true

    if echo "$sse_split_data" | grep -q 'SPLIT|'; then
        # SSE gave us split info — download only listed splits
        log_info "  SSE: splits available, downloading selective splits"
        while IFS='|' read -r prefix split_name split_url split_size; do
            [ "$prefix" != "SPLIT" ] && continue
            [ -z "$split_url" ] && continue
            local safe_name
            safe_name=$(echo "$split_name" | tr '/' '_')
            local out_path="${tmp_dir}/split_${safe_name}.apk"

            log_info "  Downloading: ${split_name} ($(( split_size / 1024 / 1024 ))MB)..."
            if curl -sS -L --max-time 300 -o "$out_path" "$split_url" 2>&1; then
                local dl_size
                dl_size=$(stat -c%s "$out_path" 2>/dev/null || echo 0)
                if [ "$dl_size" -gt 10000 ]; then
                    log_ok "  ${split_name}: $(du -h "$out_path" | cut -f1)"
                    split_count=$((split_count + 1))
                else
                    rm -f "$out_path"
                fi
            else
                log_warn "  ${split_name}: download failed"
                rm -f "$out_path"
            fi
        done <<< "$sse_split_data"
    fi

    # Fallback: if SSE didn't provide splits, try numbered splits 0-3 only
    if [ "$split_count" -eq 0 ]; then
        log_info "  SSE splits not available, trying numbered splits 0-3..."
        local base_size_bytes
        base_size_bytes=$(stat -c%s "${tmp_dir}/base.apk" 2>/dev/null || echo 0)
        for i in $(seq 0 3); do
            local split_url="${DIETDROID_BASE}/download/${pkg}/${i}?arch=${ARCH}"
            local http_code
            http_code=$(curl -sS -o "${tmp_dir}/split_${i}.apk" -w "%{http_code}" --max-time 300 -L "$split_url" 2>/dev/null) || true

            if [ "$http_code" = "200" ]; then
                local split_size
                split_size=$(stat -c%s "${tmp_dir}/split_${i}.apk" 2>/dev/null || echo 0)
                # Skip if same size as base (duplicate base APK)
                if [ "$split_size" -gt 10000 ] && [ "$split_size" -ne "$base_size_bytes" ]; then
                    log_ok "  Split ${i}: $(du -h "${tmp_dir}/split_${i}.apk" | cut -f1)"
                    split_count=$((split_count + 1))
                else
                    rm -f "${tmp_dir}/split_${i}.apk"
                    [ "$split_size" -eq "$base_size_bytes" ] && log_info "  Split ${i}: same as base (${split_size}B), skipping"
                fi
            else
                rm -f "${tmp_dir}/split_${i}.apk" 2>/dev/null || true
                break
            fi
        done
    fi

    log_info "  Total splits downloaded: ${split_count}"

    # Step 5: If we have splits, merge them with base
    local final_apk="${tmp_dir}/base.apk"
    if [ "$split_count" -gt 0 ]; then
        if ! merge_splits "$tmp_dir" "${tmp_dir}/merged.apk"; then
            log_error "  Split merge failed!"
            rm -rf "$tmp_dir"
            return 1
        fi
        final_apk="${tmp_dir}/merged.apk"
    fi

    # Copy to output location
    cp -f "$final_apk" "$output_file"
    rm -rf "$tmp_dir"

    # Verify
    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        log_error "  Output file missing!"
        return 1
    fi

    # Get version from SSE stream (fast, reliable — returns immediately)
    # Use Python JSON parser since SSE data is valid JSON with long tokens
    local version=""
    local sse_ver
    sse_ver=$(timeout 20 curl -sS -N --max-time 15 "${DIETDROID_BASE}/api/download-info-stream/${pkg}?arch=${ARCH}" 2>/dev/null \
        | timeout 10 python3 -c "
import sys, json
for line in sys.stdin:
    if 'version' in line and line.startswith('data: '):
        try:
            d = json.loads(line[6:])
            print(d.get('version', ''))
        except:
            pass
        break
" 2>/dev/null) || true
    [ -n "$sse_ver" ] && version="$sse_ver"

    # Also try to extract version from APK binary
    if [ -z "$version" ]; then
        version=$(unzip -p "$output_file" AndroidManifest.xml 2>/dev/null \
            | strings 2>/dev/null \
            | grep -oP '\d+\.\d+\.\d+\.\d+' \
            | head -1) || true
    fi

    local ver_display=""
    [ -n "$version" ] && ver_display=" v${version}"
    log_ok "  Downloaded: $(du -h "$output_file" | cut -f1)${ver_display}"

    # Export version
    export_version "${version:-unknown}"

    echo "$output_file"
    echo "${version:-unknown}"
    return 0
}

# ── Strategy 2: dietdroid.com SSE stream (gets Google Play URL) ──────
# Uses SSE to get Google Play download token, then downloads with curl.

fetch_from_dietdroid_sse() {
    local pkg="$1"
    local output_dir="$2"
    local output_file="$output_dir/jiohotstar_latest.apk"

    log_info "=== Strategy 2: dietdroid.com SSE (${pkg}) ==="

    if ! command -v python3 >/dev/null 2>&1; then
        return 1
    fi
    python3 -c "import requests" 2>/dev/null || return 1

    # Write a temporary Python script (avoids heredoc variable issues)
    local py_script
    py_script=$(mktemp --suffix=.py)

    cat > "$py_script" << 'PYEOF'
import requests, json, sys, os, subprocess

base = sys.argv[1]
pkg = sys.argv[2]
output = sys.argv[3]

headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Accept': 'text/event-stream',
    'Origin': base,
    'Referer': base + '/',
}

try:
    resp = requests.get(f"{base}/api/download-info-stream/{pkg}?arch=arm64-v8a", headers=headers, timeout=120, stream=True)
    if resp.status_code != 200:
        print(f"ERROR:{resp.status_code}")
        sys.exit(1)

    file_url = None
    version = None

    for line in resp.iter_lines(decode_unicode=True):
        if not line:
            continue
        if line.startswith('data: '):
            try:
                event = json.loads(line[6:])
                if event.get('type') == 'success':
                    file_url = event.get('downloadUrl', '')
                    version = event.get('version', '')
                    break
                elif event.get('type') == 'error':
                    print(f"ERROR:{event.get('message', 'unknown')}")
                    sys.exit(1)
            except json.JSONDecodeError:
                pass
    resp.close()

    if not file_url:
        print("ERROR:no download url")
        sys.exit(1)

    print(f"VERSION:{version}")
    print(f"URL:{file_url}")
    sys.exit(0)

except Exception as e:
    print(f"ERROR:{e}")
    sys.exit(1)
PYEOF

    local sse_result
    sse_result=$(python3 "$py_script" "$DIETDROID_BASE" "$pkg" "$output_file" 2>/dev/null) || {
        local rc=$?
        log_warn "  SSE stream failed (rc=${rc})"
        rm -f "$py_script"
        return 1
    }
    rm -f "$py_script"

    # Parse result
    local version=""
    local download_url=""

    while IFS= read -r line; do
        case "$line" in
            VERSION:*)  version="${line#VERSION:}" ;;
            URL:*)      download_url="${line#URL:}" ;;
            ERROR:*)    log_warn "  SSE error: ${line#ERROR:}"; return 1 ;;
        esac
    done <<< "$sse_result"

    if [ -z "$download_url" ]; then
        log_warn "  No download URL from SSE"
        return 1
    fi

    # Download the APK using curl
    log_info "  Downloading from Google Play CDN..."
    curl -sS -L --max-time 600 -o "$output_file" "$download_url" 2>&1 || {
        log_warn "  Download failed"
        rm -f "$output_file"
        return 1
    }

    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        log_warn "  Downloaded file missing or empty"
        rm -f "$output_file"
        return 1
    fi

    local fsize
    fsize=$(stat -c%s "$output_file" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 1000000 ]; then
        log_warn "  File too small (${fsize} bytes)"
        rm -f "$output_file"
        return 1
    fi

    log_ok "  Downloaded: $(du -h "$output_file" | cut -f1) v${version}"

    # Export version
    export_version "${version:-unknown}"

    echo "$output_file"
    echo "${version:-unknown}"
    return 0
}

# ── Merge XAPK bundle (for files downloaded as .xapk) ────────────────

merge_xapk_safely() {
    local xapk_file="$1"
    local output_file="$2"

    if [ ! -f "$xapk_file" ]; then
        log_error "XAPK not found: $xapk_file"
        return 1
    fi

    local work_dir
    work_dir=$(mktemp -d)

    log_info "Extracting XAPK bundle..."
    (cd "$work_dir" && unzip -o "$xapk_file" 2>&1 | tail -3 >&2)

    if ! merge_splits "$work_dir" "$output_file"; then
        rm -rf "$work_dir"
        return 1
    fi

    rm -rf "$work_dir"
    return 0
}

# ── Find or download apkeep ──────────────────────────────────────────

find_apkeep() {
    if command -v apkeep >/dev/null 2>&1; then
        echo "apkeep"
        return
    fi

    local bin="${SCRIPT_DIR}/apkeep"
    if [ ! -f "$bin" ]; then
        log_info "Downloading apkeep..."
        curl -sL -o "$bin" \
            "https://github.com/EFForg/apkeep/releases/download/0.20.0/apkeep-x86_64-unknown-linux-gnu" \
            --max-time 120 || \
        curl -sL -o "$bin" \
            "https://github.com/EFForg/apkeep/releases/download/0.18.0/apkeep-x86_64-unknown-linux-gnu" \
            --max-time 120 || true
        chmod +x "$bin" 2>/dev/null || true
    fi

    if [ -f "$bin" ]; then
        echo "$bin"
    else
        echo ""
    fi
}

# ── Strategy 3: apkeep fallback ──────────────────────────────────────

fetch_via_apkeep() {
    local pkg="$1"
    local source="$2"
    local output_dir="$3"
    local tmp_dir

    tmp_dir=$(mktemp -d)

    local apkeep_bin
    apkeep_bin=$(find_apkeep)

    if [ -z "$apkeep_bin" ]; then
        log_warn "  apkeep not available"
        rm -rf "$tmp_dir"
        return 1
    fi

    log_info "  Trying apkeep: $source / $pkg"
    (cd "$tmp_dir" && "$apkeep_bin" -a "$pkg" -d "$source" . 2>&1) || true

    local found_file=""
    for f in "$tmp_dir"/*.apk "$tmp_dir"/*.xapk; do
        if [ -f "$f" ] && [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -gt 100000 ]; then
            found_file="$f"
            break
        fi
    done

    if [ -n "$found_file" ]; then
        cp "$found_file" "${output_dir}/jiohotstar_latest.apk"
        rm -rf "$tmp_dir"
        echo "${output_dir}/jiohotstar_latest.apk"
        return 0
    fi

    rm -rf "$tmp_dir"
    return 1
}

# ── Main download logic ─────────────────────────────────────────────

main() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  JioHotstar APK Downloader v5.0        ${NC}"
    echo -e "${GREEN}  dietdroid proxy -> SSE -> apkeep       ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""

    mkdir -p "$OUTPUT_DIR"
    rm -f "$OUTPUT_FILE"

    local RESULT_FILE=""
    local RESULT_VERSION=""
    local RESULT_SOURCE=""

    # ── Strategy 1: dietdroid.com proxy (PRIMARY — pure curl) ──
    # CRITICAL: Do NOT use 2>&1 here! Logs go to stderr, function output (file path + version)
    # goes to stdout. Using 2>&1 mixes log lines with file path, breaking the parse.
    if dietdroid_output=$(fetch_from_dietdroid_proxy "$PRIMARY_PKG" "$OUTPUT_DIR"); then
        local lines=()
        while IFS= read -r line; do lines+=("$line"); done <<< "$dietdroid_output"
        RESULT_FILE="${lines[0]:-}"
        RESULT_VERSION="${lines[1]:-}"
        RESULT_SOURCE="dietdroid-proxy"
    fi

    # ── Strategy 2: dietdroid.com SSE stream ──
    if [ -z "$RESULT_FILE" ] || [ ! -f "$RESULT_FILE" ]; then
        if sse_output=$(fetch_from_dietdroid_sse "$PRIMARY_PKG" "$OUTPUT_DIR"); then
            local lines=()
            while IFS= read -r line; do lines+=("$line"); done <<< "$sse_output"
            RESULT_FILE="${lines[0]:-}"
            RESULT_VERSION="${lines[1]:-}"
            RESULT_SOURCE="dietdroid-sse"
        fi
    fi

    # ── Strategy 3: apkeep Google Play ──
    if [ -z "$RESULT_FILE" ] || [ ! -f "$RESULT_FILE" ]; then
        log_info "=== Strategy 3: apkeep Google Play (${PRIMARY_PKG}) ==="
        local apk_file
        if apk_file=$(fetch_via_apkeep "$PRIMARY_PKG" "google-play" "$OUTPUT_DIR"); then
            RESULT_FILE="$apk_file"
            RESULT_SOURCE="google-play-apkeep"
        fi
    fi

    # ── Strategy 4: apkeep APKPure (legacy) ──
    if [ -z "$RESULT_FILE" ] || [ ! -f "$RESULT_FILE" ]; then
        log_info "=== Strategy 4: apkeep APKPure (${LEGACY_PKG}) ==="
        local apk_file
        if apk_file=$(fetch_via_apkeep "$LEGACY_PKG" "apk-pure" "$OUTPUT_DIR"); then
            RESULT_FILE="$apk_file"
            RESULT_SOURCE="apkpure-legacy"
            log_warn "  Note: ${LEGACY_PKG} max version is 26.03.30.2"
        fi
    fi

    # ── All strategies failed ──
    if [ -z "$RESULT_FILE" ] || [ ! -f "$RESULT_FILE" ]; then
        log_error "ALL download strategies failed!"
        echo ""
        echo "Manual download links:"
        echo "  APKMirror: https://www.apkmirror.com/apk/jiostar-india-private-limited/hotstar-2/"
        echo "  dietdroid: https://apkdl.dietdroid.com/ (enter package: in.startv.hotstar)"
        echo ""
        echo "Place the downloaded file at: $OUTPUT_FILE"
        exit 1
    fi

    # ── Handle XAPK merge ──
    if [[ "$RESULT_FILE" == *.xapk ]]; then
        log_info "XAPK format detected — merging splits..."
        local merged_file="${OUTPUT_DIR}/.merged_temp.apk"
        if ! merge_xapk_safely "$RESULT_FILE" "$merged_file"; then
            log_error "XAPK merge failed!"
            exit 1
        fi
        rm -f "$RESULT_FILE"
        RESULT_FILE="$merged_file"
    fi

    # ── Ensure file is at the expected output path ──
    if [ "$RESULT_FILE" != "$OUTPUT_FILE" ]; then
        mv -f "$RESULT_FILE" "$OUTPUT_FILE"
    fi

    # ── Verify ──
    if [ ! -f "$OUTPUT_FILE" ] || [ ! -s "$OUTPUT_FILE" ]; then
        log_error "Output APK missing or empty!"
        exit 1
    fi

    local size
    size=$(du -h "$OUTPUT_FILE" | cut -f1)

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Download Complete!                    ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo -e "  Source:   ${CYAN}${RESULT_SOURCE}${NC}"
    echo -e "  Version:  ${CYAN}${RESULT_VERSION:-unknown}${NC}"
    echo -e "  File:     ${CYAN}${OUTPUT_FILE}${NC}"
    echo -e "  Size:     ${CYAN}${size}${NC}"
    echo ""
}

main
