#!/usr/bin/env bash
##
##脚本运行前要保证远程服务器已经配置好ssh免密登录
##

#数据库用户名
DB_USER=root
#数据库的密码
DB_PWD=mysql@dzkj.com
#远程的备份目录
REMOTE_BACKUP_DIR=/data/mysql-backup
#远程的备份目录
REMOTE_TEMP_DIR=/data/temp
BACKUP_RECOVERY_DIR=/data/mysql-backup-recovery
#数据库的数据目录
MYSQL_DATA_DIR=/var/lib/mysql
#数据库的配置文件
MYSQL_CONFIG_FILE_PATH=/etc/my.cnf
#日志文件
LOG_FILE=/var/log/mysql-backup-recovery.log
FULL_BACKUP_RECOVERY_DIR_NAME=""
#############################以下目录为备份目录的相对目录#############################
#存放上一次的备份数据                                                               #
LAST_BACKUP_FILE_PATH=last-backup-file                                           #
#恢复前先复制当前数据库的数据到这个目录                                                #
MYSQL_CURRENT_DATA_COPY=mysql-current-data-copy                                  #
#恢复过程中的临时目录                                                               #
RECOVER_TEMP_DIR=temp                                                            #
##################################################################################
#远程服务器的IP
SERVER_IP=szdjct.com
#远程服务器的用户名
SERVER_USER=root

log(){
 echo `date +"%Y-%m-%d %H:%M:%S"`: $1 >> "$LOG_FILE"
}
#判断进程是否在运行
isRun(){
    COUNT=$(ps -ef |grep $1 |grep -v "grep" |wc -l)
if [[ ${COUNT} -eq 0 ]]; then
        return 0;
else
        return 1;
fi
}

#在备份文件夹中获取最近的一次全量备份,第一个参数为备份数据所在的文件夹
getFull(){
if [[ ! -d $1 ]];then
    return
fi
fileList=`ls $1`
for fileName in ${fileList}
do
if [[ -n ${fileName} ]];then
   checkpointFile=${fileName}"/xtrabackup_checkpoints"
   if [[ -f ${checkpointFile} ]]; then
    count=`grep "from_lsn = 0" ${checkpointFile}`
    if [[ ${count}!=0 ]]; then
        FULL_BACKUP_RECOVERY_DIR_NAME=${fileName}
        return
    fi
   fi;
fi
done
}


init(){
#停止mysql
isRun mysqld
if [[ $? -eq 1 ]];then
    service mysqld stop
fi
cd ${BACKUP_RECOVERY_DIR}
if [[ ! -d ${RECOVER_TEMP_DIR} ]];then
    mkdir ${RECOVER_TEMP_DIR}
else rm -rf RECOVER_TEMP_DIR/*
fi
if [[ ! -d ${MYSQL_CURRENT_DATA_COPY} ]];then
    mkdir ${MYSQL_CURRENT_DATA_COPY}
else rm -rf MYSQL_CURRENT_DATA_COPY/*
fi
if [[ ! -d ${LAST_BACKUP_FILE_PATH} ]];then
    mkdir ${LAST_BACKUP_FILE_PATH}
fi
if [[ "`ls -A ${MYSQL_DATA_DIR}`" != "" ]]; then
log "Copy  current mysql data to ${MYSQL_CURRENT_DATA_COPY} "
    mv ${MYSQL_DATA_DIR}/* ${MYSQL_CURRENT_DATA_COPY}
fi
}

recover(){
if [[  -d $1 ]];then
    getFull $1
    if [[ ! -d ${FULL_BACKUP_RECOVERY_DIR_NAME} ]];then
        log "Can't find the full path  backup, please make sure that the backup file if and only a full backup, Recovery interrupt!"
        return 1
    fi
    cd $1
    fileList=`ls $1`
    for fileName in ${fileList}
    do
    if [[ -n ${fileName} ]];then
       #回滚未提交的事务及同步已经提交的事务至数据文件使得数据文件处于一致性状态
       if [[ ${FULL_BACKUP_RECOVERY_DIR_NAME} = ${fileName} ]];then
       innobackupex  --apply-log  --redo-only ${fileName}
       log "Found full backup file:"${fileName}
       else
       innobackupex  --apply-log  --redo-only  --incremental ${FULL_BACKUP_RECOVERY_DIR_NAME}    --incremental-dir ${fileName}
       log "Found incremental backup file:"${fileName}
       fi
    fi
    done
    innobackupex --copy-back $1/${FULL_BACKUP_RECOVERY_DIR_NAME}
    #修改恢复的文件的拥有者为数据库所有，否则会启动失败
    chown -R mysql:mysql  ${MYSQL_DATA_DIR}
    service mysqld start
    if [[ ! $? -eq 0 ]];then
        log "Recovery is complete, but the database could not be started, please check the startup log for the database!"
    fi
    log "Recovery is success!"
    return 0
else
    log "Can't find the recover directory"
    return 2
fi
}

log "Recovery staring"
log "Begin to package the backup file by ssh"
ssh -tt ${SERVER_USER}@${SERVER_IP} << eeooff
if [[ ! -d ${RECOVER_TEMP_DIR} ]];then
    mkdir ${RECOVER_TEMP_DIR}
fi
if [[ -f ${REMOTE_TEMP_DIR}/mysql-backup.tar ]];then
    rm -rf ${REMOTE_TEMP_DIR}/mysql-backup.tar
fi
cd ${REMOTE_BACKUP_DIR}
  if [[ "`ls -A ${REMOTE_BACKUP_DIR}`" != "" ]]; then
            tar -czvf ${REMOTE_TEMP_DIR}/mysql-backup.tar ${REMOTE_BACKUP_DIR}
        fi
exit
eeooff
if [[ ! -d ${BACKUP_RECOVERY_DIR} ]];then
    mkdir ${BACKUP_RECOVERY_DIR}
fi
log "start download the backup file form server ......"
scp root@${SERVER_IP}:${REMOTE_TEMP_DIR}/mysql-backup.tar ${BACKUP_RECOVERY_DIR}
if [[ ! $? -eq 0 ]];then
log "Can't find mysql-backup.tar in server"
fi
cd ${BACKUP_RECOVERY_DIR}
if [[ -f mysql-backup.tar ]];then
    log "Start the recovery operation"
    init
    log "Unzip the files to "${RECOVER_TEMP_DIR}
    tar -zxf mysql-backup.tar -C ${RECOVER_TEMP_DIR}
    log "Unzip complete,do recovery "
    cd ${RECOVER_TEMP_DIR}
    workDir=`pwd`
   `recover ${workDir}`
    recoverCode=$?
    log "RecoverCode :${recoverCode}"
    if [[ ! ${recoverCode} = 0 ]];then
       log "Recovery failure, restore the last data!"
        if [[ "`ls -A ${BACKUP_RECOVERY_DIR}/${MYSQL_CURRENT_DATA_COPY}`" != "" ]]; then
            mv ${BACKUP_RECOVERY_DIR}/${MYSQL_CURRENT_DATA_COPY} ${MYSQL_DATA_DIR}
        fi
    fi
     if [[ "`ls -A `" != "" ]]; then
         rm -rf ../${LAST_BACKUP_FILE_PATH}/*
         mv -bf * ../${LAST_BACKUP_FILE_PATH}
     fi
    cd ..
    log "Delete temporary operation file directory!"
    rm -rf ${RECOVER_TEMP_DIR}
    rm -rf ${MYSQL_CURRENT_DATA_COPY}
    rm -rf mysql-backup.tar
    log "Recovery operation is completed"
else
    log "Can't find mysql-backup.tar"
fi
