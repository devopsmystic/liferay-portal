#!/bin/bash

#
# Runtime injection of structured-logging configs into the shielded container.
#
# liferay/dxp:latest uses a shielded-container layout where Liferay's log4j
# config (portal-log4j.xml) lives inside shielded-container-lib/portal-impl.jar
# and Tomcat's common.loader excludes WEB-INF/classes/, so simple bind mounts
# do not reach the classpath log4j2 actually inspects at init time. This
# script runs from /mnt/liferay/scripts/ before Liferay starts and:
#
# 1. Injects portal-log4j-ext.xml + cloud-native-layout.json into the
# shielded-container-lib/portal-impl.jar (Liferay's log4j-extender picks
# up the EXT file from META-INF/ on that JAR's classpath).
# 2. Drops log4j-layout-template-json-*.jar next to log4j-core.jar in
# shielded-container-lib/ so JsonTemplateLayout's plugin is on the
# classpath log4j2 actually scans (it is not bundled in log4j-core 2.17.1).
# 3. Replaces /opt/liferay/tomcat/conf/logging.properties with the ECS
# formatter version.
# 4. Drops jul-ecs-formatter-*.jar and ecs-logging-core-*.jar into
# /opt/liferay/tomcat/lib/ so Tomcat's common.loader picks them up at
# JUL init time. (jul-ecs-formatter requires ecs-logging-core at runtime.)
#

set -o errexit
set -o nounset
set -o pipefail

readonly CONFIGS_DIR="/var/lib/structured-logging/configs"
readonly JARS_DIR="/var/lib/structured-logging/jars"
readonly SHIELDED_LIB="/opt/liferay/tomcat/webapps/ROOT/WEB-INF/shielded-container-lib"
readonly SHIELDED_JAR="${SHIELDED_LIB}/portal-impl.jar"
readonly TOMCAT_CONF="/opt/liferay/tomcat/conf"
readonly TOMCAT_LIB="/opt/liferay/tomcat/lib"

function main {
	_require_path "${CONFIGS_DIR}/portal-log4j-ext.xml"
	_require_path "${CONFIGS_DIR}/cloud-native-layout.json"
	_require_path "${CONFIGS_DIR}/logging.properties"
	_require_path "${SHIELDED_JAR}"

	_log "Injecting log4j2 config into shielded-container portal-impl.jar."

	_inject_into_shielded_jar

	_log "Copying log4j-layout-template-json JAR into shielded-container-lib/."

	_copy_jars "log4j-layout-template-json-*.jar" "${SHIELDED_LIB}"

	_log "Replacing Tomcat logging.properties."

	cp "${CONFIGS_DIR}/logging.properties" "${TOMCAT_CONF}/logging.properties"

	_log "First line: $(head --lines=1 "${TOMCAT_CONF}/logging.properties")."
	_log "Formatter line: $(grep '^java.util.logging.ConsoleHandler.formatter' "${TOMCAT_CONF}/logging.properties" || echo NOT_FOUND)."

	_log "Copying JUL ECS formatter JARs into tomcat/lib/."

	_copy_jars "jul-ecs-formatter-*.jar" "${TOMCAT_LIB}"
	_copy_jars "ecs-logging-core-*.jar" "${TOMCAT_LIB}"

	_log "Structured-logging configuration injected."
}

function _copy_jars {
	local dest="${2}"
	local glob="${1}"

	if compgen -G "${JARS_DIR}/${glob}" > /dev/null
	then
		cp "${JARS_DIR}"/${glob} "${dest}/"
	else
		_log "WARN: no ${glob} found in ${JARS_DIR}; structured-logging may not work."
	fi
}

function _inject_into_shielded_jar {
	local work_dir

	work_dir=$(mktemp --directory)

	mkdir --parents "${work_dir}/META-INF"

	cp "${CONFIGS_DIR}/portal-log4j-ext.xml" "${work_dir}/META-INF/"
	cp "${CONFIGS_DIR}/cloud-native-layout.json" "${work_dir}/META-INF/"

	(cd "${work_dir}" && jar uf "${SHIELDED_JAR}" \
		META-INF/portal-log4j-ext.xml \
		META-INF/cloud-native-layout.json)

	rm --force --recursive "${work_dir}"
}

function _log {
	echo "[structured-logging] ${*}"
}

function _require_path {
	if [ ! -e "${1}" ]
	then
		echo "[structured-logging] ERROR: required path \"${1}\" does not exist."

		exit 1
	fi
}

main "${@}"