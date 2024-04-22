#!/bin/sh

# [ ${FLOCKER} != $0 ] && exec env FLOCKER="$0" flock -e "$0" "$0" $@ ||
spinlock="${TMPDIR:-/tmp}/vgbrigade.spinlock"
# shellcheck disable=SC2064
trap "rm -f '${spinlock}' 2>/dev/null" EXIT
while [ -f "${spinlock}" ]; do
    sleep 0.1
done
touch "${spinlock}" 2>/dev/null

set -e

DB_DIR="/home"
STATS_DIR="/var/lib/vgstats"
ROUTER_SOCKETS_DIR="/var/lib/dcapi"

VGCERT_GROUP="vgcert"
VGSTATS_GROUP="vgstats"
VGROUTER_GROUP="vgrouter"

if [ "root" != "$(whoami)" ]; then
        echo "DEBUG EXECUTION" >&2
        DEBUG="yes"
fi

chunked="yes"

fatal() {
        cat << EOF | awk -v chunked="${chunked}" 'BEGIN {ORS=""; if (chunked != "") print length($0) "\r\n" $0 "\r\n0\r\n\r\n"; else print $0}'
{
        "code": $1,
        "desc": "$2"
        "status": "error",
        "message": "$3"
}
EOF
        exit 1
}

printdef () {
        msg="$1"

        fatal "400" "Bad request" "$msg"
}

if test -f "/.maintenance" && test "$(date '+%s')" -lt "$(cat "/.maintenance")"; then
        fatal 503 "Service is not available" "On maintenance till $(date -d "@$(cat /.maintenance)")"
fi

create () {
        brigade="$1"

        if [ -z "${brigade}" ]; then
                printdef "Brigade is required"
        fi

        brigade_id="$(echo "$brigade" | jq -r '.brigade_id')"

        if [ -z "${brigade_id}" ]; then
                printdef "Brigade ID is required"
        fi

        # * Check if brigade is exists
        if [ -z "${DEBUG}" ] && [ -s "${DB_DIR}/${brigade_id}/created" ]; then
                echo "Brigade ${brigade_id} already exists" >&2

                fatal "409" "Conflict" "Brigade ${brigade_id} already exists"
        fi

        if  [ -z "${DEBUG}" ] && [ ! -d "${ROUTER_SOCKETS_DIR}" ]; then
                install -o root -g "${VGROUTER_GROUP}" -m 0711 -d "${ROUTER_SOCKETS_DIR}" >&2
        fi

        # * Create system user
        if [ -z "${DEBUG}" ]; then
                {
                        useradd -p '*' -G "${VGCERT_GROUP}" -M -s /usr/sbin/nologin -d "${DB_DIR}/${brigade_id}" "${brigade_id}" >&2
                        install -o "${brigade_id}" -g "${brigade_id}" -m 0700 -d "${DB_DIR}/${brigade_id}" >&2
                        install -o "${brigade_id}" -g "${VGSTATS_GROUP}" -m 0710 -d "${STATS_DIR}/${brigade_id}" >&2
                        install -o "${brigade_id}" -g "${VGROUTER_GROUP}" -m 2710 -d "${ROUTER_SOCKETS_DIR}/${brigade_id}" >&2

                } || fatal "500" "Internal server error" "Can't create brigade ${brigade_id}"
        else
                echo "DEBUG: useradd -p '*' -G ${VGCERT_GROUP} -M -s /usr/sbin/nologin -d ${DB_DIR}/${brigade_id} ${brigade_id}" >&2
                echo "DEBUG: install -o ${brigade_id} -g ${brigade_id} -m 0700 -d ${DB_DIR}/${brigade_id}" >&2
                echo "DEBUG: install -o ${brigade_id} -g ${VGSTATS_GROUP} -m 0710 -d ${STATS_DIR}/${brigade_id}" >&2
                echo "DEBUG: install -o ${brigade_id} -g ${VGROUTER_GROUP} -m 2710 -d ${ROUTER_SOCKETS_DIR}/${brigade_id}" >&2
        fi

        if [ -z "${DEBUG}" ]; then
                echo "${brigade}" > "${DB_DIR}/${brigade_id}/brigade.json"
                chown "${brigade_id}:${brigade_id}" "${DB_DIR}/${brigade_id}"/brigade.json
                chmod 0644 "${DB_DIR}/${brigade_id}/brigade.json"
        else
                echo "DEBUG: echo ${brigade} > ${DB_DIR}/${brigade_id}/brigade.json" >&2
                echo "DEBUG: chown ${brigade_id}:${brigade_id} ${DB_DIR}/${brigade_id}/brigade.json" >&2
                echo "DEBUG: chmod 0644 ${DB_DIR}/${brigade_id}/brigade.json" >&2
        fi

        if [ -z "${DEBUG}" ]; then
                sudo -u "${brigade_id}" -g "${brigade_id}" /opt/vgkeydesk/reply || fatal "500" "Internal server error" "Can't reply brigade ${brigade_id}"
        else
                echo "DEBUG: sudo -u ${brigade_id} -g ${brigade_id} /opt/vgkeydesk/reply" >&2
        fi


        # * Activate keydesk systemD units

        systemd_vgkeydesk_instance="vgkeydesk@${brigade_id}"
        if [ -z "${DEBUG}" ]; then
                {
                        systemctl -q enable "${systemd_vgkeydesk_instance}.service" >&2
                        # Start systemD services
                        systemctl -q start "${systemd_vgkeydesk_instance}.service" >&2
                } || fatal "500" "Internal server error" "Can't start or enable ${systemd_vgkeydesk_instance}"
        else
                echo "DEBUG: systemctl -q enable ${systemd_vgkeydesk_instance}.service" >&2
                echo "DEBUG: systemctl -q start ${systemd_vgkeydesk_instance}.service" >&2
        fi

        [ -z "${DEBUG}" ] && date -u +"%Y-%m-%dT%H:%M:%S" > "${DB_DIR}/${brigade_id}/created"
}


# Loop through each item in the JSON array within the "plan" key
jq -c '.plan[]' | while read -r brigade; do
    create "${brigade}" 
done