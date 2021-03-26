#!/bin/bash

# 包下载目录
src_dir=$(pwd)/00src00
postgre_port=5432
postgre_version_yum=11
postgre_version_src=11.11
# 部署postgre的目录
postgre_home=$(pwd)/postgre-${postgre_version_yum}
sys_user=postgres
unit_file_name=postgresql-${postgre_version_src}.service


# 带格式的echo函数
function echo_info() {
    echo -e "[\033[36m$(date +%T)\033[0m] [\033[32mINFO\033[0m] \033[37m$@\033[0m"
}
function echo_warning() {
    echo -e "[\033[36m$(date +%T)\033[0m] [\033[1;33mWARNING\033[0m] \033[1;37m$@\033[0m"
}
function echo_error() {
    echo -e "[\033[36m$(date +%T)\033[0m] [\033[41mERROR\033[0m] \033[1;31m$@\033[0m"
}

# 解压
function untar_tgz(){
    echo_info 解压 $1 中
    tar xf $1
    if [ $? -ne 0 ];then
        echo_error 解压出错，请检查！
        exit 2
    fi
}

# 首先判断当前目录是否有压缩包：
#   I. 如果有压缩包，那么就在当前目录解压；
#   II.如果没有压缩包，那么就检查有没有 ${src_dir} 表示的目录;
#       1) 如果有目录，那么检查有没有压缩包
#           ① 有压缩包就解压
#           ② 没有压缩包则下载压缩包
#       2) 如果没有,那么就创建这个目录，然后 cd 到目录中，然后下载压缩包，然
#       后解压
# 解压的步骤都在后面，故此处只做下载

# 语法： download_tar_gz 保存的目录 下载链接
# 使用示例： download_tar_gz /data/openssh-update https://mirrors.cloud.tencent.com/openssl/source/openssl-1.1.1h.tar.gz
function download_tar_gz(){
    download_file_name=$(echo $2 |  awk -F"/" '{print $NF}')
    back_dir=$(pwd)
    file_in_the_dir=''  # 这个目录是后面编译目录的父目录

    ls $download_file_name &> /dev/null
    if [ $? -ne 0 ];then
        # 进入此处表示脚本所在目录没有压缩包
        ls -d $1 &> /dev/null
        if [ $? -ne 0 ];then
            # 进入此处表示没有${src_dir}目录
            mkdir -p $1 && cd $1
            echo_info 下载 $download_file_name 至 $(pwd)/
            # 检测是否有wget工具
            if [ ! -f /usr/bin/wget ];then
                echo_info 安装wget工具
                yum install -y wget
            fi
            wget $2
            file_in_the_dir=$(pwd)
            # 返回脚本所在目录，这样这个函数才可以多次使用
            cd ${back_dir}
        else
            # 进入此处表示有${src_dir}目录
            cd $1
            ls $download_file_name &> /dev/null
            if [ $? -ne 0 ];then
            # 进入此处表示${src_dir}目录内没有压缩包
                echo_info 下载 $download_file_name 至 $(pwd)/
                # 检测是否有wget工具
                if [ ! -f /usr/bin/wget ];then
                    echo_info 安装wget工具
                    yum install -y wget
                fi
                wget $2
                file_in_the_dir=$(pwd)
                cd ${back_dir}
            else
                # 进入此处，表示${src_dir}目录内有压缩包
                echo_info 发现压缩包$(pwd)/$download_file_name
                file_in_the_dir=$(pwd)
                cd ${back_dir}
            fi
        fi
    else
        # 进入此处表示脚本所在目录有压缩包
        echo_info 发现压缩包$(pwd)/$download_file_name
        file_in_the_dir=$(pwd)
    fi
}

function add_user_and_group(){
    if id -g ${1} >/dev/null 2>&1; then
        echo_warning ${1}组已存在，无需创建
    else
        groupadd ${1}
        echo_info 创建${1}组
    fi
    if id -u ${1} >/dev/null 2>&1; then
        echo_warning ${1}用户已存在，无需创建
    else
        useradd -M -g ${1} -s /sbin/nologin ${1}
        echo_info 创建${1}用户
    fi
}

