#!/bin/bash -e

#
# Downloads the latest Cloud Debugger agent and outputs a
# command line to enable Go Cloud Debugger in Google Compute Engine
# runtime environment.
#
# This script guarantees two properties:
# 1. All service instances use exactly the same version of Cloud Debugger agent.
#    Cloud Debugger requires that all instances a service must use the same
#    version of the Cloud Debugger agent.
# 2. When deploying a new version of the service, the latest Cloud Debugger
#    agent is used.
#
# Please see the documentation for more details:
# https://cloud.google.com/tools/cloud-debugger/setting-up-go-on-compute-engine
#
# Dependencies:
# 1. getopt
# 2. wget
# 3. md5sum
#

# Default parameter values.
VERBOSE=0
PROGRAM=
MODULE=
VERSION=
GCS_BUCKET_PREFIX="cdbg-agent_"
AGENT_PATH="/opt/cdbg"
RETRY_ATTEMPTS=5
SOURCECONTEXT=
SKIP_DOWNLOAD=0

# Helper constants.
METADATA_HEADER="Metadata-Flavor: Google"
STORAGE_API_BASE="https://www.googleapis.com"

# Cloud Storage bucket containing agent.
SOURCE_BUCKET="cloud-debugger"
# Location of agent.
AGENT_SOURCE_LOCATION=compute-go/go_agent_gce
# Filename of copied agent.
AGENT_NAME=go_agent_gce

# Prints the argument string to standard error output if verbose logging option
# is enabled.
function VerboseLog() {
  if [[ VERBOSE -eq 1 ]]; then
    echo "$@" >&2
  fi
}

# Computes hash of all application files and the version tuple.
function ComputeHash() {
  if [[ -n "${PROGRAM}" ]]; then
    local APP_FILES_HASH=$( md5sum -b ${PROGRAM} | awk '{print $1}' )
  else
    local APP_FILES_HASH=""
  fi
  APP_FILES_HASH+="Project ID: ${PROJECT_ID}, module: ${MODULE}, version: ${VERSION}, service_account: 0, language: Go"
  VERSION_HASH="$( echo ${APP_FILES_HASH} | md5sum -b -  | awk '{print $1}' )"

  VerboseLog "Version hash: ${VERSION_HASH}"
}

