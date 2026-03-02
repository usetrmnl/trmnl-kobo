#!/bin/sh

BATCH_MAX_LINES=50
CURL_TIMEOUT_SECONDS=8
CURL_CONNECT_TIMEOUT_SECONDS=5

DEBUG_LOG_FILE="/tmp/debug.log"
QUEUE_FILE="${trmnl_log_queue_file:-/tmp/trmnl-log-queue.ndjson}"
BATCH_FILE="/tmp/trmnl-log-batch.ndjson"
PAYLOAD_FILE="/tmp/trmnl-log-payload.json"
REMAINDER_FILE="/tmp/trmnl-log-queue.remainder"
RESPONSE_FILE="/tmp/trmnl-log-upload.response"

case "${trmnl_log_upload_enabled:-0}" in
    1)
        ;;
    *)
        exit 0
        ;;
esac

if [ ! -s "$QUEUE_FILE" ]; then
    exit 0
fi

if [ -z "${trmnl_apiurl:-}" ] || [ -z "${trmnl_id:-}" ]; then
    echo "TRMNL log upload skipped: missing API config" >> "$DEBUG_LOG_FILE" 2>&1
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "TRMNL log upload skipped: jq not found" >> "$DEBUG_LOG_FILE" 2>&1
    exit 0
fi

head -n "$BATCH_MAX_LINES" "$QUEUE_FILE" > "$BATCH_FILE" 2>/dev/null
batch_count=$(wc -l < "$BATCH_FILE" 2>/dev/null)
case "$batch_count" in
    ''|*[!0-9]*|0)
        exit 0
        ;;
esac

if ! jq -s '{logs: .}' "$BATCH_FILE" > "$PAYLOAD_FILE" 2>/dev/null; then
    echo "TRMNL log upload skipped: invalid queue payload" >> "$DEBUG_LOG_FILE" 2>&1
    exit 0
fi

http_code=$(curl "${trmnl_apiurl}/log" -L \
    -H "ID: ${trmnl_id}" \
    -H "Access-Token: ${trmnl_token}" \
    -H "FW-Version: ${trmnl_firmware_version}" \
    -H "Content-Type: application/json" \
    --connect-timeout "$CURL_CONNECT_TIMEOUT_SECONDS" \
    --max-time "$CURL_TIMEOUT_SECONDS" \
    --silent --show-error \
    -o "$RESPONSE_FILE" \
    -w "%{http_code}" \
    --data "@${PAYLOAD_FILE}" 2>/dev/null)
curl_status=$?

if [ "$curl_status" -ne 0 ]; then
    echo "TRMNL log upload failed: curl status ${curl_status}" >> "$DEBUG_LOG_FILE" 2>&1
    exit 0
fi

case "$http_code" in
    2*)
        ;;
    *)
        echo "TRMNL log upload failed: HTTP ${http_code}" >> "$DEBUG_LOG_FILE" 2>&1
        exit 0
        ;;
esac

awk "NR > ${batch_count}" "$QUEUE_FILE" > "$REMAINDER_FILE" 2>/dev/null
if [ $? -eq 0 ]; then
    mv -f "$REMAINDER_FILE" "$QUEUE_FILE"
fi

exit 0
