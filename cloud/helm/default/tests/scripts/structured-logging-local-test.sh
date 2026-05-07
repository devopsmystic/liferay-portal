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

	mkdir -p "${FIXTURES_DIR}"

	# Fetch + verify the three jars the chart depends on. Paths mirror Maven
	# Central layout for ${groupPath}/${artifactId}/${version}/${jar}.
	local jul_ecs_jar
	local ecs_core_jar
	local log4j_template_jar
	jul_ecs_jar=$(fetch_jar julEcsFormatter "co/elastic/logging" "jul-ecs-formatter")
	ecs_core_jar=$(fetch_jar ecsLoggingCore "co/elastic/logging" "ecs-logging-core")
	log4j_template_jar=$(fetch_jar log4jLayoutTemplateJson "org/apache/logging/log4j" "log4j-layout-template-json")

	container="liferay-structured-logging-test-$$"

	trap cleanup EXIT

	echo "Starting Liferay (${container})..."

	# Mirror the chart's runtime injection strategy: bind-mount the configs +
	# inject script + fetched JARs at the paths the inject script expects, then
	# let /mnt/liferay/scripts/100-inject-structured-logging.sh do the actual
	# placement at startup. This is what the helm chart does in-cluster.
	# Liferay's configure_liferay.sh (entrypoint chain when /mnt/liferay/scripts
	# is populated) runs under `set -u` and dereferences several optional env
	# vars without ":-" defaults. Pre-define them as empty to keep the script
	# from aborting on unbound-variable errors.
	docker run -d \
		--name "${container}" \
		-e LIFERAY_TOMCAT_AJP_PORT= \
		-e LIFERAY_TOMCAT_JVM_ROUTE= \
		-v "${CONFIGS_DIR}/portal-log4j-ext.xml:/var/lib/structured-logging/configs/portal-log4j-ext.xml:ro" \
		-v "${CONFIGS_DIR}/cloud-native-layout.json:/var/lib/structured-logging/configs/cloud-native-layout.json:ro" \
		-v "${CONFIGS_DIR}/logging.properties:/var/lib/structured-logging/configs/logging.properties:ro" \
		-v "${CONFIGS_DIR}/100-inject-structured-logging.sh:/mnt/liferay/scripts/100-inject-structured-logging.sh:ro" \
		-v "${jul_ecs_jar}:/var/lib/structured-logging/jars/$(basename "${jul_ecs_jar}"):ro" \
		-v "${ecs_core_jar}:/var/lib/structured-logging/jars/$(basename "${ecs_core_jar}"):ro" \
		-v "${log4j_template_jar}:/var/lib/structured-logging/jars/$(basename "${log4j_template_jar}"):ro" \
		liferay/dxp:latest > /dev/null

	echo "Waiting ${WAIT_SECONDS}s for log output..."
	sleep "${WAIT_SECONDS}"

	local logs
	logs=$(docker logs "${container}" 2>&1)

	# Drop the pre-Java banner — everything from container start up to (and
	# including) "Starting Liferay DXP. To stop the container..." is
	# bash/entrypoint output that can never be JSON. The structured-logging
	# ratio should be measured against JVM-emitted lines only.
	local jvm_logs
	jvm_logs=$(echo "${logs}" | awk -v skip=1 '
		/Starting Liferay DXP\. To stop/ { skip = 0; next }
		skip { next }
		{ print }
	')

	local non_empty
	local json_valid
	non_empty=$(echo "${jvm_logs}" | grep -cv '^$' || true)
	# log4j2 path emits `severity` (cloud-native-layout.json); JUL/ECS path
	# emits `log.level`. Both count as valid structured output for this test.
	json_valid=$(echo "${jvm_logs}" | jq -R 'fromjson? | select((.severity? or .["log.level"]?) and (.timestamp? or .["@timestamp"]?))' 2>/dev/null | jq -s 'length')

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
		echo
		echo "FAIL: ratio ${percent}% < threshold ${THRESHOLD_PERCENT}%."
		echo
		echo "Last 30 log lines for context:"
		docker logs --tail 30 "${container}" 2>&1 || true
		exit 1
	fi

	echo "PASS: structured logging is emitting JSON above the ${THRESHOLD_PERCENT}% threshold."
}

fetch_jar() {
	local sub_block="${1}"
	local group_path="${2}"
	local artifact_id="${3}"

	local version
	local sha256
	version=$(read_sub_value "${sub_block}" version)
	sha256=$(read_sub_value "${sub_block}" sha256)

	local jar_name="${artifact_id}-${version}.jar"
	local jar_path="${FIXTURES_DIR}/${jar_name}"

	if [ ! -f "${jar_path}" ]
	then
		echo "Fetching ${jar_name} from Maven Central..." >&2
		curl -sSfL \
			"https://repo1.maven.org/maven2/${group_path}/${artifact_id}/${version}/${jar_name}" \
			-o "${jar_path}"
	fi

	if [ "${sha256}" = "TODO_PIN_AFTER_VERIFY" ]
	then
		echo "WARN: SHA-256 for ${artifact_id} is the placeholder; skipping verification." >&2
	else
		echo "${sha256}  ${jar_path}" | sha256sum -c >&2
	fi

	echo "${jar_path}"
}

# Reads structuredLogging.<sub_block>.<key> from values.yaml by tracking indent.
# Top-level keys under structuredLogging sit at "sub_indent" (e.g. 4 spaces);
# their children sit deeper. We enter in_sub on the sub-block header, and exit
# as soon as we see another line at sub_indent (i.e. a sibling sub-block).
read_sub_value() {
	local sub_block="${1}"
	local key="${2}"

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
