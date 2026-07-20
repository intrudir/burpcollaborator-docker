#!/bin/bash

set -e

BURP_STARTED=0

# Cleanup handler for errors
cleanup() {
    status=$?
    echo "An error occurred during the execution of the script. Please check the output for details."
    if [ "$BURP_STARTED" -eq 1 ]; then
        docker rm -f burp >/dev/null 2>&1 || true
    fi
    [ -f ./burp/conf/burp.config.full ] && /bin/mv ./burp/conf/burp.config.full ./burp/conf/burp.config
    [ -f ./burp/conf/burp.config.dnsonly ] && /bin/rm -f ./burp/conf/burp.config.dnsonly
    exit "$status"
}
trap cleanup ERR INT TERM

# Check if a file exists
check_file() {
    if [ "$1" = "burp.jar" ]; then
        local file_path="./burp/pkg/$1"
    else
        local file_path="$1"
    fi

    if [ ! -e "$file_path" ]; then
        echo "ERROR: $file_path not found. Make sure it is in the correct location."
        exit 1
    fi
}

# Check if a command exists
check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: $1 is missing. Please install first."
        exit 1
    fi
}

check_file "burp.jar"
check_command "docker"
check_command "awk"

if [ $# -ne 2 ]; then
    echo "Usage: ./init.sh <domain> <ip>"
    exit 1
fi

DOMAIN=$1
IP=$2

if [[ ! "$DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
    echo "ERROR: '$DOMAIN' is not a valid DNS domain name."
    exit 1
fi

if ! awk -v ip="$IP" 'BEGIN {
    n = split(ip, octets, ".")
    if (n != 4) exit 1
    for (i = 1; i <= 4; i++) {
        if (octets[i] !~ /^[0-9]+$/ || octets[i] < 0 || octets[i] > 255) exit 1
    }
}' </dev/null; then
    echo "ERROR: '$IP' is not a valid IPv4 address."
    exit 1
fi

# Check if port 53 is available
if command -v ss >/dev/null 2>&1 && ss -lntu | grep -q ':53 '; then
    echo "ERROR: Port 53 is already in use. This is commonly caused by systemd-resolved."
    echo "To free port 53, you can run:"
    echo "  sudo systemctl stop systemd-resolved"
    echo "  sudo systemctl disable systemd-resolved"
    echo "  echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
    exit 1
fi

METRICS=$(LC_CTYPE=C tr -dc A-Za-z0-9 < /dev/urandom | fold -w 10 | head -1)

echo "Initialization to be done with domain *.$1 and public IP $2"

# check if docker works
if ! docker container ls >/dev/null; then
    echo "ERROR: Unable to access the Docker daemon." >&2
    exit 1
fi

# build the containers
docker build -t certbot-burp certbot
docker build -t burp burp

# Create full burp.config from template without interpolating values as JSON.
docker run --rm --entrypoint jq \
    -v "$PWD/burp/conf:/conf:ro" certbot-burp \
    --arg domain "$DOMAIN" --arg ip "$IP" --arg metrics "$METRICS" '
    .serverDomain = $domain |
    .eventCapture.publicAddress = [$ip] |
    .polling.http.publicAddress = [$ip] |
    .polling.https.publicAddress = [$ip] |
    .dns.interfaces[].publicAddress = [$ip] |
    .metrics.path = $metrics
' /conf/burp.config.template > ./burp/conf/burp.config

# Create a DNS-only config for the initial certificate fetch.
# Burp can't start with certificate paths that don't exist yet,
# so we strip HTTPS/SMTPS and polling sections entirely.
docker run --rm --entrypoint jq \
    -v "$PWD/burp/conf:/conf:ro" certbot-burp \
    'del(.eventCapture.https, .eventCapture.smtps, .polling)' \
    /conf/burp.config > ./burp/conf/burp.config.dnsonly
/bin/cp ./burp/conf/burp.config ./burp/conf/burp.config.full
/bin/mv ./burp/conf/burp.config.dnsonly ./burp/conf/burp.config

# Start Burp with DNS-only config and minimal port mappings
./burp/run-dnsonly.sh
BURP_STARTED=1

# Get certificates. The auth hook will inject TXT records into burp.config
# and restart Burp for each challenge.
./certbot/new.sh "$DOMAIN"

# Restore the full config (with certificate paths)
/bin/mv ./burp/conf/burp.config.full ./burp/conf/burp.config

# Copy certificate files to burp/keys
/bin/cp -L ./certbot/letsencrypt/live/$DOMAIN/cert.pem ./burp/keys/cert.pem
/bin/cp -L ./certbot/letsencrypt/live/$DOMAIN/chain.pem ./burp/keys/chain.pem
/bin/cp -L ./certbot/letsencrypt/live/$DOMAIN/fullchain.pem ./burp/keys/fullchain.pem
/bin/cp -L ./certbot/letsencrypt/live/$DOMAIN/privkey.pem ./burp/keys/privkey.pem

# Make the private key readable by the unprivileged Burp container user without sudo.
docker run --rm --entrypoint chown \
    -v "$PWD/burp/keys:/keys" certbot-burp 999:999 /keys/privkey.pem

# Restart Burp with the full config and certificates
docker stop burp && docker rm burp
BURP_STARTED=0
./burp/run.sh

echo
echo "SUCCESS! Burp is now running with the letsencrypt certificate for domain *.$DOMAIN"
echo
echo "Your metrics path was set to $METRICS. Change addressWhitelist to access it remotely."
echo "Initialization script has completed."
