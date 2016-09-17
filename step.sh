#!/bin/bash

THIS_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

set -e

#=======================================
# Functions
#=======================================

RESTORE='\033[0m'
RED='\033[00;31m'
YELLOW='\033[00;33m'
BLUE='\033[00;34m'
GREEN='\033[00;32m'

function color_echo {
	color=$1
	msg=$2
	echo -e "${color}${msg}${RESTORE}"
}

function echo_fail {
	msg=$1
	echo
	color_echo "${RED}" "${msg}"
	exit 1
}

function echo_warn {
	msg=$1
	color_echo "${YELLOW}" "${msg}"
}

function echo_info {
	msg=$1
	echo
	color_echo "${BLUE}" "${msg}"
}

function echo_details {
	msg=$1
	echo "  ${msg}"
}

function echo_done {
	msg=$1
	color_echo "${GREEN}" "  ${msg}"
}

function validate_required_variable {
	key=$1
	value=$2
	if [ -z "${value}" ] ; then
		echo_fail "[!] Variable: ${key} cannot be empty."
	fi
}

function validate_required_input {
	key=$1
	value=$2
	if [ -z "${value}" ] ; then
		echo_fail "[!] Missing required input: ${key}"
	fi
}

function validate_required_input_with_options {
	key=$1
	value=$2
	options=$3

	validate_required_input "${key}" "${value}"

	found="0"
	for option in "${options[@]}" ; do
		if [ "${option}" == "${value}" ] ; then
			found="1"
		fi
	done

	if [ "${found}" == "0" ] ; then
		echo_fail "Invalid input: (${key}) value: (${value}), valid options: ($( IFS=$", "; echo "${options[*]}" ))"
	fi
}

function validate_ios_inputs {
    validate_required_input "ios_pool" $ios_pool
    validate_required_input "ipa_path" $ipa_path
}

function validate_android_inputs {
    echo_fail 'android is not yet supported'
}

function get_test_package_arn {
    # Get most recent test bundle ARN
    test_package_arn=$(aws devicefarm list-uploads --arn="$device_farm_project" --query="uploads[?name=='${test_package_name}'] | max_by(@, &created).arn" --no-paginate --output=text)
    #test_package_arn=''

    echo_details "Got test package ARN:'${test_package_arn}'"
}

function get_upload_status {
    local upload_arn="$1"
    validate_required_variable "upload_arn" $upload_arn

    local upload_status=$(aws devicefarm get-upload --arn="$upload_arn" --query='upload.status' --output=text)
    echo "$upload_status"
}

function device_farm_run {
    echo_info "Setting up device farm run for platform '$platform'."
    local device_pool="$1"
    local app_package_path="$2"
    local upload_type="$3"

    validate_required_input "test_package_arn" $test_package_arn
    validate_required_variable "device_pool" $device_pool
    validate_required_variable "app_package_path" $app_package_path
    validate_required_variable "upload_type" $upload_type

    # Intialize upload
    local app_filename=$(basename "$app_package_path")
    local create_upload_response=$(aws devicefarm create-upload --project-arn="$device_farm_project" --name="$app_filename" --type="$upload_type" --query='upload.[arn, url]' --output=text)
    local app_arn=$(echo $create_upload_response|cut -d' ' -f1)
    local app_upload_url=$(echo $create_upload_response|cut -d' ' -f2)
    echo_details "Initialized upload of package '$app_filename' for app ARN '$app_arn'"

    # Perform upload
    echo_details "Beginning upload"
    curl -T "$app_package_path" "$app_upload_url"
    echo_details "Upload finished. Polling for status."

    # Poll for successful upload
    local upload_status=$(get_upload_status "$app_arn")
    echo_details "Upload status: $upload_status"
    while [ ! "$upload_status" == 'SUCCEEDED' ]; do
        if [ "$upload_status" == 'FAILED' ]; then
            echo_fail 'Upload failed!'
        fi

        echo_details "Upload not yet processed; waiting. (Status=$upload_status)"
        sleep 10s
        upload_status=$(get_upload_status "$app_arn")
    done
    echo_details 'Upload successful! Starting run...'

    # Start run
    local run_params=(--project-arn="$device_farm_project")
    run_params+=(--device-pool-arn="$device_pool")
    run_params+=(--app-arn="$app_arn")
    run_params+=(--test="{\"type\": \"${test_type}\",\"testPackageArn\": \"${test_package_arn}\",\"parameters\": {\"TestEnvVar\": \"foo\"}}")
    run_params+=(--output=json)

    if [ ! -z "$run_name_prefix" ]; then
        local run_name="${run_name_prefix}_${platform}_${build_version}"
        run_params+=(--name="$run_name")
        echo_details "Using run name '$run_name'"
    fi
    local run_response=$(aws devicefarm schedule-run "${run_params[@]}")
    echo_info "Run started for $platform!"
    echo_details "Run response: '${run_response}'"
}

#=======================================
# Main
#=======================================

#
# Validate parameters
echo_info "Configs:"
if [[ -n "$access_key_id" ]] ; then
	echo_details "* access_key_id: ***"
else
	echo_details "* access_key_id: [EMPTY]"
fi
if [[ -n "$secret_access_key" ]] ; then
	echo_details "* secret_access_key: ***"
else
	echo_details "* secret_access_key: [EMPTY]"
fi
echo_details "* device_farm_project: $device_farm_project"
echo_details "* test_package_name: $test_package_name"
echo_details "* test_type: $test_type"
echo_details "* platform: $platform"
echo_details "* ios_pool: $ios_pool"
echo_details "* ipa_path: $ipa_path"
echo_details "* run_name_prefix: $run_name_prefix"
echo_details "* build_version: $build_version"
echo_details "* aws_region: $aws_region"
echo

validate_required_input "access_key_id" $access_key_id
validate_required_input "secret_access_key" $secret_access_key
validate_required_input "device_farm_project" $device_farm_project
validate_required_input "test_package_name" $test_package_name
validate_required_input "test_type" $test_type

options=("ios"  "android" "ios+android")
validate_required_input_with_options "platform" $platform "${options[@]}"

set -o nounset
set -o errexit
set -o pipefail

get_test_package_arn

if [ "$platform" == 'ios' ]; then
    validate_ios_inputs
    device_farm_run "$ios_pool" "$ipa_path" 'IOS_APP'
elif [ "$platform" == 'android' ]; then
    validate_android_inputs
elif [ "$platform" == 'ios+android' ]; then
    validate_ios_inputs
    validate_android_inputs
fi

echo_info 'Done!'