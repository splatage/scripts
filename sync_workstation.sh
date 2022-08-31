#!/bin/bash

#apt update && apt -y install openssh-server rsync inotify-tools

source=$HOME
usr=$(whoami)
this_pc=$(hostname)
server=#remote ssh to sync to
dest=~/WORK_STATIONS/${this_pc}/


excludes_file=~/.sync_excludes
log=~/.sync_log
socket=${source}/.ssh/socket.${usr}.${server}:22

events="create,delete,move"

function start () {
    ssh -f -o 'ControlMaster=yes' -o 'ControlPersist=yes' -o 'Compression=no' -S ${socket} ${usr}@${server} "echo"
    check

    if [ ! -f ${excludes_file} ]; then
       wget https://raw.githubusercontent.com/rubo77/rsync-homedir-excludes/master/rsync-homedir-excludes.txt -O ${excludes_file}
       echo ".config/google-chrome/" >> ${excludes_file}
       echo -e ".sync_log\n.trash" >> ${excludes_file}
   fi
}


function stop () {
    ssh -O stop -S ${socket} ${usr}@${server}:22
    echo "Packing up..."
    exit
}


function watch () {
    cd $source
    IFS="+"
    awk -vSRC=$HOME/ '!/^ *#/ && NF {print "@" SRC $1}' ${excludes_file} | \
      inotifywait --fromfile - -mr \
        --timefmt '%d/%m/%y %H:%M' \
        --format '%T+%w+%f+%e' \
        --exclude '(sync_log|.*Chrome.*|recently-used|goutputstream|xsession|.*crdownload|dconf|nemo)' \
        -e ${events} ${source} | \
    while read -r time dir file code
    do 
        changed_abs=${dir}${file}
        changed_rel=${changed_abs#"$source"/}

        echo -e "\n\e[92m\e[1m** Change Detected ** \e[39m\e[0m"
        echo " Time:  $time"
        echo " Code:  $code"
        echo " File:  ${file}"
        echo " Dest:  ${usr}@${server}:${dest}"
        suffix=$(date "+%Y-%m-%d_%H-%m")

        ##
        rsync -avuz --delete --progress --relative --exclude-from=${excludes_file} -e "ssh -S ${socket}" "${changed_rel}" ${usr}@${server}:${dest}
        ##

        echo "${file} was rsynced" >> ${log} 2>&1
        echo "${file} was rsynced"
    done
}

function merge () {
        rsync -avuz --progress --relative --exclude-from=${excludes_file} -e "ssh -S ${socket}" . ${usr}@${server}:${dest}
#        rsync -avuz --progress --exclude-from=${excludes_file} -e "ssh -S ${socket}" ${usr}@${server}:${dest} .
        
}


function check () {
    ssh -O check -S ${socket} ${usr}@${server}:22

}

trap stop SIGINT

case $1 in
    start)
       start
 #      watch
    ;;
    stop)
       stop
    ;;
    watch)
       watch
    ;;
    merge)
       merge
    ;;
    check)
       check
    ;;
    *)
       echo "$0 start|stop|watch|merge|check"
    ;;
esac
