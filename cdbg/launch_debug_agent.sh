#!/bin/bash
/cdbg/gce_metadata_proxy -host=${GCE_METADATA_HOST} -key=${CDBG_JSON_KEY_FILE} &
sleep 3
$(/cdbg/cd_go_agent.sh --verbose --program=${CDBG_PROGRAM} --sourcecontext=${CDBG_SOURCECONTEXT}) "$@"
