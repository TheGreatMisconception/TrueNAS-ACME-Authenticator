#!/usr/bin/env bash
: '
TrueNAS Alternative ACME DNS-Authenticator

DNS-Provider  - IONOS
API-Reference - https://developer.hosting.ionos.com/docs/dns

This script aims to let TrueNAS-Scale systems use IONOS as a valid ACME DNS-Authenticator by levereding their API.

Authenticates ACME DNS-01 challenges for TrueNAS Scale using the IONOS DNS API.
Enables TrueNAS Scale to use IONOS as an ACME DNS authenticator for automated SSL certificate renewal via Lets Encrypt.
'

set -euo pipefail

# -----------------------------------------------------------------------
# Configuration & Definitions
# -----------------------------------------------------------------------

readonly IONOS_API_BASE_URL='https://api.hosting.ionos.com/dns/v1/'
readonly IONOS_API_TXT_RECORD_TTL=60
#readonly IONOS_API_TXT_RECORD_PRIORITY=10
readonly IONOS_API_AUTHORIZATION_KEY=""

readonly SCRIPT_LOGFILE='/tmp/TrueNAS-ACME-DNS-Authentication-IONOS.log'
readonly SCRIPT_TMPFILE='/tmp/TrueNAS-ACME-DNS-Authentication-IONOS.tmp'
readonly SCRIPT_DNS_PROPAGATION_TIMEOUT=120
readonly SCRIPT_DNS_POLL_INTERVAL=10

# -----------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------

log()   { echo "[$(date "+%Y-%m-%d %H:%M:%S")] [INFO]  $*"  | tee -a "$SCRIPT_LOGFILE"  >&2 ;}
warn()  { echo "[$(date "+%Y-%m-%d %H:%M:%S")] [WARN]  $*"  | tee -a "$SCRIPT_LOGFILE"  >&2 ;}
error() { echo "[$(date "+%Y-%m-%d %H:%M:%S")] [ERROR] $*"  | tee -a "$SCRIPT_LOGFILE"  >&2 ;}

exit_on_error() {
    error "$1"
    exit "${2:-1}"
}

# -----------------------------------------------------------------------
# Validation & Requirements
# -----------------------------------------------------------------------

check_dependencies() {
    local -r dependencies=('curl' 'jq' 'dig')

    for dependency in ${dependencies[@]}; do
        if [[ -z "$(command -v $dependency)" ]]; then
            exit_on_error "Dependency not found: ${dependency}"
        else
            log "Dependency found: ${dependency} -> $(command -v "$dependency")"
        fi
    done
}

check_enviroment() {

    if [[ -z $CERTBOT_DOMAIN ]]; then
        exit_on_error "Variable/Parameter CERTBOT_DOMAIN not set - Stopping"
    fi

     if [[ -z $CERTBOT_DOMAIN_TXT_VALIDATION_VALUE ]]; then
        exit_on_error "Variable/ParameterCERTBOT_VALIDATION not set - Stopping"
    fi

    if [[ -z $IONOS_API_AUTHORIZATION_KEY ]]; then
        exit_on_error "Script variable IONOS_API_AUTHORIZATION_KEY not set - Stopping"
    fi

    if [[ -z $IONOS_API_BASE_URL ]]; then
        exit_on_error "Script variable IONOS_API_BASE_URL not set - Stopping"
    fi

    if [[ -z $IONOS_API_TXT_RECORD_TTL ]]; then
        exit_on_error "Script variable IONOS_API_TXT_RECORD_TTL not set - Stopping"
    fi

}


# -----------------------------------------------------------------------
# IONOS API - Helperfunctions
# -----------------------------------------------------------------------