function install_postgresql_by_yum() {
    PG_CONFIG_FILE_PARAM=/var/lib/pgsql/${postgre_version_yum}/data/postgresql.conf
    PG_CONFIG_FILE_CONN=/var/lib/pgsql/${postgre_version_yum}/data/pg_hba.conf

    echo_info 安装浙大 postgresql 源
    rpm -Uvh http://mirrors.zju.edu.cn/postgresql/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

    echo_info 安装PostgreSQL ${postgre_version_yum}
    yum install -y postgresql${postgre_version_yum}-server

    echo_info 配置数据目录
    mkdir -p ${postgre_home}
    mv /var/lib/pgsql/* ${postgre_home}/
    chown -R postgres:postgres ${postgre_home}
    rm -rf /var/lib/pgsql
    ln -s ${postgre_home} /var/lib/pgsql
    chown -R postgres:postgres /var/lib/pgsql

    echo_info 初始化postgresql
    postgresql-${postgre_version_yum}-setup initdb
    echo_info 启动postgresql
    systemctl start postgresql-${postgre_version_yum}

    echo_info 配置postgresql命令提示符
    echo "\set PROMPT1 '%n@%/=> '" > ~/.psqlrc
    echo "\set PROMPT1 '%n@%/=> '" > /home/postgres/.psqlrc # yum安装用户默认为postgres，这里不使用变量

    echo_info 设置非postgres用户也可以登录数据库
    grep -E "^# peer改为trust，不用切换用户postgres就可以登录" ${PG_CONFIG_FILE_CONN} &> /dev/null
    if [ $? -ne 0 ];then
        sed -i '/# "local" is for Unix domain socket connections only/a # peer改为trust，不用切换用户postgres就可以登录' ${PG_CONFIG_FILE_CONN}
    fi
    sed -i 's/local[[:space:]]\+all[[:space:]]\+all[[:space:]]\+peer/local   all             all                                     trust/g' ${PG_CONFIG_FILE_CONN}
    
    echo_info 配置外部地址能访问postgresql
    grep -E "^listen_addresses[[:space:]]*=[[:space:]]*'\*'" ${PG_CONFIG_FILE_PARAM} &> /dev/null
    if [ $? -ne 0 ];then
        sed -i '/# - Connection Settings -/a listen_addresses = '\'*\''' ${PG_CONFIG_FILE_PARAM}
    fi
    sed -i 's/^#password_encryption = on/password_encryption = on/g' ${PG_CONFIG_FILE_PARAM}
    grep -E "^host[[:space:]]+all[[:space:]]+all[[:space:]]+0.0.0.0/0[[:space:]]+md5" ${PG_CONFIG_FILE_CONN} &> /dev/null
    if [ $? -ne 0 ];then
        sed -i '/# IPv4 local connections:/a host    all             all             0.0.0.0/0               md5' ${PG_CONFIG_FILE_CONN}
    fi
    echo_info 设置postgresql端口
    grep -E "^port[[:space:]]*=[[:space:]]*5432" ${PG_CONFIG_FILE_PARAM} &> /dev/null
    if [ $? -ne 0 ];then
        sed -i '/^#port[[:space:]]\+=[[:space:]]\+5432[[:space:]]\+#/a port = '${postgre_port}'' ${PG_CONFIG_FILE_PARAM}
    fi

    echo_info 重启postgresql
    systemctl daemon-reload
    systemctl restart postgresql-${postgre_version_yum}

    echo_info postgresql已部署完毕并成功启动，以下是相关信息：
    echo -e "\033[37m                  端口：${postgre_port}\033[0m"
    if [ ${postgre_port} -ne 5432 ];then
        echo -e "\033[37m                  登录命令：psql -U postgres -p ${postgre_port} [-d postgres]\033[0m"
    else
        echo -e "\033[37m                  登录命令：psql -U postgres [-d postgres]\033[0m"
    fi
}

function generate_unit_file() {
cat > /usr/lib/systemd/system/${unit_file_name} << EOF
# It's not recommended to modify this file in-place, because it will be
# overwritten during package upgrades.  It is recommended to use systemd
# "dropin" feature;  i.e. create file with suffix .conf under
# /etc/systemd/system/postgresql-11.service.d directory overriding the
# unit's defaults. You can also use "systemctl edit postgresql-11"
# Look at systemd.unit(5) manual page for more info.

# Note: changing PGDATA will typically require adjusting SELinux
# configuration as well.

# Note: do not use a PGDATA pathname containing spaces, or you will
# break postgresql-setup.
[Unit]
Description=PostgreSQL 11 database server
Documentation=https://www.postgresql.org/docs/11/static/
After=syslog.target
After=network.target

[Service]
Type=notify

User=postgres
Group=postgres

# Note: avoid inserting whitespace in these Environment= lines, or you may
# break postgresql-setup.

# Location of database directory
Environment=PGDATA=/var/lib/pgsql/11/data/

# Where to send early-startup messages from the server (before the logging
# options of postgresql.conf take effect)
# This is normally controlled by the global default set by systemd
# StandardOutput=syslog

# Disable OOM kill on the postmaster
OOMScoreAdjust=-1000
Environment=PG_OOM_ADJUST_FILE=/proc/self/oom_score_adj
Environment=PG_OOM_ADJUST_VALUE=0

ExecStartPre=/usr/pgsql-11/bin/postgresql-11-check-db-dir ${PGDATA}
ExecStart=/usr/pgsql-11/bin/postmaster -D ${PGDATA}
ExecReload=/bin/kill -HUP $MAINPID
KillMode=mixed
KillSignal=SIGINT
 

# Do not set any timeout value, so that systemd will not kill postmaster
# during crash recovery.
TimeoutSec=0

[Install]
WantedBy=multi-user.target
EOF
}

function install_postgresql_by_src() {
    echo a
}

function is_run_postgresql() {
    ps -ef | grep "postgres" | grep -v grep &> /dev/null
    if [ $? -eq 0 ];then
        echo_error 检测到postgresql正在运行中，退出
        exit 1
    fi
    if [ -d ${postgre_home} ];then
        echo_error 检测到postgresql部署目录${postgre_home}，请确认是否重复安装
        exit 2
    fi
    if [ -d /var/lib/pgsql ];then
        file_num=$(ls /var/lib/pgsql/ | wc -l)
        if [ file_num -ne 0 ];then
            echo_error 检测到postgresql部署目录/var/lib/pgsql，请确认是否重复安装
            exit 3
        fi
    fi
}

function install_main_func(){
    read -p "请输入数字选择安装类型（如需退出请输入q）：" software
    case $software in
        1)
            echo_info 即将使用 yum 部署postgresql
            # 等待1秒，给用户手动取消的时间
            sleep 1
            install_postgresql_by_yum
            ;;
        2)
            echo_info 即将使用 源码编译 部署postgresql
            sleep 1
            install_postgresql_by_src
            ;;
        q|Q)
            exit 0
            ;;
        *)
            install_main_func
            ;;
    esac
}

is_run_postgresql

echo -e "\033[31m本脚本支持两种部署方式：\033[0m"
echo -e "\033[36m[1]\033[32m yum部署postgresql\033[0m"
echo -e "\033[36m[2]\033[32m 源码编译部署postgresql\033[0m"
install_main_func