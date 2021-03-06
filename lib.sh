#!/bin/bash

WORKDIR="$1"; shift

if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
	echo "usage: $0 <working-directory>" >&2
	echo "" >&2
	exit 1
fi

if [ -z "$MYDIR" ] || [ ! -d "$MYDIR" ]; then
	echo "\$MYDIR not initialized!" >&2
	echo "" >&2
	exit 1
fi

# shellcheck source=environment.sh disable=SC1091
. "${MYDIR}/environment.sh"

GITHUB_LAST_STATE=""

set -euo pipefail

### SYSTEM SCRIPTS ###
get_primary_host_ip() {
	local _host_ip
	local _hostname
	local _ifconfig

	set +e

	_hostname="$(hostname)"
	if [ "$(host "$_hostname" 2>/dev/null | grep -c 'has address')" -gt 0 ]; then
		_host_ip="$(host "$_hostname" 2>/dev/null | grep 'has address' | head -n 1 | sed -e 's,^.*has address ,,')"
	else
		_ifconfig="$(command -v ifconfig)"
		if [ -n "$_ifconfig" ]; then
			_host_ip="$(ifconfig "$(netstat -rn | grep -E "^default|^0.0.0.0" | head -1 | awk '{print $NF}')" 2>/dev/null | grep 'inet ' | awk '{print $2}' | sed -e 's,^addr:,,' -e 's,/.*$,,')"
		else
			_host_ip="$(ip addr show dev "$(netstat -rn | grep -E "^default|^0.0.0.0" | head -1 | awk '{print $NF}')" 2>/dev/null | grep 'inet ' | awk '{print $2}' | sed -e 's,^addr:,,' -e 's,/.*$,,')"
		fi

	fi

	if [ -n "$_host_ip" ]; then
		echo "$_host_ip"
	else
		echo 127.0.0.1
	fi

	set -e
}

retry_sudo() {
	set +e
	if echo "" | "$@" >/tmp/$$.output 2>&1; then
		cat /tmp/$$.output
		rm /tmp/$$.output
		return 0
	else
		rm /tmp/$$.output
		echo "" | sudo -n "$@"
	fi
	set -e
}

increase_limits() {
	local limit

	limit=$(ulimit -n)
	if [ "$limit" -lt 4096 ]; then
		ulimit -n 4096
	fi

	limit=$(cat /proc/sys/kernel/threads-max)
	if [ "$limit" -lt 200000 ]; then
		sudo bash -c 'echo 200000 > /proc/sys/kernel/threads-max'
	fi

	limit=$(cat /proc/sys/vm/max_map_count)
	if [ "$limit" -lt 100000 ]; then
		sudo bash -c 'echo 128000 > /proc/sys/vm/max_map_count'
	fi
}

assert_opennms_repo_version() {
	local repoversion

	repoversion=$(opennms-release.pl | sed -e 's,^v,,' | cut -d. -f1-2)

	if [[ $(echo "${repoversion} < 2.9" | bc) == 1 ]]; then
		echo 'Install OpenNMS::Release 2.9.0 or greater!'
		exit 1
	fi
}

stop_opennms() {
	local _systemctl
	local _opennms

	_systemctl="$(command -v systemctl 2>/dev/null || :)"
	_opennms="/opt/opennms/bin/opennms"

	if [ -e "${_systemctl}" ] && [ -x "${_systemctl}" ]; then
		retry_sudo "${_systemctl}" stop opennms || :
	fi
	if [ -e "${_opennms}" ] && [ -x "${_opennms}" ]; then
		retry_sudo "${_opennms}" stop || :
		sleep 5
		retry_sudo "${_opennms}" kill || :
	else
		echo "WARNING: ${_opennms} does not exist"
	fi
}

clean_opennms() {
	for PKG_SUFFIX in \
		upgrade \
		docs \
		core \
		plugin-ticketer-centric \
		source \
		remote-poller \
		minion-core \
		minion-features \
		minion-container
	do
		retry_sudo yum -y remove "opennms-${PKG_SUFFIX}" || :
		retry_sudo yum -y remove "meridian-${PKG_SUFFIX}" || :
	done
	retry_sudo rm -rf /opt/opennms /opt/minion /usr/lib/opennms, /usr/share/opennms, /var/lib/opennms, /var/log/opennms, /var/opennms
}

stop_firefox() {
	retry_sudo killall firefox >/dev/null 2>&1 || :
}

stop_compiles() {
	set +eo pipefail
	KILLME=$(pgrep -f '(failsafe|surefire|git-upload-pack|bin/java .*install$)')
	if [ -n "$KILLME" ]; then
		# shellcheck disable=SC2086
		retry_sudo kill $KILLME || :
		sleep 5
		# shellcheck disable=SC2086
		retry_sudo kill -9 $KILLME || :
	fi
	set -eo pipefail
}

