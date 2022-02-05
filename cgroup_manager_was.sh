#!/usr/bin/env bash
###########################################################################################
:<<'__DOCUMENTATION-BLOCK__'
###########################################################################################

###########################################################################################
__DOCUMENTATION-BLOCK__
###########################################################################################

#Set environment options
#set -o errexit      # -e Any non-zero output will cause an automatic script failure
set -o pipefail     #    Any non-zero output in a pipeline will return a failure
set -o noclobber    # -C Prevent output redirection from overwriting an existing file
set -o nounset      # -u Prevent use of uninitialized variables
#set -o xtrace       # -x Same as verbose but with variable expansion

#--------------------------------------------------------------------------
#    FUNCTION       script_exit
#    SYNTAX         script_exit <exitCode>
#    DESCRIPTION    Cleans up logs, traps, flocks, and performs any other exit tasks
#--------------------------------------------------------------------------
script_exit() 
{
    #Validate the number of passed variables
    if [[ $# -gt 1 ]]
    then
        #Invalid number of arguments
        #We're just echoing this as a note, we still want the script to exit
        >&2 echo "Received an invalid number of arguments"
    fi

    #Define variables as local first
    declare l_exit_code="$1"; shift

    #Reset signal handlers to default actions
    trap - 0 1 2 3 15

    #Remove any tmp dirs/files we created
    if [[ -n ${script_name} ]] && [[ -n ${tmp_dir} ]]
    then
        find "${tmp_dir}" -name "${script_name}*" -exec rm -rf {} \;
    fi

    #Remove empty log files
    if [[ ! -s "${lofile}" ]]
    then
        rm "${lofile}" || >&2 echo "Removing null log file ${lofile} failed"
    fi

    #Cleanup old log files
    find "${lopath}" -type f -daystart -mtime +"${loretention:-14}" | while read -r line
    do
        rm "${line}" || >&2 echo "Removing old log file ${line} failed"
    done

    #Exit
    exit "${l_exit_code}"
}

#--------------------------------------------------------------------------
#     FUNCTION      script_usage
#     SYNTAX        script_usage
#     DESCRIPTION   Displays proper usage syntax for the script
#--------------------------------------------------------------------------
script_usage() #function_version=0.1.0
{
    echo ""
    echo "Usage: ./${script_file} --activate"
    echo "      -a|--activate   : Apply cgroups to all was jvms"
    echo "      -d|--deactivate : Remove cgroups from all was jvms"
    echo "      -h|--help       : Display this help"
    echo "      <nothing>       : Display existing cgroup configuration for was jvms" 
    echo ""

    exit 1
}

#--------------------------------------------------------------------------
#    FUNCTION       setup_directory
#    SYNTAX         setup_directory <DirectoryName>
#    DESCRIPTION    Accepts full directory path and verifies if it can be written to
#                   0=Success
#                   1=Failure
#                   2=Error
#--------------------------------------------------------------------------
setup_directory() 
{
    #Validate the number of passed variables
    if [[ $# -ne 1 ]]
    then
        #Invalid number of arguments
        >&2 echo "Received an invalid number of arguments"
        return 2
    fi

    #Assign variables passed
    declare l_directory=$1; shift

    #Check for the directory
    if [[ ! -a "${l_directory}" ]]
    then
        #The directory doesn't exist, try to create it
        mkdir -p "${l_directory}" 1>/dev/null 2>&1 || { rc=$? && >&2 echo "The directory ${l_directory} does not exist and could not be created" && return $rc; }
    fi

    #Check if the direcotory is writeable
    if [[ ! -w "${l_directory}" ]]
    then
        #The directory is not writeable, lets try to change that
        chmod ugo+w "${l_directory}" 1>/dev/null 2>&1 || { rc=$? && >&2 echo "The directory ${l_directory} can not be written to and permissions could not be modified" && return $rc; }
    fi

    #No Error
    return 0
}

#--------------------------------------------------------------------------
#    FUNCTION       setup_file
#    SYNTAX         setup_file <file_name>
#    DESCRIPTION    Accepts full file path and verifies if it can be written to
#                   0=Success
#                   1=Failure
#                   2=Error
#--------------------------------------------------------------------------
setup_file() 
{
    #Validate the number of passed variables
    if [[ $# -ne 1 ]]
    then
        #Invalid number of arguments
        >&2 echo "Received an invalid number of arguments"
        return 2
    fi

    #Assign variables passed
    declare l_file_path=$1; shift
    typeset l_directory="${l_file_path%/*}"

    setup_directory "${l_directory}" || return $?

    #Check if the file already exists
    if [[ -a "${l_file_path}" ]]
    then
        #The file already exists, is it writable?
        if [[ ! -w "${l_file_path}" ]]
        then
            #The file exists but is NOT writeable, lets try changing it
            chmod ugo+w "${l_file_path}" 1>/dev/null 2>&1 || { rc=$? && >&2 echo "File ${l_file_path} exists but is not writeable and permissions could not be modified" && return $rc; }
        fi
    else
        #The file does not exist, lets touch it
        touch "${l_file_path}" 1>/dev/null 2>&1 || { rc=$? && >&2 echo "File ${l_file_path} does not exist and could not be created" && return $rc; }
    fi

    #No Error
    return 0
}

#--------------------------------------------------------------------------
#     MAIN
#--------------------------------------------------------------------------
main() 
{
    #getopt is required, make sure it's available
    # -use ! and PIPESTATUS to get exit code with errexit set
    ! getopt --test > /dev/null 
    if [[ ${PIPESTATUS[0]} -ne 4 ]]
    then
        >&2 echo "enhanced getopt is required for this script but not available on this system"
        exit 1
    fi

    declare l_options=adh
    declare l_options_long=activate,deactivate,help

    # -use ! and PIPESTATUS to get exit code with errexit set
    ! l_options_parsed=$(getopt --options=$l_options --longoptions=$l_options_long --name "$0" -- "$@")
    if [[ ${PIPESTATUS[0]} -ne 0 ]]
    then
        # getopt did not like the parameters passed
        >&2 echo "getopt did not like the parameters passed"
        exit 1
    fi

    # read getopt’s output this way to handle the quoting right:
    eval set -- "$l_options_parsed"

    # now enjoy the options in order and nicely split until we see --
    while true
    do
        case "$1" in
            -a|--activate)
                activate=1
                shift 1
                ;;
            -d|--deactivate)
                deactivate=1
                shift 1
                ;;
            -h|--help)
                script_usage
                shift 1
                ;;
            --)
                shift
                break
                ;;
            *)
                >&2 echo "getopt parsing error"
                exit 1
                ;;
        esac
    done

    #Define our cgroup name
    was_cgroup_resource_controller="/sys/fs/cgroup/cpu"
    was_cgroup_prefix="was.jvm"
    was_cgroup_security_name="${was_cgroup_prefix}.sec_service"
    was_cgroup_security_path="${was_cgroup_resource_controller}/${was_cgroup_security_name}"
    was_cgroup_default_name="${was_cgroup_prefix}.default"
    was_cgroup_default_path="${was_cgroup_resource_controller}/${was_cgroup_default_name}"

    #Create a tmp file to store all existing cgroup pids
    was_cgroup_pids=$(mktemp "${tmp_dir}"/"${script_name}".XXXXX)
    grep "" ${was_cgroup_resource_controller}/${was_cgroup_prefix}.*/tasks 2>/dev/null | awk -F '[/:]' '{print $8" "$6}' | sort -nk 1 >| "${was_cgroup_pids}"

    #Create a tmp file to store current cgroup state
    was_cgroup_state_before=$(mktemp "${tmp_dir}"/"${script_name}".XXXXX)
    echo "PID JVM CGROUP" >| "${was_cgroup_state_before}"
    join --header -j 1 <(grep -F -f <(cut -d' ' -f1 "${was_cgroup_pids}") "${was_pids}") "${was_cgroup_pids}" >> "${was_cgroup_state_before}"
    grep -Fvf <(cut -d' ' -f1 "${was_cgroup_pids}") "${was_pids}" >> "${was_cgroup_state_before}"

    #Check if we should activate was cgroups
    if [[ ${activate:-0} -eq 1 ]]
    then
        #Check if our sec_service cgroup exists
        if [[ ! -d ${was_cgroup_security_path} ]]
        then
            #Nope, create it
            mkdir ${was_cgroup_security_path} || { echo "Error: Creating directory ${was_cgroup_security_path} failed" && exit 2; }
        fi

        #Check if our default cgroup exists
        if [[ ! -d ${was_cgroup_default_path} ]]
        then
            #Nope, create it
            mkdir ${was_cgroup_default_path} || { echo "Error: Creating directory ${was_cgroup_default_path} failed" && exit 2; }
        fi

        #Find and place all sec_service processes in the cgroup we created
        if [[ $(grep -c "sec_service" "${was_pids}") -gt 0 ]]
        then
            grep "sec_service" "${was_pids}" | cut -d' ' -f1 | xargs -n1 echo >| ${was_cgroup_security_path}/tasks || { echo "Error: Putting sec_service was pids in ${was_cgroup_security_path}/tasks failed" && exit 2; }
        fi

        #Find and place all ! sec_service processes in the cgroup we created
        if [[ $(grep -cv "sec_service" "${was_pids}") -gt 0 ]]
        then
            grep -v "sec_service" "${was_pids}" | cut -d' ' -f1 | xargs -n1 >| ${was_cgroup_default_path}/tasks || { echo "Error: Putting non-sec_service was pids in ${was_cgroup_default_path}/tasks failed" && exit 2; }
        fi
        
        #Save the pids in cgroups post changes
        grep "" ${was_cgroup_resource_controller}/${was_cgroup_prefix}.*/tasks 2>/dev/null | awk -F '[/:]' '{print $8" "$6}' | sort -nk 1 >| "${was_cgroup_pids}"
    fi

    #Check if we should deactivate was cgroups
    if [[ ${deactivate:-0} -eq 1 ]]
    then
        #Move all of our cgroup pids to the root cgroup
        cat ${was_cgroup_resource_controller}/${was_cgroup_prefix}.*/tasks | xargs -n1 echo >| ${was_cgroup_resource_controller}/tasks || { echo "Error: Putting ALL was pids in ${was_cgroup_resource_controller}/tasks failed" && exit 2; }
        
        #Save the pids in cgroups post changes
        grep "" ${was_cgroup_resource_controller}/${was_cgroup_prefix}.*/tasks 2>/dev/null | awk -F '[/:]' '{print $8" "$6}' | sort -nk 1 >| "${was_cgroup_pids}"
    fi

    #Output anything we need to
    if [[ ${deactivate:-0} -eq 0 ]] && [[ ${activate:-0} -eq 0 ]]
    then
        #Display the original cgroup state only to our screen, bypassing the logfile
        column -t "${was_cgroup_state_before}" 1>&3
    else
        #Find current cgroup state
        was_cgroup_state_after=$(mktemp "${tmp_dir}"/"${script_name}".XXXXX)
        echo "PID JVM CGROUP" >| "${was_cgroup_state_after}"
        join --header -j 1 <(grep -F -f <(cut -d' ' -f1 "${was_cgroup_pids}") "${was_pids}") "${was_cgroup_pids}" >> "${was_cgroup_state_after}"
        grep -Fvf <(cut -d' ' -f1 "${was_cgroup_pids}") "${was_pids}" >> "${was_cgroup_state_after}"

        #Find the difference in cgroup state
        was_cgroup_state_difference=$(mktemp "${tmp_dir}"/"${script_name}".XXXXX)
        echo "PID JVM CGROUP" >| "${was_cgroup_state_difference}"
        grep -Fxvf <(cat "${was_cgroup_state_before}") "${was_cgroup_state_after}" >> "${was_cgroup_state_difference}"

        #Display the difference in cgroup state, but only if any exists
        if [[ $(cat "${was_cgroup_state_difference}" | wc -l) -gt 1 ]]
        then
            column -t "${was_cgroup_state_difference}"
        fi
    fi
}

#Save information about our script
script_file="${0##*/}"
script_name="${script_file%.*}"
script_extension="${script_file##*.}"
script_path=$(readlink -f "$0")
script_dir="${script_path%/*}"
script_flags="$@"

#Pulls the local node name, not including any suffix
local_node=$(hostname -s)
local_node_fqdn=$(hostname -f)
local_node_os=$(uname)

#Identifies who is exeucting this script
username=$(whoami)

#Timestamp
date_stamp=$(date +"%Y.%m.%d")
time_stamp=$(date +"%Y.%m.%d.%H.%M.%S")
month_stamp=$(date +"%Y-%m")

#Various log files
lodir="/var/log"
lopath="${lodir}/${script_name}"
lofile="${lopath}/${script_name}.${time_stamp}.log"
loretention=30
#Setup Logs
setup_file "${lofile}" || { rc=$? && >&2 echo "Validating logfile ${lofile} failed" && script_exit $rc; }

#Setup temp dir
tmp_dir="/dev/shm"

#Set signal handlers to run our script_exit function
trap 'rc=$?; script_exit $rc' 0 1 2 3 15

#Check OS
if [[ "${local_node_os}" != "Linux" ]]
then
    >&2 echo ""
    >&2 echo " !!!! This script was written for Linux. Detected ${local_node_os}" | tee -a "${lofile}"
    >&2 echo ""
    exit 1
fi

#Check User
if [[ "${username}" != "root" ]]
then
    >&2 echo ""
    >&2 echo " !!!! This script should be executed by the root user. Detected ${username}" | tee -a "${lofile}"
    >&2 echo ""
    exit 1
fi

#Save the list of PIDs we will use for the remainder of this script.
#This will prevent PIDs that pop up in the middle of our execution from causing issues with assumptions
was_pids=$(mktemp ${tmp_dir}/"${script_name}".XXXXX)
pgrep -u wasadmin -af "${local_node}" | awk '{print $1" "$(NF)}' | sed "s/_${local_node}.*//g" | sort -nk 1 >| "${was_pids}"

#Check for web_ and core_ cluster jvms, we only execute if we find some
if [[ $(cut -d' ' -f2- "${was_pids}" | grep -Ec "^web_|^core_") -eq 0 ]]
then
    >&2 echo ""
    >&2 echo " !!!! No running WAS JVMs detected." | tee -a "${lofile}"
    >&2 echo ""
    exit 0
fi

#Execute main
#This syntax is necessary to tee all output to a logfile without calling a subshell. AKA, without using a |
#By copying fd1 > fd3, we can output data to the screen but NOT to our logfile by utilizing fd3
main "$@" 3>&1 1> >(tee "${lofile}") 2>&1

exit 0
