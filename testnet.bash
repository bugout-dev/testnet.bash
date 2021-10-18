#!/usr/bin/env bash

# Source: https://github.com/bugout-dev/testnet.bash

# This script sets up an Ethereum test network using 2 miners.
# Assumptions:
# - geth available on PATH
# - jq available on PATH
# - The password is always "peppercat" (without the quotes)

# Accepts the following environment variables as inputs:
# - TESTNET_BASE_DIR: Directory into which all testnet data goes for all nodes.

set -e -o pipefail

function usage() {
    echo "$0 [-h]"
    echo
    echo "Starts an Ethereum testnet consisting of two mining nodes and a preconfigured genesis block."
    echo "Any changes to network topology or configuration should be made by editing this file."
    echo "Respects the following environment variables:"
    echo "TESTNET_BASE_DIR"
    echo -e "\tUse this environment variable to specify a directory in which to persist blockchain state. If this variable is not specified, a temporary directory will be used."
    echo "PASSWORD_FOR_ALL_ACCOUNTS"
    echo -e "\tUse this environment variable to specify a password that unlocks all miner accounts in the testnet. Default: 'peppercat' (without the quotes)."
    echo "GENESIS_JSON_CHAIN_ID"
    echo -e "\tUse this environment variable to specify a chain ID to write into the genesis.json for your testnet. Default: 1337."
}

if [ "$1" = "-h" ] || [ "$1" = "--help" ]
then
    usage
    exit 2
fi

PASSWORD_FOR_ALL_ACCOUNTS="${PASSWORD_FOR_ALL_ACCOUNTS:-peppercat}"

GETH="${GETH:-geth}"

TESTNET_BASE_DIR="$TESTNET_BASE_DIR"
if [ -z "$TESTNET_BASE_DIR" ]
then
    TESTNET_BASE_DIR="$(mktemp -d)"
    echo "TESTNET_BASE_DIR not provided. Using temporary directory: $TESTNET_BASE_DIR" 1>&2
fi

if [ ! -d "$TESTNET_BASE_DIR" ]
then
    echo "Base directory does not exist or is not a directory: $TESTNET_BASE_DIR"
    exit 1
fi


PIDS_FILE="$TESTNET_BASE_DIR/pids.txt"
BOOTNODES_FILE="$TESTNET_BASE_DIR/bootnodes.txt"
# Reset PID and bootnode metadata
rm -f "$BOOTNODES_FILE" "$PIDS_FILE"
touch "$PIDS_FILE" "$BOOTNODES_FILE"

GENESIS_JSON_CHAIN_ID="${GENESIS_JSON_CHAIN_ID:-1337}"

# Modify this if you would like to change the genesis parameters.
GENESIS_JSON="$TESTNET_BASE_DIR/genesis.json"
cat <<EOF >"$GENESIS_JSON"
{
  "config": {
    "chainId": $GENESIS_JSON_CHAIN_ID,
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": 0
  },
  "alloc": {},
  "coinbase": "0x0000000000000000000000000000000000000000",
  "difficulty": "0x20000",
  "extraData": "",
  "gasLimit": "0x2fefd8",
  "nonce": "0x0037861100000042",
  "mixhash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "parentHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "timestamp": "0x00"
}
EOF

function run_miner() {
    PASSWORD_FILE="$TESTNET_BASE_DIR/password.txt"
    if [ ! -f "$PASSWORD_FILE" ]
    then
        echo "$PASSWORD_FOR_ALL_ACCOUNTS" >"$PASSWORD_FILE"
    fi
    MINER_LABEL="miner-$1"
    MINER_LOGFILE="$TESTNET_BASE_DIR/$MINER_LABEL.log"
    MINER_DATADIR="$TESTNET_BASE_DIR/$MINER_LABEL"
    echo "Creating data directory for miner: $MINER_LABEL -- $MINER_DATADIR" 1>&2
    mkdir "$MINER_DATADIR"

    ETHASH_DIR="$TESTNET_BASE_DIR/ethash"
    if [ ! -d "$ETHASH_DIR" ]
    then
        mkdir "$ETHASH_DIR"
    fi
    MINER_DAGDIR="$ETHASH_DIR/$MINER_LABEL"

    KEYSTORE_DIR="$MINER_DATADIR/keystore"
    mkdir -p "$KEYSTORE_DIR"
    OLDEST_ACCOUNT_FILE=$(ls -1tr "$KEYSTORE_DIR")
    if [ -z "$OLDEST_ACCOUNT_FILE" ]
    then
        "$GETH" account new --datadir "$MINER_DATADIR" --password "$PASSWORD_FILE" >>"$MINER_LOGFILE"
        OLDEST_ACCOUNT_FILE=$(ls -1tr "$MINER_DATADIR/keystore/")
    fi

    MINER_ADDRESS=$(jq -r ".address" "$KEYSTORE_DIR/$OLDEST_ACCOUNT_FILE")

    "$GETH" init --datadir "$MINER_DATADIR" "$GENESIS_JSON"

    BOOTNODE="$(head -n1 $BOOTNODES_FILE)"

    if [ -z "$BOOTNODE" ]
    then
        set -x
        "$GETH" \
            --datadir="$MINER_DATADIR" \
            --ethash.dagdir="$MINER_DAGDIR" \
            --mine \
            --miner.threads=1 \
            --miner.gasprice=1000 \
            --miner.etherbase="$MINER_ADDRESS" \
            --networkid=1337 \
            --port 0 \
            >>"$MINER_LOGFILE" 2>&1 \
            &
        set +x
    else
        set -x
        "$GETH" \
            --datadir="$MINER_DATADIR" \
            --ethash.dagdir="$MINER_DAGDIR" \
            --mine \
            --miner.threads=1 \
            --miner.gasprice=1000 \
            --miner.etherbase="$MINER_ADDRESS" \
            --networkid=1337 \
            --port 0 \
            --bootnodes "$BOOTNODE" \
            >>"$MINER_LOGFILE" 2>&1 \
            &
        set +x
    fi

    PID="$!"
    echo "$PID" >>"$PIDS_FILE"

    if [ -z "$BOOTNODE" ]
    then
        until "$GETH" attach --exec "console.log(admin.nodeInfo.enode)" "$MINER_DATADIR/geth.ipc" | head -n1 >"$BOOTNODES_FILE"
        do
            sleep 1
        done
    fi

    echo "{\"miner\": \"$MINER_LABEL\", \"address\": \"$MINER_ADDRESS\", \"pid\": $PID, \"logfile\": \"$MINER_LOGFILE\"}"
}

function cancel() {
    while read -r pid
    do
        echo "Killing process: $pid" 1>&2
        kill -2 "$pid"
    done <"$PIDS_FILE"

    while read -r pid
    do
        while kill -0 "$pid"
        do
            echo "Waiting for process to die..." 1>&2
            sleep 1
        done
        echo "Process killed: $pid" 1>&2
    done <"$PIDS_FILE"
}

trap cancel SIGINT

# Add additional nodes here.
MINER_0=$(run_miner 0)
MINER_1=$(run_miner 1)

echo "Running testnet. Miner info:"
echo "$MINER_0" | jq .
echo "$MINER_1" | jq .
echo
echo "Press CTRL+C to exit."

tail -f $(echo "$MINER_0" | jq -r ".logfile") $(echo "$MINER_1" | jq -r ".logfile")