ionos_api_request() {
    local -r api_header_content_type="Content-Type: application/json"
    local -r api_authorization_key="X-API-KEY: $IONOS_API_AUTHORIZATION_KEY"
    local -r api_method="$1"
    local -r api_endpoint="$2"
    local -r api_body="${3:-}"

    local -a curl_arguments=(
        --request "$api_method"
        --header "$api_authorization_key"
        --header "$api_header_content_type"
        --write-out "%{http_code}"
        --output "$SCRIPT_TMPFILE" 
        --silent
    )

    if [[ -n $api_body ]]; then
        curl_arguments+=(--data "$api_body")
    fi

    curl_arguments+=("${IONOS_API_BASE_URL}${api_endpoint}")
    local -r http_code=$(curl "${curl_arguments[@]}")

    if [[ "${http_code:0:1}" != '2' ]]; then
        exit_on_error "CURL: Received HTTP-StatusCode '$http_code' with method '$api_method' to queried endpoint '${IONOS_API_BASE_URL}${api_endpoint}' - Stopping!"
    else
        log "CURL: Received HTTP-StatusCode '$http_code' with method '$api_method' to queried endpoint '${IONOS_API_BASE_URL}${api_endpoint}'"
    fi

    http_content=$(cat "$SCRIPT_TMPFILE")
    rm -f "$SCRIPT_TMPFILE"
    echo "$http_content"

}

ionos_api_get_zone_id() {
    local dns_zones_json=$(ionos_api_request 'GET' 'zones')
    local dns_zone_id
    
    dns_zone_id=$(echo "$dns_zones_json" | jq -r --arg domain "$CERTBOT_DOMAIN" '.[] | .name as $zone | select(".\($domain)" | endswith(".\($zone)")) | .id')

    if [[ -z "$dns_zone_id" ]]; then
        exit_on_error "No DNS-Zone found that matches domain provided by certbot"
    else
        log "DNS-Zone found that matches domain provided by certbot"
        log "${CERTBOT_DOMAIN} corresponds to the zone_id $dns_zone_id"
    fi

    echo "$dns_zone_id"
}

ionos_api_get_record_id() {
    local -r dns_zone_id="$2"
    local -r dns_record_name="$1"
    local dns_records_json=$(ionos_api_request 'GET' "zones/${dns_zone_id}")
    local dns_record_id
    
    dns_record_id=$(echo "$dns_records_json" | jq -r --arg name "$dns_record_name" '.records[] | select(.name == $name) | .id' )
    if [[ -z "$dns_record_id" ]]; then
        exit_on_error "No DNS-Record found that matches provided recordname '$dns_record_name'"
    else
        log "DNS-Record found that matches recordname '$dns_record_name'"
        log "DNS-Record '$dns_record_name' corresponds to record_id '$dns_record_id'"
    fi

    echo "$dns_record_id"

}

ionos_api_add_txt_record() {
    local api_body_arguments
    local -r api_dns_zone_id=$(ionos_api_get_zone_id)
    local -r api_dns_endpoint="zones/${api_dns_zone_id}/records"

    local api_body_json=$(jq    -n \
                                --arg name "${ACME_DNS_RECORD_NAME}" \
                                --arg type "TXT" \
                                --arg content "$CERTBOT_DOMAIN_TXT_VALIDATION_VALUE" \
                                --argjson ttl "$IONOS_API_TXT_RECORD_TTL" \
                                --argjson disabled false \
                                '[{name: $name, type: $type, content: $content, ttl: $ttl, disabled: $disabled}]')

    http_response_add_record=$(ionos_api_request 'POST' "$api_dns_endpoint" "$api_body_json")
    
    local -r api_dns_record_id=$(echo "$http_response_add_record" | jq -r '.[].id')

    if [[ -n $api_dns_record_id ]]; then
        log "ACME-DNS-Record successfully created - received DNS-Record-ID from API"
        log "$http_response_add_record"
    else
        exit_on_error "Faield to set ACME-DNS-Record - No DNS-Record-ID received from API - Stopping!"
    fi
    
    echo $api_dns_record_id
}


