#!/bin/bash
# 用于快速排查Java的CPU性能问题(top us值过高)，自动查出运行的Java进程中消耗CPU多的线程，并打印出其线程栈，从而确定导致性能问题的方法调用。

# @Function
# Find out the highest cpu consumed threads of java processes, and print the stack of these threads.
#
# @Usage
#   $ ./show-busy-java-threads
#
# @online-doc https://github.com/oldratlee/useful-scripts/blob/dev-2.x/docs/java.md#-show-busy-java-threads
# @author Jerry Lee (oldratlee at gmail dot com)
# @author superhj1987 (superhj1987 at 126 dot com)
#
# NOTE about Bash Traps and Pitfalls:
#
# 1. DO NOT combine var declaration and assignment which value supplied by subshell!
#    for example: readonly var1=$(echo value1)
#                 local var1=$(echo value1)
#
#    declaration make exit code of assignment to be always 0,
#      aka. the exit code of command in subshell is discarded.
#      tested on bash 3.2.57/4.2.46

# NOTE: DO NOT declare var PROG as readonly, because its value is supplied by subshell.
PROG="$(basename "$0")"
readonly PROG_VERSION='2.4.0-dev'
# choosing between $0 and BASH_SOURCE
# https://stackoverflow.com/a/35006505/922688
# How can I get the source directory of a Bash script from within the script itself?
# https://stackoverflow.com/questions/59895
# Will $0 always include the path to the script?
# https://unix.stackexchange.com/questions/119929
readonly -a COMMAND_LINE=("${BASH_SOURCE[0]}" "$@")
# Get current user name via whoami command
#   See https://www.lifewire.com/current-linux-user-whoami-command-3867579
# Because if run command by `sudo -u`, env var $USER is not rewritten/correct, just inherited from outside!
#
# NOTE: DO NOT declare var USER as readonly, because its value is supplied by subshell.
USER="$(whoami)"

################################################################################
# util functions
################################################################################

# NOTE: $'foo' is the escape sequence syntax of bash
readonly ec=$'\033'      # escape char
readonly eend=$'\033[0m' # escape end
readonly nl=$'\n'        # new line

colorEcho() {
    local color=$1
    shift

    # if stdout is console, turn on color output.
    [ -t 1 ] && echo "${ec}[1;${color}m$*$eend" || echo "$@"
}

colorPrint() {
    local color=$1
    shift

    colorEcho "$color" "$@"
    [[ -n "$append_file" && -w "$append_file" ]] && echo "$@" >>"$append_file"
    [[ -n "$store_dir" && -w "$store_dir" ]] && echo "$@" >>"${store_file_prefix}$PROG"
}

# shellcheck disable=SC2120
normalPrint() {
    echo "$@"
    [[ -n "$append_file" && -w "$append_file" ]] && echo "$@" >>"$append_file"
    [[ -n "$store_dir" && -w "$store_dir" ]] && echo "$@" >>"${store_file_prefix}$PROG"
}

redPrint() {
    colorPrint 31 "$@"
}

greenPrint() {
    colorPrint 32 "$@"
}

yellowPrint() {
    colorPrint 33 "$@"
}

bluePrint() {
    colorPrint 36 "$@"
}

die() {
    redPrint "Error: $*" 1>&2
    exit 1
}

logAndRun() {
    echo "$@"
    echo
    "$@"
}

logAndCat() {
    echo "$@"
    echo
    cat
}

# print calling(quoted) command line which is able to copy and paste to rerun safely
#
# How to get the complete calling command of a BASH script from inside the script (not just the arguments)
# https://stackoverflow.com/questions/36625593
printCallingCommandLine() {
    local arg isFirst=true
    for arg in "${COMMAND_LINE[@]}"; do
        if $isFirst; then
            isFirst=false
        else
            printf ' '
        fi
        printf '%q' "$arg"
    done
    echo
}

