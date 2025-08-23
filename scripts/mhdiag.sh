#!/usr/bin/env bash
# ==============================================================================
# Matrix Hub Deep Diagnostics v2.2
#
# Version: 2.2 - Fixes critical bugs causing curl/awk/rm errors. All informational
#                output is now correctly sent to stderr, ensuring variables
#                only capture the intended paths. Simplified and stabilized logic.
#
# Requirements: bash, curl, jq, awk
# ==============================================================================

set -u

# ---------- Config (env-overridable) ----------
API_HOST="${API_HOST:-api.matrixhub.io}"      # FastAPI Hub (behind Cloudflare)
WEB_HOST="${WEB_HOST:-www.matrixhub.io}"      # Vercel frontend
TIMEOUT="${TIMEOUT:-10}"                      # curl timeout seconds
Q_KEYWORD_A="${Q_KEYWORD_A:-videodb}"         # A term that should exist in the catalog
Q_PENDING="${Q_PENDING:-Slack}"               # A term that is likely 'pending'
# ---------------------------------------------

# ---------- Styling ----------
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
    C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3)
    C_BLUE=$(tput setaf 4); C_MAGENTA=$(tput setaf 5); C_CYAN=$(tput setaf 6); C_GREY=$(tput setaf 7)
else # Fallback for non-interactive shells or no tput
    C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_GREY=""
fi
OK="✅"; FAIL="❌"; WARN="⚠️"; PROBE="🔬"
hr(){ printf "\n${C_GREY}%*s${C_RESET}\n" "${COLUMNS:-100}" '' | tr ' ' '-'; }
# ---------------------------------------------

# ---------- Checks ----------
need(){ command -v "$1" >/dev/null 2>&1 || { echo "${FAIL} Missing required command: '$1'"; exit 1; }; }
need curl; need jq; need awk
# ---------------------------------------------

# ---------- State flags (auto-filled) ----------
HUB_HEALTH=0; CAT_TOTAL=0; KEYWORD_WORKS=0; PUBLIC_BASE_BAD=0; PROXY_WORKS=0; PENDING_NEEDED=0
# ---------------------------------------------

# Core request helper function.
# IMPORTANT: All informational output goes to stderr (>&2) to not pollute stdout.
# The *only* stdout is the temporary directory path for capture by the caller.
do_req() {
    local method="$1" url="$2"
    local tmpdir; tmpdir="$(mktemp -d)"
    local hdr_file="$tmpdir/h.txt" body_file="$tmpdir/b.txt"

    # The -L flag is added to follow redirects by default.
    local rc=0
    # The URL must be the last argument after all options.
    curl -sS -L -m "$TIMEOUT" -X "$method" \
        -D "$hdr_file" -o "$body_file" \
        -H "User-Agent: MatrixHubDiag/2.2" \
        -H "Accept: application/json, */*" \
        "$url" || rc=$?

    if [[ $rc -ne 0 ]]; then
        # All output here goes to stderr
        echo "${FAIL} curl failed (rc=$rc) for $url" >&2
        rm -rf "$tmpdir"
        # Return nothing on stdout to signal failure
        return 1
    fi

    local http_status
    # Safely read the status code
    http_status="$(awk '/^HTTP\//{code=$2} END{print code}' "$hdr_file" 2>/dev/null)"

    # Print status to stderr
    if [[ "$http_status" =~ ^2 ]]; then
        echo "   ${C_GREEN}Status: $http_status OK${C_RESET}" >&2
    else
        echo "   ${C_RED}${FAIL} Status: $http_status${C_RESET}" >&2
    fi

    # Smart JSON body printing to stderr
    if jq -e . "$body_file" >/dev/null 2>&1; then
        echo "   ${C_GREEN}${OK} JSON body detected.${C_RESET}" >&2
        local line_count
        line_count=$(jq . "$body_file" | wc -l)
        if [[ $line_count -gt 25 ]]; then
            echo "   ${C_CYAN}Body (trimmed for brevity):${C_RESET}" >&2
            # Smartly trims large arrays, showing the first item and a count of the rest
            jq 'if .items? | length > 1 then .items = [(.items[0]), "... (\(.items | length - 1) more)"] else . end' "$body_file" | sed 's/^/     /' >&2
        else
            echo "   ${C_CYAN}Body (pretty):${C_RESET}" >&2
            jq . "$body_file" | sed 's/^/     /' >&2
        fi
    else
        echo "   ${C_YELLOW}${WARN} Body is not valid JSON.${C_RESET}" >&2
    fi

    echo "$tmpdir" # The ONLY output to stdout
}

# ---------- Main Script ----------
clear
echo "${C_BOLD}${C_MAGENTA}=== Matrix Hub Deep Diagnostics v2.2 ===${C_RESET}"
echo "Hub (API):  ${C_CYAN}$API_HOST${C_RESET}"
echo "Proxy (Web): ${C_CYAN}$WEB_HOST${C_RESET}"

# --- Section 1: API Health and Data ---
hr
echo "${C_BOLD}SECTION 1: API Health & Catalog Status${C_RESET}"

echo -e "\n${C_BLUE}${PROBE} 1) Checking Hub Health (/health)...${C_RESET}"
tdir=$(do_req GET "https://$API_HOST/health?check_db=true")
if [[ -n "$tdir" ]]; then
    status=$(awk '/^HTTP\//{code=$2} END{print code}' "$tdir/h.txt" 2>/dev/null)
    [[ "$status" == "200" ]] && HUB_HEALTH=1
    rm -rf "$tdir"
fi