ionos_api_del_txt_record() {
    local -r api_dns_zone_id="$1"
    local -r api_dns_acme_record_id=$(ionos_api_get_record_id "${ACME_DNS_RECORD_NAME}" "$api_dns_zone_id")
    local -r api_dns_endpoint="zones/${api_dns_zone_id}/records/${api_dns_acme_record_id}"
    
    local -r http_response_del_record_id=$(ionos_api_request 'DELETE' "$api_dns_endpoint")

    echo $http_response_del_record_id
}
# -----------------------------------------------------------------------
# DNS Propagation
# -----------------------------------------------------------------------

wait_for_dns_propagation() {
    local dns_certbot_validation_status=1
    SECONDS=0
    while (( $SECONDS < $SCRIPT_DNS_PROPAGATION_TIMEOUT )); do    # Loop until interval has elapsed.
        if [[ "$(dig @8.8.8.8 TXT "${ACME_DNS_RECORD_NAME}" +short)" == *"$CERTBOT_DOMAIN_TXT_VALIDATION_VALUE"* ]]; then
            log "Certbot DNS-Validation successful"
            dns_certbot_validation_status=0
            break
        fi
        sleep $SCRIPT_DNS_POLL_INTERVAL
    done

    if [[ $dns_certbot_validation_status -eq 1 ]]; then
        exit_on_error "Reached Timeout for DNS-Propagation for Certbot TXT-Record validation - Certbot DNS-Validation failed"
    fi
}

# -----------------------------------------------------------------------
# Main Logic
# -----------------------------------------------------------------------

action_deploy() {
    log "Starting ACME-DNS verification process for domain ${CERTBOT_DOMAIN}"
    check_dependencies
    check_enviroment

    local -r api_dns_record_id=$(ionos_api_add_txt_record)
    log "Deployment: Sucessfully set DNS-Record for ACME-Validation: ${api_dns_record_id}"

    wait_for_dns_propagation || exit_on_error "Deployment: DNS-Progagation failed - Timeout reached"

    log "Deployment: Successful"
}


action_cleanup() {
    log "Cleanup: Starting cleanup for domain ${CERTBOT_DOMAIN}"
    check_enviroment
    check_dependencies

    local -r api_dns_zone_id=$(ionos_api_get_zone_id)

    local http_repsonse=$(ionos_api_del_txt_record "$api_dns_zone_id")
    log "Cleanup: finished"
}

# -----------------------------------------------------------------------
# Main - Entry Point
# -----------------------------------------------------------------------

main() {
    trap "rm -f \"$SCRIPT_TMPFILE\"; log 'Script terminated, cleaning up..'; exit" EXIT

    readonly SCRIPT_ACTION="${1:-}"
    readonly CERTBOT_DOMAIN="${2:-}"
    readonly CERTBOT_DOMAIN_TXT_VALIDATION_VALUE="${4:-}"
    readonly ACME_DNS_RECORD_NAME="${3:-}"

    log "========================================"
    log "ACME IONOS Authenticator started"
    log "Action: ${SCRIPT_ACTION} | Domain: ${CERTBOT_DOMAIN:-not set} | Record: ${ACME_DNS_RECORD_NAME:-not set}"

    [[ -z "$SCRIPT_ACTION" ]]           && exit_on_error "Parameter \$1 (Action) missing"
    [[ -z "$CERTBOT_DOMAIN" ]]          && error "Parameter \$2 (Domain) missing"
    [[ -z "$ACME_DNS_RECORD_NAME" ]]    && error "Parameter \$3 (Record-Name) missing"
    
    if [[ "$SCRIPT_ACTION" == "set" ]]; then
        [[ -z "$CERTBOT_DOMAIN_TXT_VALIDATION_VALUE" ]] && exit_on_error "..."
    fi

    case "$SCRIPT_ACTION" in
        set)   action_deploy  ;;
        unset) action_cleanup ;;
        *)     exit_on_error "Unkown action: '${SCRIPT_ACTION}'. Allowed: set | unset" ;;
    esac
}

main "$@"