usage() {
    local -r exit_code="${1:-0}"
    (($# > 0)) && shift
    # shellcheck disable=SC2015
    [ "$exit_code" != 0 ] && local -r out=/dev/stderr || local -r out=/dev/stdout

    (($# > 0)) && colorEcho 31 "$*$nl" >$out

    cat >$out <<EOF
Usage: ${PROG} [OPTION]... [delay [count]]
Find out the highest cpu consumed threads of java processes,
and print the stack of these threads.

Example:
  ${PROG}       # show busy java threads info
  ${PROG} 1     # update every 1 second, (stop by eg: CTRL+C)
  ${PROG} 3 10  # update every 3 seconds, update 10 times

Output control:
  -p, --pid <java pid(s)>   find out the highest cpu consumed threads from
                            the specified java process. support pid list(eg: 42,99).
                            default from all java process.
  -c, --count <num>         set the thread count to show, default is 5.
                            set count 0 to show all threads.
  -a, --append-file <file>  specifies the file to append output as log.
  -S, --store-dir <dir>     specifies the directory for storing
                            the intermediate files, and keep files.
                            default store intermediate files at tmp dir,
                            and auto remove after run. use this option to keep
                            files so as to review jstack/top/ps output later.
  delay                     the delay between updates in seconds.
  count                     the number of updates.
                            delay/count arguments imitates the style of
                            vmstat command.

jstack control:
  -s, --jstack-path <path>  specifies the path of jstack command.
  -F, --force               set jstack to force a thread dump. use when jstack
                            does not respond (process is hung).
  -m, --mix-native-frames   set jstack to print both java and native frames
                            (mixed mode).
  -l, --lock-info           set jstack with long listing.
                            prints additional information about locks.

CPU usage calculation control:
  -d, --top-delay           specifies the delay between top samples.
                            default is 0.5 (second). get thread cpu percentage
                            during this delay interval.
                            more info see top -d option. eg: -d 1 (1 second).
  -P, --use-ps              use ps command to find busy thread(cpu usage)
                            instead of top command.
                            default use top command, because cpu usage of
                            ps command is expressed as the percentage of
                            time spent running during the *entire lifetime*
                            of a process, this is not ideal in general.

Miscellaneous:
  -h, --help                display this help and exit.
  -V, --version             display version information and exit.
EOF

    exit "$exit_code"
}

progVersion() {
    echo "$PROG $PROG_VERSION"
    exit
}

################################################################################
# Check os support
################################################################################

uname | grep '^Linux' -q || die "$PROG only support Linux, not support $(uname) yet!"

################################################################################
# parse options
################################################################################

# NOTE: ARGS can not be declared as readonly!!
# readonly declaration make exit code of assignment to be always 0, aka. the exit code of `getopt` in subshell is discarded.
#   tested on bash 4.2.46
ARGS=$(
    getopt -n "$PROG" -a -o c:p:a:s:S:Pd:FmlhV \
        -l count:,pid:,append-file:,jstack-path:,store-dir:,use-ps,top-delay:,force,mix-native-frames,lock-info,help,version \
        -- "$@"
) || {
    echo
    usage 1
}
eval set -- "${ARGS}"

count=5
use_ps=false
top_delay=0.5

while true; do
    case "$1" in
    -c | --count)
        count="$2"
        shift 2
        ;;
    -p | --pid)
        pid_list="$2"
        shift 2
        ;;
    -a | --append-file)
        append_file="$2"
        shift 2
        ;;
    -s | --jstack-path)
        jstack_path="$2"
        shift 2
        ;;
    -S | --store-dir)
        store_dir="$2"
        shift 2
        ;;
    -P | --use-ps)
        use_ps=true
        shift
        ;;
    -d | --top-delay)
        top_delay="$2"
        shift 2
        ;;
    -F | --force)
        force=-F
        shift
        ;;
    -m | --mix-native-frames)
        mix_native_frames=-m
        shift
        ;;
    -l | --lock-info)
        more_lock_info=-l
        shift
        ;;
    -h | --help)
        usage
        ;;
    -V | --version)
        progVersion
        ;;
    --)
        shift
        break
        ;;
    esac
done

update_delay=${1:-0}
# Bash RegEx to check floating point numbers from user input
# https://stackoverflow.com/questions/13790763
[[ "$update_delay" =~ ^[+]?[0-9]+\.?[0-9]*$ ]] || die "update delay($update_delay) is not a positive float number!"