# Reads OAuth token and project information from local metadata service or
# exchange private key for access token if service account authentication was
# enabled in command line options.
function ReadProjectMetadata() {
  VerboseLog "Querying metadata service"

  local METADATA_URL="http://${GCE_METADATA_HOST}/computeMetadata/v1"

  OAUTH_TOKEN="$( wget -q -O - --no-cookies --header "${METADATA_HEADER}" "${METADATA_URL}/instance/service-accounts/default/token" | \
                  sed -e 's/.*"access_token"\ *:\ *"\([^"]*\)".*$/\1/g' )"
  PROJECT_ID="$( wget -q -O - --no-cookies --header "${METADATA_HEADER}" "${METADATA_URL}/project/project-id" )"
  PROJECT_NUMBER="$( wget -q -O - --no-cookies --header "${METADATA_HEADER}" "${METADATA_URL}/project/numeric-project-id" )"

  VerboseLog "Project ID: ${PROJECT_ID}"
  VerboseLog "Project number: ${PROJECT_NUMBER}"

  AUTH_HEADER="Authorization: Bearer ${OAUTH_TOKEN}"
  VerboseLog "OAuth token: ${OAUTH_TOKEN}"
}

# Creates storage bucket for the Cloud Debugger if one doesn't already exists
# and verifies that the bucket belongs to this GCP project.
function CreateGcsBucket() {
  BUCKET_NAME="${GCS_BUCKET_PREFIX}${PROJECT_ID}"

  echo "Creating GCS bucket ${BUCKET_NAME}"

  local CREATE_BUCKET_JSON_REQUEST="{ \"name\": \"${BUCKET_NAME}\" }"
  local CREATE_BUCKET_URL="${STORAGE_API_BASE}/storage/v1/b?project=${PROJECT_ID}&predefinedAcl=projectPrivate&projection=noAcl"
  wget -nv -O - --post-data "${CREATE_BUCKET_JSON_REQUEST}" --header "${AUTH_HEADER}" --header "Content-Type:application/json" "${CREATE_BUCKET_URL}" || true

  echo "Verifying that bucket ${BUCKET_NAME} belongs to GCP project ${PROJECT_ID}"

  local QUERY_BUCKET_URL="${STORAGE_API_BASE}/storage/v1/b/${BUCKET_NAME}"
  local BUCKET_INFO="$( wget -q -O - --no-cookies --header "${AUTH_HEADER}" "${QUERY_BUCKET_URL}" )"

  echo "Bucket ${BUCKET_NAME} info: ${BUCKET_INFO}"

  if [[ ! "${BUCKET_INFO}" =~ \"projectNumber\":\ *\"${PROJECT_NUMBER}\" ]]; then
    echo "Bucket could not be created or belongs to another GCP project"
    exit 1
  fi

  echo "GCS bucket ${BUCKET_NAME} is ready"
}

# If the agent binary doesn't exist in the storage bucket, uploads the latest
# version to the current version directory. If the agent binary is already
# there, does nothing. This operation is atomic: the same binary version will
# be used on each instance even if multiple instances of this script are running
# concurrently.
function SaveCloudDebuggerAgentLatestVersion() {
  local DESTINATION_BUCKET="${BUCKET_NAME}"
  local DESTINATION_OBJECT="${VERSION_HASH}/${AGENT_NAME}"

  echo "Copying agent binary from gs://${SOURCE_BUCKET}/${AGENT_SOURCE_LOCATION} to gs://${DESTINATION_BUCKET}/${DESTINATION_OBJECT}"

  local COPY_OBJECT_URL="${STORAGE_API_BASE}/storage/v1/b/${SOURCE_BUCKET}/o/${AGENT_SOURCE_LOCATION//\//%2F}/copyTo/b/${DESTINATION_BUCKET}/o/${DESTINATION_OBJECT//\//%2F}?ifGenerationMatch=0"
  wget -nv -O - --post-data "{}" --header "${AUTH_HEADER}" --header "Content-Type:application/json" "${COPY_OBJECT_URL}"
}

# Download and unpack the agent binary on the local drive.
function DownloadCloudDebuggerAgent() {
  local SOURCE="https://storage.googleapis.com/${BUCKET_NAME}/${VERSION_HASH}/${AGENT_NAME}"
  local DESTINATION="${AGENT_PATH}/${VERSION_HASH}/${AGENT_NAME}"

  echo "Trying to download the agent binary from ${SOURCE}"

  mkdir -p ${AGENT_PATH}/${VERSION_HASH}

  local DOWNLOAD_FAILED=0
  wget -nv -O "${DESTINATION}" --header "${AUTH_HEADER}" "${SOURCE}" || DOWNLOAD_FAILED=1
  if [[ DOWNLOAD_FAILED -eq 1 ]]; then
    rm -f "${DESTINATION}"
    return 1
  fi

  local CHMOD_FAILED=0
  chmod 0555 "${DESTINATION}" || CHMOD_FAILED=1
  if [[ CHMOD_FAILED -eq 1 ]]; then
    rm -f "${DESTINATION}"
    return 1
  fi

  echo "Agent binary copied to ${DESTINATION}"
}

# Single retry loop for PrepareCloudDebuggerAgent.
function TryPrepareCloudDebuggerAgent() {
  # It is important to call CreateGcsBucket before the attempt to download
  # the package. CreateGcsBucket verifies that the storage bucket belongs to
  # this project. Exits the script if it doesn't. Downloading from the GCE
  # bucket before this validation is not safe.
  CreateGcsBucket

  local NEED_COPY=0
  DownloadCloudDebuggerAgent || NEED_COPY=1
  if [[ NEED_COPY -eq 1 ]]; then
    SaveCloudDebuggerAgentLatestVersion
    DownloadCloudDebuggerAgent
  fi
}

# Applies all the storage manipulations explained above. Retries several times
# in case of an error. Errors may occur either due to GCS unavailability or
# due to race conditions when multiple instances of the script are executed
# at the same time. In either case this function handles these situations
# correctly.
function PrepareCloudDebuggerAgent() {
  if [[ SKIP_DOWNLOAD -eq 1 ]]; then
    return
  fi

  local ATTEMPT=0
  while [[ ATTEMPT -lt RETRY_ATTEMPTS ]]; do
    local PREPARE_FAILED=0

    if [[ VERBOSE -eq 1 ]]; then
      TryPrepareCloudDebuggerAgent 1>&2 || PREPARE_FAILED=1
    else
      TryPrepareCloudDebuggerAgent >> /dev/null 2>&1 || PREPARE_FAILED=1
    fi

    if [[ PREPARE_FAILED -eq 0 ]]; then
      return
    fi

    ATTEMPT=$[$ATTEMPT+1]

    VerboseLog "Failed to prepare the Cloud Debugger agent, attempt: ${ATTEMPT}"

    sleep 1
  done
}

function FormatCommandLine() {
  local AGENT_BINARY="${AGENT_PATH}/${VERSION_HASH}/${AGENT_NAME}"

  ARGS=
  if [[ -f "${AGENT_BINARY}" ]]; then
    ARGS=${AGENT_BINARY}
    if [[ VERBOSE -eq 1 ]]; then
      ARGS+=" -v"
    fi
    if [[ -n "${MODULE}" ]]; then
      ARGS+=" -appmodule=${MODULE}"
    fi
    if [[ -n "${VERSION}" ]]; then
      ARGS+=" -appversion=${VERSION}"
    fi
    if [[ -n "${SOURCECONTEXT}" ]]; then
      ARGS+=" -sourcecontext=${SOURCECONTEXT}"
    fi
    ARGS+=" -- ${PROGRAM}"
  else
    VerboseLog "Cloud Debugger agent not found: ${AGENT_BINARY}"
    exit 1
  fi
}

function DisplayUsage() {
  echo "Bootstrap script to enable Cloud Debugger on a Go application
running on Google Compute Engine.

For usage guide please see:
https://cloud.google.com/tools/cloud-debugger/setting-up-on-compute-engine

Required arguments:
  --program <filename>
      specifies the program to run

  --version <version>
      application major version

Optional arguments:
  --module <module>
      application module

  --gcs_bucket_prefix <prefix>
      prefix for GCS bucket name to use (default: ${GCS_BUCKET_PREFIX})

  --retry_attempts <n>
      sets the number of retry attempts to copy and download the Cloud
      Debugger agent (default: ${RETRY_ATTEMPTS})

  --sourcecontext <filename>
      File containing information about the version of the source code used
      to build the application. When you open the Cloud Debugger in the Google
      Developer Console, it uses the information in this file to display the
      correct version of the source.

  --skip_download
      only formats the command line argument assuming this script has
      been already called to download the agent

  --agent_path <dir>
      local directory to store the Cloud Debugger agent
      (default: ${AGENT_PATH})

  --env <path>
      Runs a script to set configuration options. This can be used to
      configure the debugger from file rather than command line.

  --verbose
      enables verbose logging to standard error output

  -h | --help | --?
      displays this help message" >&2
}

function PrintConfig() {
  VerboseLog "VERBOSE=${VERBOSE}"
  VerboseLog "PROGRAM=\"${PROGRAM}\""
  VerboseLog "MODULE=\"${MODULE}\""
  VerboseLog "VERSION=\"${VERSION}\""
  VerboseLog "AGENT_PATH=\"${AGENT_PATH}\""
  VerboseLog "GCS_BUCKET_PREFIX=\"${GCS_BUCKET_PREFIX}\""
  VerboseLog "RETRY_ATTEMPTS=\"${RETRY_ATTEMPTS}\""
  VerboseLog "SOURCECONTEXT=\"${SOURCECONTEXT}\""
  VerboseLog "SKIP_DOWNLOAD=\"${SKIP_DOWNLOAD}\""
}

function Main() {
  PrintConfig

  ReadProjectMetadata
  ComputeHash
  if [[ ! -d "${AGENT_PATH}/${VERSION_HASH}" ]]; then
    PrepareCloudDebuggerAgent
  fi
  FormatCommandLine

  echo ${ARGS}
}

# read the options
GETOPT=`getopt -o h -u --long ?,help,env:,program:,verbose,module:,version:,gcs_bucket_prefix:,retry_attempts:,skip_download,agent_path:,sourcecontext: -n 'cd_go_agent.sh' -- "$@"`
eval set -- "${GETOPT}"

while true ; do
  case "$1" in
    --verbose ) let VERBOSE=1; shift ;;
    --program ) PROGRAM="$2"; shift 2 ;;
    --module ) MODULE="$2"; shift 2 ;;
    --version ) VERSION="$2"; shift 2 ;;
    --gcs_bucket_prefix ) GCS_BUCKET_PREFIX="$2"; shift 2 ;;
    --retry_attempts ) let RETRY_ATTEMPTS="$2"; shift 2 ;;
    --sourcecontext ) SOURCECONTEXT="$2"; shift 2 ;;
    --skip_download ) SKIP_DOWNLOAD=1; shift 2 ;;
    --agent_path ) AGENT_PATH="$2"; shift 2 ;;
    --env ) . "$2"; shift 2 ;;
    -h|--?|--help ) DisplayUsage ; exit 1 ;;
    --) shift ; break ;;
    * ) echo "Error parsing command line arguments" >&2;
        exit 1
        ;;
  esac
done

Main
