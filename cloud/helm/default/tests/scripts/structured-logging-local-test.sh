#!/usr/bin/env bash

# Locally verifies the structured-logging chart wiring by booting Liferay in a
# plain Docker container with the chart's config files bind-mounted at the same
# Tomcat paths the helm chart targets, plus the JUL ECS formatter JAR fetched
# from Maven Central with the SHA-256 pinned in values.yaml.
#
# No DB is provided. Liferay's startup logging emits before the DB connection
# attempt fails — which is exactly the window we want to verify produces JSON.
#
# Usage: ./structured-logging-local-test.sh [seconds_to_wait]

set -o errexit
set -o nounset
set -o pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CHART_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly CONFIGS_DIR="${CHART_DIR}/files/structured-logging"
readonly FIXTURES_DIR="${SCRIPT_DIR}/../fixtures"
readonly WAIT_SECONDS="${1:-60}"
readonly THRESHOLD_PERCENT=50

# Set inside main(); referenced by the EXIT trap. Script-global so it stays
# in scope after main() returns, when the trap actually fires.
container=""

cleanup() {
	if [ -n "${container}" ]
	then
		docker rm -f "${container}" > /dev/null 2>&1 || true
	fi
}

main() {
	require_cmd curl docker jq sha256sum

	local version
	local sha256
	version=$(read_value "version")
	sha256=$(read_value "sha256")

	local jar_name="jul-ecs-formatter-${version}.jar"
	local jar_path="${FIXTURES_DIR}/${jar_name}"

	mkdir -p "${FIXTURES_DIR}"

	if [ ! -f "${jar_path}" ]
	then
		echo "Fetching ${jar_name} from Maven Central..."
		curl -sSfL \
			"https://repo1.maven.org/maven2/co/elastic/logging/jul-ecs-formatter/${version}/${jar_name}" \
			-o "${jar_path}"
	fi

	if [ "${sha256}" = "TODO_PIN_AFTER_VERIFY" ]
	then
		echo "WARN: SHA-256 in values.yaml is the placeholder; skipping verification."
	else
		echo "${sha256}  ${jar_path}" | sha256sum -c
	fi

	container="liferay-structured-logging-test-$$"

	trap cleanup EXIT

	echo "Starting Liferay (${container})..."

	docker run -d \
		--name "${container}" \
		-v "${CONFIGS_DIR}/portal-log4j-ext.xml:/opt/liferay/tomcat/webapps/ROOT/WEB-INF/classes/META-INF/portal-log4j-ext.xml:ro" \
		-v "${CONFIGS_DIR}/cloud-native-layout.json:/opt/liferay/tomcat/webapps/ROOT/WEB-INF/classes/META-INF/cloud-native-layout.json:ro" \
		-v "${CONFIGS_DIR}/logging.properties:/opt/liferay/tomcat/conf/logging.properties:ro" \
		-v "${jar_path}:/opt/liferay/tomcat/lib/${jar_name}:ro" \
		liferay/dxp:latest > /dev/null

	echo "Waiting ${WAIT_SECONDS}s for log output..."
	sleep "${WAIT_SECONDS}"

	local logs
	logs=$(docker logs "${container}" 2>&1)

	local non_empty
	local json_valid
	non_empty=$(echo "${logs}" | grep -cv '^$' || true)
	# log4j2 path emits `severity` (cloud-native-layout.json); JUL/ECS path
	# emits `log.level`. Both count as valid structured output for this test.
	json_valid=$(echo "${logs}" | jq -R 'fromjson? | select((.severity? or .["log.level"]?) and (.timestamp? or .["@timestamp"]?))' 2>/dev/null | jq -s 'length')

	if [ "${non_empty}" -eq 0 ]
	then
		echo "FAIL: container emitted no log output."
		exit 1
	fi

	local percent=$((json_valid * 100 / non_empty))

	echo "Total non-empty log lines:                   ${non_empty}"
	echo "Lines with valid JSON + severity + timestamp: ${json_valid}"
	echo "Structured-logging ratio:                     ${percent}%"

	if [ "${percent}" -lt "${THRESHOLD_PERCENT}" ]
	then
		echo
		echo "FAIL: ratio ${percent}% < threshold ${THRESHOLD_PERCENT}%."
		echo
		echo "Last 30 log lines for context:"
		docker logs --tail 30 "${container}" 2>&1 || true
		exit 1
	fi

	echo "PASS: structured logging is emitting JSON above the ${THRESHOLD_PERCENT}% threshold."
}

read_value() {
	local key="${1}"

	awk '
		/^structuredLogging:/ { in_block = 1; next }
		/^[^[:space:]]/ { in_block = 0 }
		in_block { print }
	' "${CHART_DIR}/values.yaml" |
		grep -E "^[[:space:]]+${key}:" |
		head -1 |
		sed -E 's/.*"([^"]*)".*/\1/'
}

require_cmd() {
	for cmd in "$@"
	do
		if ! command -v "${cmd}" > /dev/null
		then
			echo "ERROR: required command \"${cmd}\" not found in PATH."
			exit 1
		fi
	done
}

main "$@"
