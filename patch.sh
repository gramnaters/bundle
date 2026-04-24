#!/bin/bash
# ============================================================
#  patch.sh - JioHotstar CookieSeeder Patcher v5.0
#  Architecture: DataStore Seed + Native Refresh Pipeline
#
#  v5.0 CHANGES:
#    - Fixed apksigner/zipalign PATH detection (no subshell leak)
#    - Proper GITHUB_ENV support
#    - Works with standard APK and XAPK bundles
#    - Verified XAPK merge: selective copy, fresh zip, no dupes
#
#  Usage: bash patch.sh [path/to/base.apk]
# ============================================================

set -euo pipefail

# ===================== CONFIGURATION =====================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
WORK_DIR="${BUILD_DIR}/work"
DECOMPILED_DIR="${WORK_DIR}/decompiled"
PATCHED_APK="${BUILD_DIR}/jiohotstar_patched.apk"
KEYSTORE="${BUILD_DIR}/sign.keystore"
KEYSTORE_PASS="hotstarpatch"
KEY_ALIAS="hotstar"
BASE_APK="${1:-}"

# Colors (disabled in non-TTY / CI environments)
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# ===================== FUNCTIONS =====================

log_info()  { echo -e "${BLUE}[PATCH]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

banner() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  JioHotstar CookieSeeder Patcher v5.0  ${NC}"
    echo -e "${GREEN}  DataStore Seed + Native Refresh       ${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

check_dependencies() {
    log_info "Checking dependencies..."

    local missing=()
    command -v java >/dev/null 2>&1 || missing+=("java")
    command -v apktool >/dev/null 2>&1 || missing+=("apktool")
    command -v sed >/dev/null 2>&1 || missing+=("sed")
    command -v unzip >/dev/null 2>&1 || missing+=("unzip")
    command -v zip >/dev/null 2>&1 || missing+=("zip")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    # apksigner: check common locations (GH Actions, Android SDK, system)
    # Fix: avoid subshell pipeline so PATH export persists
    if command -v apksigner >/dev/null 2>&1; then
        : # found in PATH
    else
        local _apksigner_path=""
        if [ -n "${ANDROID_HOME:-}" ]; then
            _apksigner_path=$(find "$ANDROID_HOME/build-tools" -name apksigner -type f 2>/dev/null | sort -V | tail -1 || true)
        fi
        if [ -n "$_apksigner_path" ]; then
            export PATH="$(dirname "$_apksigner_path"):$PATH"
            log_info "  Found apksigner at: $_apksigner_path"
        else
            missing+=("apksigner")
        fi
    fi

    # zipalign: same approach
    if command -v zipalign >/dev/null 2>&1; then
        : # found in PATH
    else
        local _zipalign_path=""
        if [ -n "${ANDROID_HOME:-}" ]; then
            _zipalign_path=$(find "$ANDROID_HOME/build-tools" -name zipalign -type f 2>/dev/null | sort -V | tail -1 || true)
        fi
        if [ -n "$_zipalign_path" ]; then
            export PATH="$(dirname "$_zipalign_path"):$PATH"
            log_info "  Found zipalign at: $_zipalign_path"
        else
            missing+=("zipalign")
        fi
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        echo "Install: sudo apt-get install default-jdk sed unzip zip python3"
        echo "Android SDK build-tools for apksigner/zipalign"
        echo "  export ANDROID_HOME=/path/to/android-sdk"
        exit 1
    fi

    log_ok "All dependencies available"
    log_info "  apksigner: $(command -v apksigner)"
    log_info "  zipalign:  $(command -v zipalign)"
}

parse_cookie_json() {
    local cookies_json="${SCRIPT_DIR}/cookies.json"
    local cookies_dir="${SCRIPT_DIR}/cookies"

    if [ ! -f "$cookies_json" ]; then
        return
    fi

    log_info "Found cookies.json - auto-parsing..."
    mkdir -p "$cookies_dir"

    python3 -c "
import json, sys, os
try:
    data = json.load(open('${cookies_json}'))
    if not isinstance(data, list):
        print('ERROR: cookies.json must be a JSON array', file=sys.stderr)
        sys.exit(1)
    os.makedirs('${cookies_dir}', exist_ok=True)
    for c in data:
        name = c.get('name', '')
        value = c.get('value', '').strip()
        if name == 'sessionUserUP' and value:
            open('${cookies_dir}/sessionUserUP.txt', 'w').write(value)
            print(f'  sessionUserUP.txt -> {len(value)} chars')
        elif name == 'userUP' and value and not os.path.exists('${cookies_dir}/sessionUserUP.txt'):
            open('${cookies_dir}/sessionUserUP.txt', 'w').write(value)
            print(f'  sessionUserUP.txt -> {len(value)} chars (from userUP)')
        elif name == 'userHID' and value:
            open('${cookies_dir}/userHID.txt', 'w').write(value)
            print(f'  userHID.txt -> {len(value)} chars')
        elif name == 'userPID' and value:
            open('${cookies_dir}/userPID.txt', 'w').write(value)
            print(f'  userPID.txt -> {len(value)} chars')
        elif name == 'deviceId' and value:
            open('${cookies_dir}/deviceId.txt', 'w').write(value)
            print(f'  deviceId.txt -> {len(value)} chars')
        elif name == 'media_token' and value:
            open('${cookies_dir}/media_token.txt', 'w').write(value)
            print(f'  media_token.txt -> {len(value)} chars')
    if not os.path.exists('${cookies_dir}/media_token.txt'):
        open('${cookies_dir}/media_token.txt', 'w').write('')
        print('  media_token.txt -> (empty)')
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
"

    log_ok "Cookie JSON parsed"
}

validate_cookies() {
    log_info "Validating cookie files..."

    local cookies_dir="${SCRIPT_DIR}/cookies"
    local required_files=("sessionUserUP.txt" "userHID.txt" "userPID.txt" "deviceId.txt")
    local missing=()
    local empty=()

    for file in "${required_files[@]}"; do
        local filepath="${cookies_dir}/${file}"
        if [ ! -f "$filepath" ]; then
            missing+=("$file")
        elif [ ! -s "$filepath" ]; then
            empty+=("$file")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing cookie files: ${missing[*]}"
        echo ""
        echo "Place cookies.json in ${SCRIPT_DIR}/ or create files in ${cookies_dir}/"
        echo "  sessionUserUP.txt  <- JWT token"
        echo "  userHID.txt        <- Hotstar ID"
        echo "  userPID.txt        <- Partner ID"
        echo "  deviceId.txt       <- Device ID"
        echo ""
        exit 1
    fi

    if [ ${#empty[@]} -ne 0 ]; then
        log_error "Empty cookie files: ${empty[*]}"
        exit 1
    fi

    # Handle optional media_token
    if [ ! -f "${cookies_dir}/media_token.txt" ] || [ ! -s "${cookies_dir}/media_token.txt" ]; then
        log_warn "media_token.txt empty - app will get from API"
        printf '' > "${cookies_dir}/media_token.txt"
    fi

    log_ok "All cookie files valid"
}

find_base_apk() {
    # If BASE_APK is a directory (e.g. "." passed as arg), clear it
    if [ -n "$BASE_APK" ] && [ -d "$BASE_APK" ]; then
        BASE_APK=""
    fi

    if [ -z "$BASE_APK" ]; then
        for candidate in \
            "${SCRIPT_DIR}/jiohotstar_latest.apk" \
            "${SCRIPT_DIR}/base.apk" \
            "${SCRIPT_DIR}/jiohotstar.apk" \
            "${BUILD_DIR}/jiohotstar_latest.apk"; do
            if [ -f "$candidate" ]; then
                BASE_APK="$candidate"
                log_info "Found base APK: $BASE_APK"
                return
            fi
        done

        log_error "No base APK found!"
        echo "Place the JioHotstar APK at: ${SCRIPT_DIR}/jiohotstar_latest.apk"
        exit 1
    fi

    if [ ! -f "$BASE_APK" ]; then
        log_error "APK not found: $BASE_APK"
        exit 1
    fi

    log_info "Using base APK: $BASE_APK ($(du -h "$BASE_APK" | cut -f1))"
}

# ── XAPK / Split APK handler (v5.0: SAFE merge) ─────────────────────────
# Key fix: Use SELECTIVE merge instead of blind cp -r
# Skip duplicate files (classes.dex, AndroidManifest.xml, resources.arsc)
# Create FRESH zip instead of appending to existing

handle_xapk() {
    local apk_path="$1"

    # Check if it's an XAPK (contains manifest.json with xapk_version)
    if ! unzip -l "$apk_path" 2>/dev/null | grep -q "manifest.json"; then
        log_info "Format: standard APK (no XAPK manifest)"
        return
    fi

    local manifest
    manifest=$(unzip -p "$apk_path" "manifest.json" 2>/dev/null | head -c 500) || true

    if ! echo "$manifest" | grep -q "xapk_version\|package_name"; then
        log_info "Format: standard APK (manifest.json not XAPK format)"
        return
    fi

    log_info "Format: XAPK bundle — extracting and merging splits..."

    local merge_dir="${WORK_DIR}/xapk_safe_merge"
    rm -rf "$merge_dir"
    mkdir -p "$merge_dir"

    # Step 1: Extract entire XAPK to inspect contents
    log_info "  Step 1: Extracting XAPK archive..."
    (cd "$merge_dir" && unzip -o "$apk_path" 2>&1 | tail -3 >&2)

    # Step 2: Find base APK (largest file or package-named file)
    local base_apk=""
    local base_size=0
    local pkg_name=""
    pkg_name=$(echo "$manifest" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('package_name',''))" 2>/dev/null || echo "")

    for apk_file in "$merge_dir"/*.apk; do
        [ ! -f "$apk_file" ] && continue
        local fname
        fname=$(basename "$apk_file")
        local sz
        sz=$(stat -c%s "$apk_file" 2>/dev/null || echo 0)

        # Prefer package-named file
        if [ -n "$pkg_name" ] && [ "$fname" = "${pkg_name}.apk" ]; then
            base_apk="$apk_file"
            base_size=$sz
            break
        fi

        # Otherwise pick largest
        if [ "$sz" -gt "$base_size" ]; then
            base_size=$sz
            base_apk="$apk_file"
        fi
    done

    if [ -z "$base_apk" ]; then
        log_error "  No base APK found inside XAPK!"
        exit 1
    fi

    log_info "  Step 2: Base APK = $(basename "$base_apk") ($(du -h "$base_apk" | cut -f1))"

    # Step 3: Extract base APK fully
    local base_dir="${merge_dir}/base_extracted"
    mkdir -p "$base_dir"
    log_info "  Step 3: Extracting base APK..."
    (cd "$base_dir" && unzip -o "$base_apk" 2>&1 | tail -3 >&2)

    # Step 4: Selectively merge split APKs
    local arch_found=false
    for split_file in "$merge_dir"/*.apk; do
        [ ! -f "$split_file" ] && continue
        [ "$split_file" = "$base_apk" ] && continue

        local split_name
        split_name=$(basename "$split_file")
        log_info "  Step 4: Merging split: $split_name"

        local split_dir="${merge_dir}/split_${split_name%.apk}"
        mkdir -p "$split_dir"
        (cd "$split_dir" && unzip -o "$split_file" 2>&1 | tail -1 >&2)

        # Selective copy: avoid duplicate entries
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
                                continue
                            fi
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
                    AndroidManifest.xml)
                        continue
                        ;;
                    resources.arsc)
                        continue
                        ;;
                    *.SF|*.RSA|*.MF|MANIFEST.MF)
                        continue
                        ;;
                    *)
                        mkdir -p "$(dirname "$dest")"
                        cp -f "$file" "$dest" 2>/dev/null || true
                        ;;
                esac
            done
        ) || true

        if echo "$split_name" | grep -q "arm64_v8a\|armeabi_v7a"; then
            arch_found=true
        fi
    done

    if [ "$arch_found" = true ]; then
        log_ok "  Arch split APKs merged (native libs included)"
    else
        log_warn "  No arch split found — native libs may be from base only"
    fi

    # Step 5: Clean signing metadata (will re-sign later)
    rm -rf "$base_dir/META-INF" 2>/dev/null || true

    # Step 6: Repack as FRESH zip
    local merged_apk="${WORK_DIR}/merged_base.apk"
    rm -f "$merged_apk"
    log_info "  Step 5: Repacking merged APK (fresh zip)..."
    (cd "$base_dir" && zip -r -q "$merged_apk" . 2>&1 >/dev/null)

    if [ ! -f "$merged_apk" ] || [ ! -s "$merged_apk" ]; then
        log_error "  Failed to repack merged APK!"
        exit 1
    fi

    BASE_APK="$merged_apk"
    log_ok "  Merged APK ready: $(du -h "$BASE_APK" | cut -f1)"

    # Cleanup
    rm -rf "$merge_dir"
}

decompile_apk() {
    log_info "Decompiling APK with apktool..."
    log_info "  Input:  $BASE_APK"

    rm -rf "${DECOMPILED_DIR}"

    if ! apktool d "$BASE_APK" -o "${DECOMPILED_DIR}" -f 2>&1 | tee "${WORK_DIR}/apktool_decompile.log"; then
        log_error "Decompilation failed!"
        echo "Check: ${WORK_DIR}/apktool_decompile.log"
        exit 1
    fi

    log_ok "APK decompiled successfully"

    # Fix common manifest issues
    if grep -q 'android:intentMatchingFlags' "${DECOMPILED_DIR}/AndroidManifest.xml" 2>/dev/null; then
        log_info "Fixing manifest: removing unsupported intentMatchingFlags"
        sed -i 's/android:intentMatchingFlags="[^"]*" //g' "${DECOMPILED_DIR}/AndroidManifest.xml"
        log_ok "  Manifest fixed"
    fi
}

inject_smali_patches() {
    log_info "Injecting smali patches..."

    # Find smallest smali directory to avoid dex overflow
    local smallest_dir=""
    local smallest_count=999999

    for dir in "${DECOMPILED_DIR}"/smali*/; do
        local count
        count=$(find "$dir" -name "*.smali" -type f 2>/dev/null | wc -l)
        if [ "$count" -lt "$smallest_count" ]; then
            smallest_count=$count
            smallest_dir="$dir"
        fi
    done

    if [ -z "$smallest_dir" ]; then
        smallest_dir="${DECOMPILED_DIR}/smali/"
    fi

    local target_dir="${smallest_dir}com/hotstar/patch"
    mkdir -p "$target_dir"
    log_info "  Target: ${target_dir} (${smallest_count} smali files)"

    if [ ! -f "${SCRIPT_DIR}/patches/CookieFileReader.smali" ]; then
        log_error "Missing: patches/CookieFileReader.smali"
        exit 1
    fi
    if [ ! -f "${SCRIPT_DIR}/patches/cookie-seeder.smali" ]; then
        log_error "Missing: patches/cookie-seeder.smali"
        exit 1
    fi

    cp "${SCRIPT_DIR}/patches/CookieFileReader.smali" "${target_dir}/CookieFileReader.smali"
    cp "${SCRIPT_DIR}/patches/cookie-seeder.smali" "${target_dir}/CookieSeeder.smali"
    log_ok "  Patches injected"
}

inject_cookie_assets() {
    log_info "Injecting cookie files as APK assets..."

    local assets_dir="${DECOMPILED_DIR}/assets/cookies"
    mkdir -p "$assets_dir"

    local count=0
    for cookie_file in "${SCRIPT_DIR}/cookies"/*.txt; do
        [ ! -f "$cookie_file" ] && continue
        local bname
        bname=$(basename "$cookie_file")
        cp "$cookie_file" "${assets_dir}/${bname}"
        log_ok "  ${bname} -> assets/cookies/"
        count=$((count + 1))
    done

    log_info "  Injected $count cookie file(s)"
}

patch_application_class() {
    log_info "Patching Application class to call CookieSeeder..."

    local manifest="${DECOMPILED_DIR}/AndroidManifest.xml"
    if [ ! -f "$manifest" ]; then
        log_error "AndroidManifest.xml not found!"
        exit 1
    fi

    # Extract android:name from <application> tag specifically
    local app_class
    app_class=$(grep -oP '<application\s[^>]*android:name="\K[^"]+' "$manifest")

    if [ -z "$app_class" ]; then
        log_error "Could not find Application class in manifest"
        exit 1
    fi

    log_info "  Application class: $app_class"

    # Convert to smali path
    local smali_path="${app_class//./\/}.smali"
    local full_path=""

    for smali_dir in "${DECOMPILED_DIR}"/smali*/; do
        if [ -f "${smali_dir}${smali_path}" ]; then
            full_path="${smali_dir}${smali_path}"
            break
        fi
    done

    # Fallback: search by class name
    if [ -z "$full_path" ] || [ ! -f "$full_path" ]; then
        local class_name
        class_name=$(echo "$app_class" | sed 's/.*\.//')
        full_path=$(find "${DECOMPILED_DIR}" -path "*/smali*" -name "${class_name}.smali" -type f 2>/dev/null | head -1)
    fi

    if [ -z "$full_path" ] || [ ! -f "$full_path" ]; then
        log_error "Could not find Application class smali!"
        log_info "  Searched: ${smali_path}"
        exit 1
    fi

    log_info "  Found: $full_path"

    # Get patch class reference from injection directory
    local patch_dir
    patch_dir=$(find "${DECOMPILED_DIR}" -path "*/patch/CookieSeeder.smali" -type f 2>/dev/null | head -1)
    local patch_class_path="Lcom/hotstar/patch/CookieSeeder;"
    if [ -n "$patch_dir" ]; then
        patch_class_path=$(echo "$patch_dir" | sed 's|.*/smali[^/]*/||; s|\.smali$||; s|^|L|; s|$|;|')
    fi
    log_info "  Patch ref: $patch_class_path"

    # Skip if already patched
    if grep -q "CookieSeeder" "$full_path" 2>/dev/null; then
        log_warn "  Already patched — skipping"
        return
    fi

    local inject_line="    invoke-static {p0}, ${patch_class_path}->seedIfNeeded(Landroid/content/Context;)V"
    local patch_success=false

    if grep -q "invoke-super.*attachBaseContext" "$full_path"; then
        log_info "  Strategy: after attachBaseContext super"
        sed -i "/invoke-super.*attachBaseContext/a\\${inject_line}" "$full_path"
        patch_success=true
    elif grep -q "invoke-super.*onCreate" "$full_path"; then
        log_info "  Strategy: after onCreate super"
        sed -i "/invoke-super.*onCreate/a\\${inject_line}" "$full_path"
        patch_success=true
    elif grep -q "attachBaseContext" "$full_path"; then
        log_info "  Strategy: in attachBaseContext before return-void"
        sed -i '/\.method.*attachBaseContext/,/\.end method/{
            /return-void/i\    invoke-static {p0}, Lcom/hotstar/patch/CookieSeeder;->seedIfNeeded(Landroid/content/Context;)V
        }' "$full_path"
        patch_success=true
    else
        log_info "  Strategy: after first invoke-super"
        sed -i '0,/invoke-super/{s/invoke-super.*/&\n    invoke-static {p0}, Lcom\/hotstar\/patch\/CookieSeeder;->seedIfNeeded(Landroid\/content\/Context;)V/}' "$full_path"
        patch_success=true
    fi

    if [ "$patch_success" = true ] && grep -q "CookieSeeder" "$full_path"; then
        log_ok "  Application class patched"
    else
        log_error "  Failed to patch Application class!"
        exit 1
    fi
}

patch_interceptors() {
    log_info "Analyzing request interceptors..."

    local found=0
    while IFS= read -r -d '' file; do
        local rel="${file#${DECOMPILED_DIR}/}"
        if grep -q "CookieSeeder" "$file" 2>/dev/null; then
            continue
        fi
        log_info "  Found: $rel"
        found=$((found + 1))
    done < <(grep -rl "X-Hs-UserToken\|x-hs-mediatoken" "${DECOMPILED_DIR}"/smali* 2>/dev/null | head -10)

    if [ "$found" -eq 0 ]; then
        log_warn "  No interceptors found — native refresh may not activate"
    else
        log_ok "  $found interceptor file(s) found"
    fi
}

recompile_apk() {
    log_info "Recompiling patched APK..."

    rm -f "${PATCHED_APK}"

    if ! apktool b "${DECOMPILED_DIR}" -o "${PATCHED_APK}" 2>&1 | tee "${WORK_DIR}/apktool_recompile.log"; then
        log_error "Recompilation failed!"
        echo "=== LAST 20 LINES ==="
        tail -20 "${WORK_DIR}/apktool_recompile.log"
        exit 1
    fi

    if [ ! -f "${PATCHED_APK}" ]; then
        log_error "Recompiled APK not found!"
        exit 1
    fi

    log_ok "APK recompiled ($(du -h "${PATCHED_APK}" | cut -f1))"
}

generate_keystore() {
    if [ -f "$KEYSTORE" ]; then
        log_info "Using existing keystore"
        return
    fi

    log_info "Generating signing keystore..."
    keytool -genkeypair -v \
        -keystore "$KEYSTORE" -alias "$KEY_ALIAS" \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass "$KEYSTORE_PASS" -keypass "$KEYSTORE_PASS" \
        -dname "CN=JioHotstar Patcher, OU=Patch, O=HotstarPatch, L=Unknown, ST=Unknown, C=XX" \
        2>&1 | tail -1
    log_ok "Keystore generated"
}

sign_apk() {
    log_info "Signing APK..."

    local aligned="${BUILD_DIR}/aligned.apk"

    rm -f "$aligned"
    if ! zipalign -f 4 "${PATCHED_APK}" "$aligned"; then
        log_error "zipalign failed"
        exit 1
    fi

    if ! apksigner sign \
        --ks "$KEYSTORE" \
        --ks-pass "pass:${KEYSTORE_PASS}" \
        --ks-key-alias "$KEY_ALIAS" \
        --key-pass "pass:${KEYSTORE_PASS}" \
        --out "${PATCHED_APK}" \
        "$aligned"; then
        log_error "apksigner failed"
        exit 1
    fi

    if apksigner verify "${PATCHED_APK}" 2>/dev/null; then
        log_ok "  Signature verified"
    else
        log_warn "  Signature verification failed (may still work)"
    fi

    rm -f "$aligned"
    log_ok "APK signed ($(du -h "${PATCHED_APK}" | cut -f1))"
}

print_summary() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  PATCH COMPLETE!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "  ${BLUE}Patched APK:${NC} ${PATCHED_APK}"
    echo -e "  ${BLUE}Size:${NC}       $(du -h "${PATCHED_APK}" | cut -f1)"
    echo ""
    echo -e "  ${GREEN}How it works:${NC}"
    echo "  1. CookieSeeder reads tokens from APK assets on first launch"
    echo "  2. Tokens stored in SharedPreferences (one-time)"
    echo "  3. Native interceptors handle token refresh cycle"
    echo "  4. Tokens auto-refresh indefinitely (like PC browser)"
    echo ""
}

# ===================== MAIN =====================

main() {
    banner
    check_dependencies
    parse_cookie_json
    validate_cookies
    find_base_apk

    mkdir -p "${BUILD_DIR}" "${WORK_DIR}"

    handle_xapk "$BASE_APK"
    decompile_apk
    inject_smali_patches
    inject_cookie_assets
    patch_application_class
    patch_interceptors
    recompile_apk
    generate_keystore
    sign_apk
    print_summary
}

main "$@"