[ -z "$1" ] && update_count=1 || update_count=${2:-0}
[[ "$update_count" =~ ^[+]?[0-9]+$ ]] || die "update count($update_count) is not a natural number!"

if [ -n "$pid_list" ]; then
    pid_list="${pid_list//[[:space:]]/}" # delete white space
    [[ "$pid_list" =~ ^([0-9]+)(,[0-9]+)*$ ]] || die "pid(s)($pid_list) is illegal! example: 42 or 42,99,67"
fi

# check the directory of append-file(-a) mode, create if not exist.
if [ -n "$append_file" ]; then
    if [ -e "$append_file" ]; then
        [ -f "$append_file" ] || die "$append_file(specified by option -a, for storing run output files) exists but is not a file!"
        [ -w "$append_file" ] || die "file $append_file(specified by option -a, for storing run output files) exists but is not writable!"
    else
        append_file_dir="$(dirname "$append_file")"
        if [ -e "$append_file_dir" ]; then
            [ -d "$append_file_dir" ] || die "directory $append_file_dir(specified by option -a, for storing run output files) exists but is not a directory!"
            [ -w "$append_file_dir" ] || die "directory $append_file_dir(specified by option -a, for storing run output files) exists but is not writable!"
        else
            mkdir -p "$append_file_dir" || die "fail to create directory $append_file_dir(specified by option -a, for storing run output files)!"
        fi
    fi
fi

# check store directory(-S) mode, create directory if not exist.
if [ -n "$store_dir" ]; then
    if [ -e "$store_dir" ]; then
        [ -d "$store_dir" ] || die "$store_dir(specified by option -S, for storing output files) exists but is not a directory!"
        [ -w "$store_dir" ] || die "directory $store_dir(specified by option -S, for storing output files) exists but is not writable!"
    else
        mkdir -p "$store_dir" || die "fail to create directory $store_dir(specified by option -S, for storing output files)!"
    fi
fi

################################################################################
# check the existence of jstack command
################################################################################

if [ -n "$jstack_path" ]; then
    [ -f "$jstack_path" ] || die "$jstack_path is NOT found!"
    [ -x "$jstack_path" ] || die "$jstack_path is NOT executable!"
elif command -v jstack &>/dev/null; then
    jstack_path="$(command -v jstack)"
else
    [ -n "$JAVA_HOME" ] || die "jstack not found on PATH and No JAVA_HOME setting! Use -s option set jstack path manually."
    [ -f "$JAVA_HOME/bin/jstack" ] || die "jstack not found on PATH and \$JAVA_HOME/bin/jstack($JAVA_HOME/bin/jstack) file does NOT exists! Use -s option set jstack path manually."
    [ -x "$JAVA_HOME/bin/jstack" ] || die "jstack not found on PATH and \$JAVA_HOME/bin/jstack($JAVA_HOME/bin/jstack) is NOT executable! Use -s option set jstack path manually."
    jstack_path="$JAVA_HOME/bin/jstack"
fi

################################################################################
# biz logic
################################################################################

# NOTE: DO NOT declare var run_timestamp as readonly, because its value is supplied by subshell.
run_timestamp="$(date "+%Y-%m-%d_%H:%M:%S.%N")"
readonly uuid="${PROG}_${run_timestamp}_${$}_${RANDOM}"

readonly tmp_store_dir="/tmp/${uuid}"
if [ -n "$store_dir" ]; then
    readonly store_file_prefix="$store_dir/${run_timestamp}_"
else
    readonly store_file_prefix="$tmp_store_dir/${run_timestamp}_"
fi
mkdir -p "$tmp_store_dir"

cleanupWhenExit() {
    rm -rf "$tmp_store_dir" &>/dev/null
}
trap "cleanupWhenExit" EXIT

headInfo() {
    colorEcho "0;34;42" ================================================================================
    echo "$(date "+%Y-%m-%d %H:%M:%S.%N") [$((update_round_num + 1))/$update_count]: $(printCallingCommandLine)"
    colorEcho "0;34;42" ================================================================================
    echo
}

if [ -n "${pid_list}" ]; then
    readonly ps_process_select_options="-p $pid_list"
else
    readonly ps_process_select_options="-C java -C jsvc"
