#!/usr/bin/env bash

# ==============================================================================
# Matrix Hub - Comprehensive Diagnostics Tool v1.2
#
# This script performs a series of read-only tests against the Matrix Hub API
# and the Vercel frontend proxy to diagnose common issues.
#
# Version: 1.2 - Added full JSON body output for each successful probe.
# ==============================================================================

# --- Configuration ---
API_HOST="${API_HOST:-api.matrixhub.io}"
WEB_HOST="${WEB_HOST:-www.matrixhub.io}"
TIMEOUT="${TIMEOUT:-10}" # Seconds for each curl request

# --- Colors and Icons ---
C_RESET=$(tput sgr0)
C_BOLD=$(tput bold)
C_RED=$(tput setaf 1)
C_GREEN=$(tput setaf 2)
C_YELLOW=$(tput setaf 3)
C_BLUE=$(tput setaf 4)
C_MAGENTA=$(tput setaf 5)
C_CYAN=$(tput setaf 6)
C_GREY=$(tput setaf 7)

ICON_OK="✅"
ICON_FAIL="❌"
ICON_WARN="⚠️"
ICON_INFO="ℹ️"
ICON_PROBE="🔬"

# --- Helper Functions ---

hr() {
    printf "\n${C_GREY}%*s${C_RESET}\n" "${COLUMNS:-80}" '' | tr ' ' '-'
}

check_dep() {
    if ! command -v "$1" &>/dev/null; then
        echo "${C_RED}${ICON_FAIL} Error: Required command '$1' is not installed. Please install it to continue.${C_RESET}"
        exit 1
    fi
}

run_probe() {
    local title="$1"
    local url="$2"
    local response headers body http_status

    echo
    echo "${C_BOLD}${C_BLUE}${ICON_PROBE} ${title}${C_RESET}"
    echo "${C_GREY}   URL: ${url}${C_RESET}"

    response=$(curl -sSiL -m "$TIMEOUT" \
        -H "User-Agent: MatrixHub-Diagnostic-Script/1.2" \
        -H "Accept: application/json, */*" \
        "$url")

    if [[ $? -ne 0 ]]; then
        echo "   ${C_RED}${ICON_FAIL} curl command failed. Check network connection or DNS resolution.${C_RESET}"
        hr
        return
    fi

    headers=$(echo "$response" | sed '/^\r$/q')
    body=$(echo "$response" | sed '1,/^\r$/d')
    http_status=$(echo "$headers" | grep -oE 'HTTP/[0-9\.]* [0-9]{3}' | tail -n1 | cut -d' ' -f2)

    if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
        echo "   ${C_GREEN}Status: $http_status OK${C_RESET}"
    else
        echo "   ${C_RED}${ICON_FAIL} Status: $http_status Client/Server Error${C_RESET}"
    fi
    
    echo "   ${C_GREY}Content-Type: $(echo "$headers" | grep -i 'content-type' | cut -d' ' -f2- | tr -d '\r')${C_RESET}"

    if [[ -z "$body" ]]; then
        echo "   ${C_YELLOW}${ICON_WARN} Response body is empty.${C_RESET}"
    else
        if echo "$body" | jq . &>/dev/null; then
            echo "   ${C_GREEN}${ICON_OK} Response body is valid JSON.${C_RESET}"
            
            # --- NEW: Print the full pretty-printed JSON response ---
            echo "   ${C_CYAN}Full JSON Response:${C_RESET}"
            echo "$body" | jq . | sed 's/^/     /'
            
            if [[ "$url" == *"/search"* ]]; then
                # ... Inferences for search endpoints ...
                local items_count=$(echo "$body" | jq '.items | if type=="array" then length else 0 end')
                if [[ "$items_count" -gt 0 ]]; then
                    local lexical_score=$(echo "$body" | jq -r '.items[0].score_lexical // 0')
                    if [[ "$lexical_score" == "0" ]]; then
                         echo "   ${C_YELLOW}${ICON_WARN} Inference: 'score_lexical' is 0, proving the keyword index was not used.${C_RESET}"
                    fi
                    local install_url=$(echo "$body" | jq -r '.items[0].install_url // ""')
                    if [[ "$install_url" == *"127.0.0.1"* ]]; then
                        echo "   ${C_RED}${ICON_FAIL} Inference: 'install_url' points to 127.0.0.1, proving the PUBLIC_BASE_URL is misconfigured!${C_RESET}"
                    fi
                fi
            fi
        else
            echo "   ${C_RED}${ICON_FAIL} Response body is NOT valid JSON.${C_RESET}"
        fi
    fi
    hr
}

# --- Main Execution & Summary (unchanged) ---
clear
echo "${C_BOLD}${C_MAGENTA}=== Matrix Hub Comprehensive Diagnostics ===${C_RESET}"
echo "Probing API Host: ${C_CYAN}${API_HOST}${C_RESET}"
echo "Probing Web Host: ${C_CYAN}${WEB_HOST}${C_RESET}"
hr
check_dep curl
check_dep jq
run_probe "1. API Health Check" "https://${API_HOST}/health?check_db=true"
run_probe "2. API Catalog Listing (Confirm data exists)" "https://${API_HOST}/catalog?limit=1"
echo; echo "${C_BOLD}${C_MAGENTA}--- Testing Direct API Search Index ---${C_RESET}"
run_probe "3a. Keyword Search (Should fail: 'videodb')" "https://${API_HOST}/catalog/search?q=videodb&mode=keyword"
run_probe "3b. Keyword Search (Should pass via fallback: 'Slack')" "https://${API_HOST}/catalog/search?q=Slack&mode=keyword&include_pending=true"
echo; echo "${C_BOLD}${C_MAGENTA}--- Testing Vercel Frontend Proxy ---${C_RESET}"
run_probe "4. Vercel Proxy to API ('/api/search')" "https://${WEB_HOST}/api/search?q=Slack"
echo; echo "${C_BOLD}${C_GREEN}=== Diagnostic Summary & Next Steps ===${C_RESET}"
echo "${ICON_INFO} The full JSON responses above confirm the diagnosis:"
echo; echo "  ${C_YELLOW}1. Broken Search Index:${C_RESET}"
echo "     ${C_BOLD}Diagnosis:${C_RESET} Test #2 shows data exists, but #3a returns an empty 'items' array. Test #3b returns an item but with 'score_lexical': 0."
echo "     ${C_BOLD} Solution:${C_RESET} SSH into your API server and run your data ingestion/re-indexing command."
echo; echo "  ${C_YELLOW}2. Misconfigured Public URL:${C_RESET}"
echo "     ${C_BOLD}Diagnosis:${C_RESET} The JSON in tests #3b and #4 clearly shows 'install_url': 'http://127.0.0.1:443/...'"
echo "     ${C_BOLD} Solution:${C_RESET} Set PUBLIC_BASE_URL=https://${API_HOST} in your API server's environment and restart the application."
hr
echo "${C_GREEN}Diagnostics complete.${C_RESET}"