reset_postgresql() {
	echo "- cleaning up postgresql:"

	retry_sudo service postgresql restart || :

	set +euo pipefail
	psql -U opennms -c 'SELECT datname FROM pg_database' -Pformat=unaligned -Pfooter=off 2>/dev/null | grep -E '^opennms' >/tmp/$$.databases
	set -euo pipefail

	(while read -r DB; do
		echo "  - removing $DB"
		dropdb -U opennms "$DB"
	done) < /tmp/$$.databases
	echo "- finished cleaning up postgresql"
	rm /tmp/$$.databases
	/usr/bin/createdb -U opennms -E UNICODE opennms
	/usr/sbin/install_iplike.sh
}

reset_docker() {
	echo "- killing and removing old Docker containers..."
	set +eo pipefail
	# shellcheck disable=SC2046
	# stop all running docker containers
	(docker kill $(docker ps --no-trunc -a -q)) 2>/dev/null || :
	docker system prune --all --force --filter "until=24h" 2>/dev/null || :
	docker system prune --force 2>/dev/null || :
	docker system prune --volumes --force 2>/dev/null || :
	set -eo pipefail
}


### GIT and Maven ###
update_github_status() {
	local _workdir
	local _state
	local _context
	local _description

	local _url
	local _hash

	_workdir="$1"; shift
	_state="$1"; shift
	_context="$1"; shift
	_description="$1"; shift

	set +u
	# shellcheck disable=SC2154
	_url="${bamboo_buildResultsUrl}"

	if [ -z "$_url" ]; then
		echo "ERROR: \$bamboo_buildResultsUrl is not set." >&2
		return 1
	fi
	if [ -z "${GITHUB_AUTH_TOKEN}" ]; then
		echo "ERROR: \$GITHUB_AUTH_TOKEN is not set." >&2
		return 1
	fi

	_hash="$(get_git_hash "$_workdir")"

	read -r -d '' __github_status_DATA <<END || true
{
	"state": "${_state}",
	"context": "${_context}",
	"description": "${_description}",
	"target_url": "${_url}"
}
END
	set -u

	GITHUB_LAST_STATE="${_state}"

	curl \
		--silent \
		--show-error \
		-H "Authorization: token ${GITHUB_AUTH_TOKEN}" \
		--request POST \
		--data "$__github_status_DATA" \
		"https://api.github.com/repos/OpenNMS/opennms/statuses/${_hash}" \
		> /dev/null

	case "${_state}" in
		success|pending)
			return 0
			;;
		failure)
			return 1
			;;
		error)
			return 2
			;;
		*)
			echo "WARNING: Unhandled state: '${_state}'" >&2
			return 3
			;;
	esac
}

get_branch_name() {
	local _workdir
	local _branch_name

	_workdir="$1"; shift

	set +u
	# shellcheck disable=SC2154
	if [ -z "${bamboo_OPENNMS_BRANCH_NAME}" ]; then
		_branch_name="${bamboo_planRepository_branchName}"
	else
		_branch_name="${bamboo_OPENNMS_BRANCH_NAME}"
	fi
	set -u

	if [ -z "$_branch_name" ] || [ "$(echo "$_branch_name" | grep -c '\$')" -gt 0 ]; then
		# branch did not get substituted, use git instead
		echo "WARNING: \$bamboo_OPENNMS_BRANCH_NAME and \$bamboo_planRepository_branchName are not set, attempting to determine branch with \`git symbolic-ref HEAD\`." >&2
		_branch_name="$( (cd "${_workdir}" || exit 1; git symbolic-ref HEAD) | sed -e 's,^refs/heads/,,')"
	fi

	echo "${_branch_name}"
}

get_sanitized_branch_name() {
	local _workdir
	local _branch_name

	_workdir="$1"; shift
	_branch_name="$(get_branch_name "${_workdir}" | sed -e 's,[^[:alnum:]][^[:alnum:]]*,.,g' -e 's,^\.,,' -e 's,\.$,,')"

	echo "${_branch_name}"
}

get_repo_name() {
	local _workdir
	local _repo_name

	_workdir="$1"; shift

	set +u
	# shellcheck disable=SC2154
	if [ -z "${bamboo_OPENNMS_BUILD_REPO}" ]; then
		_repo_name=$(cat "${_workdir}/.nightly")
	else
		_repo_name="${bamboo_OPENNMS_BUILD_REPO}"
	fi
	set -u

	echo "${_repo_name}"
}

get_opennms_version() {
	local _workdir

	_workdir="$1"; shift

	set +o pipefail
	grep '<version>' "${_workdir}/pom.xml" | head -n 1 | sed -e 's,^.*<version>,,' -e 's,<.version>.*$,,'
	set -o pipefail
}