fi

__die_when_no_java_process_found() {
    if [ -n "${pid_list}" ]; then
        die "process($pid_list) is not running, or not java process!"
    else
        die 'No java process found!'
    fi
}

# output field: pid, thread id(lwp), pcpu, user
#   order by pcpu(percentage of cpu usage)
findBusyJavaThreadsByPs() {
    # 1. sort by %cpu by ps option `--sort -pcpu`
    # 2. use wide output(unlimited width) by ps option `-ww`
    #    avoid trunk user column to username_fo+ or $uid alike

    # shellcheck disable=SC2206
    local -a ps_cmd_line=(ps $ps_process_select_options -wwLo 'pid,lwp,pcpu,user' --sort -pcpu --no-headers)
    # DO NOT combine var ps_out declaration and assignment, because its value is supplied by subshell.
    local ps_out
    ps_out="$("${ps_cmd_line[@]}")"
    [ -n "$ps_out" ] || __die_when_no_java_process_found

    if [ -n "$store_dir" ]; then
        echo "$ps_out" | logAndCat "${ps_cmd_line[@]}" >"${store_file_prefix}$((update_round_num + 1))_ps"
    fi

    if ((count > 0)); then
        echo "$ps_out" | head -n "${count}"
    else
        echo "$ps_out"
    fi
}

# top with output field: thread id, %cpu
__top_threadId_cpu() {
    # DO NOT combine var java_pid_list declaration and assignment, because its value is supplied by subshell.
    local java_pid_list
    # shellcheck disable=SC2086
    java_pid_list="$(ps $ps_process_select_options -o pid --no-headers)"
    [ -n "$java_pid_list" ] || __die_when_no_java_process_found
    # shellcheck disable=SC2086
    java_pid_list="$(echo $java_pid_list | tr ' ' ,)" # join with ,

    # 1. sort by %cpu by top option `-o %CPU`
    #    unfortunately, top version 3.2 does not support -o option(supports from top version 3.3+),
    #    use
    #       HOME="$tmp_store_dir" top -H -b -n 1
    #    combined
    #       sort
    #    instead of
    #       HOME="$tmp_store_dir" top -H -b -n 1 -o '%CPU'
    # 2. change HOME env var when run top,
    #    so as to prevent top command output format being change by .toprc user config file unexpectedly
    # 3. use option `-d 0.5`(update interval 0.5 second) and `-n 2`(update 2 times),
    #    and use second time update data to get cpu percentage of thread in 0.5 second interval
    # 4. top v3.3, there is 1 black line between 2 update;
    #    but top v3.2, there is 2 blank lines between 2 update!
    local -a top_cmd_line=(top -H -b -d "$top_delay" -n 2 -p "$java_pid_list")
    # DO NOT combine var ps_out declaration and assignment, because its value is supplied by subshell.
    local top_out
    top_out=$(HOME="$tmp_store_dir" "${top_cmd_line[@]}")
    if [ -n "$store_dir" ]; then
        echo "$top_out" | logAndCat "${top_cmd_line[@]}" >"${store_file_prefix}$((update_round_num + 1))_top"
    fi

    # DO NOT combine var result_threads_top_info declaration and assignment, because its value is supplied by subshell.
    local result_threads_top_info
    result_threads_top_info=$(
        echo "$top_out" | awk '{
            # from text line to empty line, increase block index
            if (previousLine && !$0) blockIndex++
            # only print 4th text block(blockIndex == 3), aka. process info of second top update
            if (blockIndex == 3 && $1 ~ /^[0-9]+$/)
                print $1, $9  # $1 is thread id field, $9 is %cpu field
            previousLine = $0
        }'
    )
    [ -n "$result_threads_top_info" ] || __die_when_no_java_process_found

    echo "$result_threads_top_info" | sort -k2,2nr
}