echo -e "\n${C_BLUE}${PROBE} 2) Checking Catalog for data (/catalog)...${C_RESET}"
tdir=$(do_req GET "https://$API_HOST/catalog?limit=1")
if [[ -n "$tdir" ]]; then
    CAT_TOTAL=$(jq -r '.total // 0' "$tdir/b.txt" 2>/dev/null || echo 0)
    rm -rf "$tdir"
fi

# --- Section 2: Search Index Health ---
hr
echo "${C_BOLD}SECTION 2: Search Index Health${C_RESET}"

echo -e "\n${C_BLUE}${PROBE} 3) Testing Keyword Search ('$Q_KEYWORD_A')...${C_RESET}"
tdir=$(do_req GET "https://$API_HOST/catalog/search?q=$Q_KEYWORD_A&mode=keyword")
if [[ -n "$tdir" ]]; then
    item_count=$(jq -r '.items | length' "$tdir/b.txt" 2>/dev/null || echo 0)
    [[ "$item_count" -gt 0 ]] && KEYWORD_WORKS=1
    rm -rf "$tdir"
fi

echo -e "\n${C_BLUE}${PROBE} 4) Checking pending items & base URL ('$Q_PENDING')...${C_RESET}"
tdir_with_pending=$(do_req GET "https://$API_HOST/catalog/search?q=$Q_PENDING&mode=keyword&include_pending=true")
if [[ -n "$tdir_with_pending" ]]; then
    len_with=$(jq -r '.items | length' "$tdir_with_pending/b.txt" 2>/dev/null || echo 0)
    if [[ "$len_with" -gt 0 ]]; then
        install_url=$(jq -r '.items[0].install_url // ""' "$tdir_with_pending/b.txt")
        [[ "$install_url" == *"127.0.0.1"* ]] && PUBLIC_BASE_BAD=1
        
        # Now check if it appears WITHOUT the pending flag
        tdir_no_pending=$(do_req GET "https://$API_HOST/catalog/search?q=$Q_PENDING&mode=keyword")
        if [[ -n "$tdir_no_pending" ]]; then
            len_without=$(jq -r '.items | length' "$tdir_no_pending/b.txt" 2>/dev/null || echo 0)
            [[ "$len_without" -eq 0 ]] && PENDING_NEEDED=1
            rm -rf "$tdir_no_pending"
        fi
    fi
    rm -rf "$tdir_with_pending"
fi

# --- Section 3: Vercel Proxy ---
hr
echo "${C_BOLD}SECTION 3: Vercel Proxy Health${C_RESET}"

echo -e "\n${C_BLUE}${PROBE} 5) Testing Proxy ('/api/search?q=$Q_PENDING')...${C_RESET}"
tdir=$(do_req GET "https://$WEB_HOST/api/search?q=$Q_PENDING")
if [[ -n "$tdir" ]]; then
    len_proxy=$(jq -r '.items | length' "$tdir/b.txt" 2>/dev/null || echo 0)
    [[ "$len_proxy" -gt 0 ]] && PROXY_WORKS=1
    rm -rf "$tdir"
fi

# ---------- Final Summary ----------
hr
echo -e "\n${C_BOLD}${C_GREEN}=== ✅ Diagnostic Summary ===${C_RESET}"

printf "%-28s: %s\n" "API Health (DB connected)" "$( ((HUB_HEALTH)) && echo "${C_GREEN}OK${C_RESET}" || echo "${C_RED}FAIL${C_RESET}")"
printf "%-28s: %s (%s items total)\n" "Catalog has data" "$( (($CAT_TOTAL > 0)) && echo "${C_GREEN}OK${C_RESET}" || echo "${C_RED}FAIL${C_RESET}")" "$CAT_TOTAL"
printf "%-28s: %s\n" "Keyword Search Index" "$( ((KEYWORD_WORKS)) && echo "${C_GREEN}OK${C_RESET}" || echo "${C_RED}FAIL - Index appears empty${C_RESET}")"
printf "%-28s: %s\n" "Public Base URL in links" "$( ((PUBLIC_BASE_BAD == 0)) && echo "${C_GREEN}OK${C_RESET}" || echo "${C_RED}FAIL - Points to 127.0.0.1${C_RESET}")"
printf "%-28s: %s\n" "Vercel Proxy to API" "$( ((PROXY_WORKS)) && echo "${C_GREEN}OK${C_RESET}" || echo "${C_RED}FAIL - Returned no data${C_RESET}")"
if (( PENDING_NEEDED )); then
    printf "%-28s: %s (Searching for '${Q_PENDING}' requires 'include_pending=true')\n" "Pending Items Behavior" "${C_YELLOW}NOTE${C_RESET}"
fi

echo -e "\n${C_BOLD}${C_MAGENTA}--- Action Plan ---${C_RESET}"
if (( KEYWORD_WORKS == 0 && CAT_TOTAL > 0 )); then
    echo "- ${FAIL} **Fix the Search Index:** Your API has data but the search is not returning results for known terms. Log into your production server and run the re-indexing or data ingestion command."
fi
if (( PUBLIC_BASE_BAD )); then
    echo "- ${FAIL} **Fix the Base URL:** Your API is generating links with '127.0.0.1'. Set the correct environment variable (e.g., \`PUBLIC_BASE_URL=https://$API_HOST\`) on your server and restart the application."
fi
if (( HUB_HEALTH == 0 || CAT_TOTAL == 0 )); then
    echo "- ${FAIL} **Check API/Database:** The API is unhealthy or the catalog is empty. Check your server logs and database connection."
fi
if (( KEYWORD_WORKS && PUBLIC_BASE_BAD == 0 && HUB_HEALTH )); then
    echo "- ${OK} **All critical checks passed.** If problems persist, the issue may be more subtle. Check the Vercel proxy logs for specific errors during its upstream fetch to the API."
fi

hr
echo "${C_GREEN}Done.${C_RESET}"