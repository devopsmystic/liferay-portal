#!/bin/bash

#
# Locally verifies the structured-logging chart wiring by booting Liferay in a
# plain Docker container with the chart's config files bind-mounted at the
# same Tomcat paths the helm chart targets, plus the JUL ECS formatter JAR
# fetched from Maven Central with the SHA-256 pinned in values.yaml.
#
# No DB is provided. Liferay's startup logging emits before the DB connection
# attempt fails, which is exactly the window we want to verify produces JSON.
#
# Usage: ./structured-logging-local-test.sh [seconds_to_wait]
#

set -o errexit
set -o nounset
set -o pipefail

readonly CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly CONFIGS_DIR="${CHART_DIR}/files/structured-logging"
readonly FIXTURES_DIR="${CHART_DIR}/tests/fixtures"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly THRESHOLD_PERCENT=50
readonly WAIT_SECONDS="${1:-60}"

# Set inside main; referenced by the EXIT trap. Script-global so it stays
# in scope after main returns, when the trap actually fires.
container=""

function main {
	_require_cmd curl docker jq sha256sum

	mkdir --parents "${FIXTURES_DIR}"

	local ecs_core_jar
	local jul_ecs_jar
	local log4j_template_jar

	ecs_core_jar=$(_fetch_jar ecsLoggingCore "co/elastic/logging" "ecs-logging-core")
	jul_ecs_jar=$(_fetch_jar julEcsFormatter "co/elastic/logging" "jul-ecs-formatter")
	log4j_template_jar=$(_fetch_jar log4jLayoutTemplateJson "org/apache/logging/log4j" "log4j-layout-template-json")

	container="liferay-structured-logging-test-${$}"

	trap _cleanup EXIT

	echo "Starting Liferay (${container})."

	docker run --detach \
		--env LIFERAY_TOMCAT_AJP_PORT= \
		--env LIFERAY_TOMCAT_JVM_ROUTE= \
		--name "${container}" \
		--volume "${CONFIGS_DIR}/100-inject-structured-logging.sh:/mnt/liferay/scripts/100-inject-structured-logging.sh:ro" \
		--volume "${CONFIGS_DIR}/cloud-native-layout.json:/var/lib/structured-logging/configs/cloud-native-layout.json:ro" \
		--volume "${CONFIGS_DIR}/logging.properties:/var/lib/structured-logging/configs/logging.properties:ro" \
		--volume "${CONFIGS_DIR}/portal-log4j-ext.xml:/var/lib/structured-logging/configs/portal-log4j-ext.xml:ro" \
		--volume "${ecs_core_jar}:/var/lib/structured-logging/jars/$(basename "${ecs_core_jar}"):ro" \
		--volume "${jul_ecs_jar}:/var/lib/structured-logging/jars/$(basename "${jul_ecs_jar}"):ro" \
		--volume "${log4j_template_jar}:/var/lib/structured-logging/jars/$(basename "${log4j_template_jar}"):ro" \
		liferay/dxp:latest > /dev/null

	echo "Waiting ${WAIT_SECONDS}s for log output."

	sleep "${WAIT_SECONDS}"

	local logs

	logs=$(docker logs "${container}" 2>&1)

	local jvm_logs

	jvm_logs=$(echo "${logs}" | awk -v skip=1 '
		/Starting Liferay DXP\. To stop/ { skip = 0; next }
		skip { next }
		{ print }
	')

	local non_empty

	non_empty=$(echo "${jvm_logs}" | grep --count --invert-match '^$' || true)

	local json_valid

	json_valid=$(echo "${jvm_logs}" | jq --raw-input 'fromjson? | select((.severity? or .["log.level"]?) and (.timestamp? or .["@timestamp"]?))' 2>/dev/null | jq --slurp 'length')

	if [ "${non_empty}" -eq 0 ]
	then
		echo "FAIL: container emitted no JVM log output."

		exit 1
	fi

	local percent=$((json_valid * 100 / non_empty))

	echo "JVM-emitted non-empty log lines:              ${non_empty}"
	echo "Lines with valid JSON + severity + timestamp: ${json_valid}"
	echo "Structured-logging ratio:                     ${percent}%"

	if [ "${percent}" -lt "${THRESHOLD_PERCENT}" ]
	then
		echo ""
		echo "FAIL: ratio ${percent}% < threshold ${THRESHOLD_PERCENT}%."
		echo ""
		echo "Last 30 log lines for context:"

		docker logs --tail 30 "${container}" 2>&1 || true

		exit 1
	fi

	echo "PASS: structured logging is emitting JSON above the ${THRESHOLD_PERCENT}% threshold."
}

function _cleanup {
	if [ -n "${container}" ]
	then
		docker rm --force "${container}" > /dev/null 2>&1 || true
	fi
}

function _fetch_jar {
	local artifact_id="${3}"
	local group_path="${2}"
	local sub_block="${1}"

	local sha256
	local version

	sha256=$(_read_sub_value "${sub_block}" sha256)
	version=$(_read_sub_value "${sub_block}" version)

	local jar_name="${artifact_id}-${version}.jar"
	local jar_path="${FIXTURES_DIR}/${jar_name}"

	if [ ! -f "${jar_path}" ]
	then
		echo "Fetching ${jar_name} from Maven Central." >&2

		curl --fail --location --show-error --silent \
			"https://repo1.maven.org/maven2/${group_path}/${artifact_id}/${version}/${jar_name}" \
			--output "${jar_path}"
	fi

	if [ "${sha256}" = "TODO_PIN_AFTER_VERIFY" ]
	then
		echo "WARN: SHA-256 for ${artifact_id} is the placeholder; skipping verification." >&2
	else
		echo "${sha256}  ${jar_path}" | sha256sum -c >&2
	fi

	echo "${jar_path}"
}

#
# Reads structuredLogging.<sub_block>.<key> from values.yaml by tracking
# indent. Top-level keys under structuredLogging sit at "sub_indent" (e.g.
# 4 spaces); their children sit deeper. We enter in_sub on the sub-block
# header, and exit as soon as we see another line at sub_indent (i.e. a
# sibling sub-block).
#
function _read_sub_value {
	local key="${2}"
	local sub_block="${1}"

	awk -v block="${sub_block}" -v key="${key}" '
		function indent(s) {
			match(s, /^[[:space:]]*/)
			return RLENGTH
		}
		/^structuredLogging:/ { in_top = 1; block_indent = -1; next }
		/^[^[:space:]]/ { in_top = 0; in_block = 0; next }
		!in_top { next }
		{
			ind = indent($0)
			if (block_indent < 0) block_indent = ind
			if (in_block && ind <= block_indent) in_block = 0
			if (ind == block_indent && match($0, "^[[:space:]]+" block ":")) {
				in_block = 1
				next
			}
			if (in_block && match($0, "^[[:space:]]+" key ":")) {
				print
				exit
			}
		}
	' "${CHART_DIR}/values.yaml" |
		sed --regexp-extended 's/.*:[[:space:]]*"?([^"#[:space:]]+)"?.*/\1/'
}

function _require_cmd {
	local cmd

	for cmd in "${@}"
	do
		if ! command -v "${cmd}" > /dev/null
		then
			echo "ERROR: required command \"${cmd}\" not found in PATH."

			exit 1
		fi
	done
}

main "${@}"