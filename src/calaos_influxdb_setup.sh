#!/bin/sh
# shellcheck disable=SC3043

set -e #stop if any error occurs
set -o nounset #stop if variable are uninitialised

NOCOLOR='\033[0m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'

info()
{
    echo -e "${CYAN}$*${NOCOLOR}"
}

green()
{
    echo -e "${GREEN}$*${NOCOLOR}"
}

err()
{
    echo -e "${RED}$*${NOCOLOR}"
}

# Ping influxd until it responds or crashes.
# Used to block execution until the server is ready to process setup requests.
wait_for_influxd () {
    local -r influxd_pid="$1"
    local ping_count=0
    while kill -0 "${influxd_pid}" && [ ${ping_count} -lt 30 ]; do
        sleep 1
        info "--> pinging influxd..." ping_attempt ${ping_count}
        ping_count=$((ping_count+1))
        if influx ping > /dev/null 2>&1 ; then
            info "--> got response from influxd, proceeding" total_pings ${ping_count}
            return
        fi
    done
    if [ ${ping_count} -eq 30 ]; then
        err "influxd took too long to start up" total_pings ${ping_count}
    else
        err "influxd crashed during startup" total_pings ${ping_count}
    fi
    exit 1
}

# Fix problem with influx-cli and localhost resolution"
echo "127.0.0.1 localhost" >> /etc/hosts

# Ensure influxdb is not running
if systemctl is-active --quiet influxdb
then
    systemctl stop influxdb
fi

info "--> Removing previous install of influxdb"
rm -rf /root/.influxdbv2/
rm -rf /var/lib/influxdb
rm -rf /var/lib/private/influxdb

info "--> Starting influxdb"
systemctl start influxdb
pid=$(systemctl show --property MainPID --value influxdb)
wait_for_influxd $pid

INFLUXDB_TOKEN="$(openssl rand -base64 64)"
INFLUXDB_USER="admin"
INFLUXDB_PASS="$(openssl rand --base64 15)"
INFLUXDB_ORG="calaos"
INFLUXDB_BUCKET="calaos-data"
INFLUXDB_CLI_CONFIG_NAME="calaos-config"

info "--> Setup new configuration of influxdb"
influx setup \
        --force \
        --username "${INFLUXDB_USER}" \
        --password "${INFLUXDB_PASS}" \
        --org "${INFLUXDB_ORG}" \
        --bucket "${INFLUXDB_BUCKET}" \
        --name "${INFLUXDB_CLI_CONFIG_NAME}" \
        --retention 0 \
        --token "${INFLUXDB_TOKEN}"


calaos_config set influxdb_token "${INFLUXDB_TOKEN}"
calaos_config set influxdb_org "${INFLUXDB_ORG}"
calaos_config set influxdb_bucket "${INFLUXDB_BUCKET}"
calaos_config set influxdb_version "2"

info "--> Save infos into /root/influxdb_access.log"

info "-->        token : ${INFLUXDB_TOKEN}"
info "-->         user : ${INFLUXDB_USER}"
info "-->     password : ${INFLUXDB_PASS}"
info "--> organisation : ${INFLUXDB_ORG}"
info "-->       bucket : ${INFLUXDB_BUCKET}"

{
echo  "        token : ${INFLUXDB_TOKEN}" 
echo  "     password : ${INFLUXDB_PASS}"
echo  "         user : ${INFLUXDB_USER}"
echo  " organisation : ${INFLUXDB_ORG}"
echo  "       bucket : ${INFLUXDB_BUCKET}"
} >>  /root/influxdb_access.log

chmod 600 /root/influxdb_access.log