get_git_hash() {
	local _workdir

	_workdir="$1"; shift

	cd "${_workdir}" || exit 1
	git rev-parse HEAD
}

clean_m2_repository() {
	if [ -d "$HOME/.m2" ]; then
		retry_sudo rm -rf "$HOME"/.m2/repository*/{com,org}/opennms
	fi
}

clean_maven_target_directories() {
	local _workdir

	_workdir="$1"; shift

	retry_sudo find "$_workdir" -type d -name target -print0 | xargs -0 rm -rf
}

clean_node_directories() {
	local _workdir

	_workdir="$1"; shift

	retry_sudo rm -rf "${_workdir}/node_modules"
}

clean_tmp() {
	retry_sudo find /tmp -name opennms.\* -o -name \*.javabins -o -name com.vaadin.\* -exec rm -rf {} \;
}

### Filesystem/Path Admin ###
# usage: fix_ownership $WORKDIR [$file_to_match]
# If file_to_match is not passed, attempts to use the bamboo uid/gid.
# If bamboo uid/gid can't be determined, falls back to the 'opennms' user/group.
fix_ownership() {
	local _workdir
	local _chown_user
	local _chown_group

	_workdir="$1"; shift
	set +u
	if [ -n "$1" ]; then
		# shellcheck disable=SC2012
		_chown_user="$(ls -n "$1" | awk '{ print $3 }')"
		# shellcheck disable=SC2012
		_chown_group="$(ls -n "$1" | awk '{ print $4 }')"
	else
		_chown_user="$(id -u bamboo 2>/dev/null)"
		_chown_group="$(id -g bamboo 2>/dev/null)"
	fi
	set -u

	if [ -z "${_chown_user}" ] || [ "${_chown_user}" -eq 0 ]; then
		_chown_user="opennms"
	fi
	if [ -z "${_chown_group}" ] || [ "${_chown_group}" -eq 0 ]; then
		_chown_group="opennms"
	fi

	retry_sudo chown -R "${_chown_user}:${_chown_group}" "${_workdir}"
}

warn_ownership() {
	local _workdir
	local _user
	local _group

	_workdir="$1"; shift
	if [ -z "$1" ]; then
		echo 'You must specify a file to match!'
		exit 1
	fi
	_checkfile="$1"; shift

	set +u
	# shellcheck disable=SC2012
	_user="$(ls -n "${_checkfile}" | awk '{ print $3 }')"
	# shellcheck disable=SC2012
	_group="$(ls -n "${_checkfile}" | awk '{ print $4 }')"
	set -u

	if [ -z "${_user}" ] || [ -z "${_group}" ]; then
		echo "Unable to determine UID and GID of ${_checkfile}"
		exit 1
	fi

	COUNT="$(find "${_workdir}" ! -uid "${_user}" -o ! -gid "${_group}" | wc -l | sed -e 's, *,,')"
	if [ "$COUNT" -gt 0 ]; then
		echo "WARNING: $COUNT file(s) are not owned by ${_user}:${_group}."
	fi
	return "$COUNT"
}

consolidate_junit_output() {
	local _workdir

	_workdir="$1"; shift
	if [ -z "$_workdir" ]; then
		echo 'You must specify a path which contains junit test output!'
		exit 1
	fi
	mkdir -p "${_workdir}/target/surefire-reports/"
	find "${_workdir}" -type d -a '(' -name surefire-\* -o -name failsafe-\* ')' \
		| grep -v -E "^${_workdir}/target/surefire-reports/?\$" \
		| while read -r DIR; do
			find "$DIR" -type f -a '(' -name 'TEST-*.xml' -o -name '*.txt' ')' -exec mv -f '{}' "${_workdir}/target/surefire-reports/" \;
		done
}

github_trap_exit() {
	local _ret="$?"
	set +u
	if [ "$_ret" -gt 0 ]; then
		local _state="failure"
		local _message="unknown failure"
		if [ "$_ret" -gt 1 ]; then
			_state="error"
			_message="unknown error"
		fi
		if [ "${_state}" != "${GITHUB_LAST_STATE}" ]; then
			update_github_status "${WORKDIR}" "${_state}" "${BUILD_CONTEXT}" "${_message}" || :
		fi
	fi
	set -u
}


set +u
if [ -n "${GITHUB_AUTH_TOKEN}" ] && [ -n "${GITHUB_BUILD_CONTEXT}" ]; then
	trap github_trap_exit EXIT
	update_github_status "${WORKDIR}" "pending" "${BUILD_CONTEXT}" "starting ${BUILD_CONTEXT}" || :
fi
set -u