__complete_pid_user_by_ps() {
    # ps output field: pid, thread id(lwp), user
    # shellcheck disable=SC2206
    local -a ps_cmd_line=(ps $ps_process_select_options -wwLo 'pid,lwp,user' --no-headers)
    # DO NOT combine var ps_out declaration and assignment, because its value is supplied by subshell.
    local ps_out
    ps_out="$("${ps_cmd_line[@]}")"
    if [ -n "$store_dir" ]; then
        echo "$ps_out" | logAndCat "${ps_cmd_line[@]}" >"${store_file_prefix}$((update_round_num + 1))_ps"
    fi

    local idx=0 threadId pcpu output_fields
    while read -r threadId pcpu; do
        ((count <= 0 || idx < count)) || break

        # output field: pid, threadId, pcpu, user
        output_fields="$(echo "$ps_out" |
            awk -v "threadId=$threadId" -v "pcpu=$pcpu" '$2==threadId {
                print $1, threadId, pcpu, $3; exit
            }')"
        if [ -n "$output_fields" ]; then
            ((idx++))
            echo "$output_fields"
        fi
    done
}

# output format is same as function findBusyJavaThreadsByPs
findBusyJavaThreadsByTop() {
    __top_threadId_cpu | __complete_pid_user_by_ps
}

printStackOfThreads() {
    local idx=0 pid threadId pcpu user threadId0x
    while read -r pid threadId pcpu user; do
        threadId0x="0x$(printf %x "${threadId}")"

        ((idx++))
        local jstackFile="${store_file_prefix}$((update_round_num + 1))_jstack_${pid}"
        [ -f "${jstackFile}" ] || {
            # shellcheck disable=SC2206
            local -a jstack_cmd_line=("$jstack_path" ${force} $mix_native_frames $more_lock_info ${pid})
            if [ "${user}" == "${USER}" ]; then
                # run without sudo, when java process user is current user
                logAndRun "${jstack_cmd_line[@]}" >"${jstackFile}"
            elif [ $UID == 0 ]; then
                # if java process user is not current user, must run jstack with sudo
                logAndRun sudo -u "${user}" "${jstack_cmd_line[@]}" >"${jstackFile}"
            else
                # current user is not root user, so can not run with sudo; print error message and rerun suggestion
                redPrint "[$idx] Fail to jstack busy(${pcpu}%) thread(${threadId}/${threadId0x}) stack of java process(${pid}) under user(${user})."
                redPrint "User of java process($user) is not current user($USER), need sudo to rerun:"
                yellowPrint "    sudo $(printCallingCommandLine)"
                normalPrint
                continue
            fi || {
                redPrint "[$idx] Fail to jstack busy(${pcpu}%) thread(${threadId}/${threadId0x}) stack of java process(${pid}) under user(${user})."
                normalPrint
                rm "${jstackFile}" &>/dev/null
                continue
            }
        }

        bluePrint "[$idx] Busy(${pcpu}%) thread(${threadId}/${threadId0x}) stack of java process(${pid}) under user(${user}):"

        if [ -n "$mix_native_frames" ]; then
            local sed_script="/--------------- $threadId ---------------/,/^---------------/ {
                /--------------- $threadId ---------------/b # skip first separator line
                /^---------------/d # delete second separator line
                p
            }"
        elif [ -n "$force" ]; then
            local sed_script="/^Thread ${threadId}:/,/^$/ {
                /^$/d; p # delete end separator line
            }"
        else
            local sed_script="/ nid=${threadId0x} /,/^$/ {
                /^$/d; p # delete end separator line
            }"
        fi
        {
            sed "$sed_script" -n "${jstackFile}"
            echo
        } | tee ${append_file:+-a "$append_file"} ${store_dir:+-a "${store_file_prefix}$PROG"}
    done
}

################################################################################
# Main
################################################################################

main() {
    local update_round_num
    # if update_count <= 0, infinite loop till user interrupted (eg: CTRL+C)
    for ((update_round_num = 0; update_count <= 0 || update_round_num < update_count; ++update_round_num)); do
        ((update_round_num > 0)) && sleep "$update_delay"

        [[ -n "$append_file" || -n "$store_dir" ]] && headInfo |
            tee ${append_file:+-a "$append_file"} ${store_dir:+-a "${store_file_prefix}$PROG"} >/dev/null
        ((update_count != 1)) && headInfo

        if $use_ps; then
            findBusyJavaThreadsByPs
        else
            findBusyJavaThreadsByTop
        fi | printStackOfThreads
    done
}

main
