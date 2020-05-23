#!/bin/bash
CONFDIR='/etc/gost'
CONF='/etc/gost/gost.json'
TMPDIR="./.conftmp"
TMPCONF="./.conftmp/gost.json"
SERVICE_FILE='[Unit]
Description=Gost
After=network.target
Wants=network.target

[Service]
User=root
ExecStart=/usr/bin/gost -C /etc/gost/gost.json
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -TERM $MAINPID
Type=simple
KillMode=control-group
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target'

PEER_FILE='strategy   random
max_fails    1
fail_timeout    30s
reload    10s'

GOST_JSON='{
    "Debug": false,
    "Retries": 0,
    "ServeNodes": [],
    "ChainNodes": [],
    "Routes": [
        {}
    ]
}'
LIMIT='* soft nofile 51200
* hard nofile 51200'
SYS='fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mem = 25600 51200 102400
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1'
PROTO_LIST='1. tls    2. mtls   3. ws
4. mws    5. wss    6. mwss
7. h2     8. h2c    9. quic
10. kcp'
PROTO_LIST_ARRAY=($(echo "${PROTO_LIST}"))

[[ `id -u` != "0" ]] && echo -e "必须以root用户执行此脚本" && exit

function InstallDependence() {
    echo "安装必要的依赖包"
    which yum > /dev/null 2>&1 && PKM=yum
    which apt-get > /dev/null 2>&1 && PKM=apt-get
    [[ -z ${PKM} ]] && echo -e "不支持的包管理器" && return 0
    which curl > /dev/null 2>&1 || PKG="${PKG} curl"
    which wget > /dev/null 2>&1 || PKG="${PKG} wget"
    which wget > /dev/null 2>&1 || PKG="${PKG} wget"
    which gunzip > /dev/null 2>&1 || PKG="${PKG} wget"
    which host > /dev/null 2>&1 || ([[ ${PKM} = yum ]] && PKG="${PKG} bind-utils" || PKG="${PKG} dnsutils") 
    [[ -z ${PKG} ]] && return 0
    $(echo "$PKM install -y $PKG")
}

function GetLatestRelease() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" | \
        grep '"tag_name":' | \
        sed -E 's/.*"([^"]+)".*/\1/'
}

function InstallGost() {
    local ans
    [[ -e gost ]] && read -p "使用本地文件？[y/n]：" ans || ans="n"
    if [[ ${ans} = n ]]; then
        echo -e "下载安装最新gost"
        version=`GetLatestRelease ginuerzh/gost | sed -e "s|^v||"`
        wget "https://github.com/ginuerzh/gost/releases/download/v${version}/gost-linux-amd64-${version}.gz" -O gost.gz
        gunzip gost.gz
    fi
    # 清理安装的环境，防止重复安装的影响
    [[ -e /usr/bin/gost || -d /usr/bin/gost ]] && rm -rf /usr/bin/gost
    [[ -d ~/gost_back ]] && rm -rf ~/gost_back
    if [[ -d ${CONFDIR} ]]; then
        read -p "检测到系统中已存在gost配置文件，是否使用全新配置？[y/n]: " ans
        [[ ${ans} = y ]] && mv -f ${CONFDIR} ~/gost_back && mkdir -p ${CONFDIR} && \
            echo -e "${GOST_JSON}" > ${CONF} && echo "原有配置移动到 ~/gost_back"
        [[ ${ans} = n ]] && echo -e "将会使用原有文件"
    else
        mkdir -p ${CONFDIR} && echo -e "${GOST_JSON}" > ${CONF}
    fi
    cp gost /usr/bin/gost && chmod +x /usr/bin/gost
    echo -e "${SERVICE_FILE}" > /lib/systemd/system/gost.service
    which gost > /dev/null 2>&1 || (echo -e "安装失败，请重试" && return 0)
    systemctl daemon-reload && systemctl enable gost.service
    echo -e "安装成功"
}


function ConfigtoTmp() {
    [[ -d ${TMPDIR} || -e ${TMPDIR} ]] && rm -rf ${TMPDIR}
    mkdir ${TMPDIR}
    cp -r ${CONFDIR}/* ${TMPDIR}
    sed -i -e "s|${CONFDIR}|${TMPDIR}|" ${TMPCONF}
    for i in `ls -l ${CONFDIR} | awk '/^d/ {print $9}'`; do
        sed -i -e "s|${CONFDIR}|${TMPDIR}|" ${TMPDIR}/${i}/peer
    done
}

function TmptoConfig() {
    sed -i -e "s|${TMPDIR}|${CONFDIR}|" ${TMPCONF}
    for i in `ls -l ${TMPDIR} | awk '/^d/ {print $9}'`; do
        sed -i -e "s|${TMPDIR}|${CONFDIR}|" ${TMPDIR}/${i}/peer
    done
    [[ -d ${CONFDIR} ]] && rm -rf ${CONFDIR}
    mv -f ${TMPDIR} ${CONFDIR}
}

function IsAddressValid() {
    local ip=$1
    local domain=$1
    if [[ ${ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        OIFS=$IFS
        IFS='.'
        ip=(${ip})
        IFS=$OIFS
        [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 \
            && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]] && return 0
    fi
    host ${domain} > /dev/null 2>&1
    [[ $? = 0 ]] && return 0
    return 1
}

# $1->num, $2->max, $3->min
function IsNumValid() {
    local num=$1
    local min=$2
    local max=$3
    [[ ${num} =~ ^[[:digit:]]+$ && ${num} -le ${max} && ${num} -ge ${min} ]] && return 0
    return 1
}


# 检查输入的端口，
# 1. 输入无效内容 return 1
# 2. 端口已经被占用 return 2
# 3. 一切正常 return 0
# $1->proto $2->port $3->mode
function IsPortValid() {
    local proto=$1
    local port=$2
    if ! IsNumValid ${port} 0 65535; then
        return 1
    fi
    if [[ ! -z `awk -v proto=${proto} -v port=${port} \
        -F '://:|[.]/[.]conftmp/|_|/peer|/.*:[[:digit:]+]|" []]|[[] "|+' \
        '/"ServeNodes": \[ ".+" \]/ && (($2 == proto && $3 == port) || \
        ($3 == proto && $4 == port)) {print $3}' ${TMPDIR}/gost.json` ]]; then
        return 2
    fi
    if [[ ${proto} =~ udp|kcp|quic ]]; then
        if [[ ! -z `ss -nulp | awk -v port=${port} -F ' +|:' '$5 == port {print $5}'` ]]; then
            return 2
        fi
    else
        if [[ ! -z `ss -ntlp | awk -v port=${port} -F ' +|:' '$5 == port {print $5}'` ]]; then
            return 2
        fi
    fi
    return 0
}
        
function GetProtofromNum() {
    local num=$1
    local mode=$2
    if [[ ${mode} = 1 ]]; then
        [[ ${num} = 1 ]] && echo "udp"
        [[ ${num} = 2 ]] && echo "tcp"
    fi
    if [[ ${mode} = 2 ]]; then
        echo ${PROTO_LIST_ARRAY[((${num}*2-1))]}
    fi
}

function GetNumfromProto() {
    local proto=$1
    local mode=$2
    if [[ ${mode} = 1 ]]; then
        [[ ${proto} = "udp" ]] && echo "1"
        [[ ${proto} = "tcp" ]] && echo "2"
    fi
    if [[ ${mode} = 2 ]]; then
        for i in ${!PROTO_LIST_ARRAY[@]}; do
            [[ ${PROTO_LIST_ARRAY[${i}]} = ${proto} ]] && echo $(((${i}+1)/2))
        done
    fi
}

# 获取用户输入，同时检查输入是否合法，返回输入值
function InputwithCheck() {
    local var=$1
    local premessage=$2
    local readmessage=$3
    local checkfunc=$4
    local errmessage=$5
    local quitmode=$6
    local default=$7
    local ans
    while true; do
        echo -ne "${premessage}"
        read -ep "${readmessage}" ans
        if [[ ! -z ${default} ]]; then
            [[ -z ${ans} ]] && break
        fi
        if [[ ! -z ${quitmode} ]]; then
            [[ ${ans} = q ]] && break
        fi
        eval ${checkfunc} && break
        echo -ne ${errmessage}
    done
    if [[ ! -z ${default} && -z ${ans} ]]; then
        eval ${var}="${default}"
    else
        eval ${var}="${ans}"
    fi
}
        

# 添加隧道
function AddRoutes() {
    local ans serve_port serve_proto serve_ip chain_ip chain_port \
        chain_group_name chain_group_proto ssr_ip ssr_port mode
    echo -e "================================================"
    while true; do
        echo -e "*************************************************"
        InputwithCheck "mode" "1. 客户端(国内机器)\n2. 服务端(国外机器)\n" \
            "选择[序号]，输入q退出：" 'IsNumValid ${ans} 1 2' "序号无效\n" "q"
        [[ ${mode} = q ]] && return 0
        if [[ ${mode} = 1 ]]; then
            # 获取ServeNodes的监听端口和监听类型
            InputwithCheck "serve_proto" "1. UDP\n2. TCP\n" "请输入 gost 监听端口类型[序号]：" \
                'IsNumValid ${ans} 1 2' "序号无效\n" "q"
            serve_proto=`GetProtofromNum ${serve_proto} ${mode}`
            while true; do
                read -p "请输入 gost 监听端口[数字]: " serve_port
                IsPortValid ${serve_proto} ${serve_port}
                case $? in 
                    0)
                        break;
                        ;;
                    1)
                        echo -e "输入的端口格式无效"
                        ;;
                    2)
                        echo -e "该端口已被使用，请选择新的端口"
                        ;;
                esac
            done
            SERVENODES="\"ServeNodes\": [ \"${serve_proto}://:${serve_port}\" ],"
            read -p "是否使用负载均衡？[y/n]: " ans
            if [[ ${ans} = y ]]; then
                mkdir -p ${TMPDIR}/${serve_proto}_${serve_port}
                echo -e "${PEER_FILE}" > ${TMPDIR}/${serve_proto}_${serve_port}/peer
                while true; do
                    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                    InputwithCheck "chain_group_name" "" "新建协议组的名字，输入q返回上一级：" \
                        '[[ ! -e ${TMPDIR}/${serve_proto}_${serve_port}/${ans} ]]' \
                        "该协议组已经存在\n" "q"
                    [[ ${chain_group_name} = q ]] && break
                    InputwithCheck "chain_group_proto" "请选择传输协议(客户端和服务端必须保持一致)\n${PROTO_LIST}\n" \
                        "请输入传输协议[序号]，输入q返回上一级：" 'IsNumValid ${ans} 1 10' "序号无效\n" "q"
                    [[ ${chain_group_proto} = q ]] && break
                    chain_group_proto=`GetProtofromNum ${chain_group_proto} 2`
                    [[ ${chain_group_proto} = quic ]] && \
                        echo -e "peer    relay+${chain_group_proto}://:?ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}&keepalive=true" >> ${TMPDIR}/${serve_proto}_${serve_port}/peer \
                        || \
                        echo -e "peer    relay+${chain_group_proto}://:?ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}" >> ${TMPDIR}/${serve_proto}_${serve_port}/peer
                    [[ ! -e ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name} ]] && touch ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                    echo -e "直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" > ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                    sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                        -e "1 i 例如" \
                        -e "1 i www.baidu.com:443" \
                        -e "1 i 192.168.0.1:1234" \
                        -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                    nano ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                    sed -i -e "1,6 d" ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                done
                CHAINNODES="\"ChainNodes\": [ \":?peer=${TMPDIR}/${serve_proto}_${serve_port}/peer\" ]"
            else
                InputwithCheck "chain_proto" "请选择传输协议(客户端和服务端必须保持一致)\n${PROTO_LIST}\n" \
                    "请输入传输协议[序号]：" 'IsNumValid ${ans} 1 10' "序号无效\n"
                chain_proto=`GetProtofromNum ${chain_proto} 2`
                InputwithCheck "chain_ip" "" "输入服务端ip地址或域名: " \
                    'IsAddressValid ${ans}' "地址无效或域名未解析，请重新输入\n"
                InputwithCheck "chain_port" "" "输入服务端 gost 运行端口: " \
                    'IsNumValid ${ans} 0 65535' "端口无效，请重新输入\n"
                [[ ${chain_proto} = quic ]] && CHAINNODES="\"ChainNodes\": [ \"relay+${chain_proto}://${chain_ip}:${chain_port}?keepalive=true\" ]" || \
                    CHAINNODES="\"ChainNodes\": [ \"relay+${chain_proto}://${chain_ip}:${chain_port}\" ]"
            fi
        else  
         	# 获取ServeNodes的监听端口和监听类型
            InputwithCheck "serve_proto" "请选择传输协议(客户端和服务端必须保持一致)\n${PROTO_LIST}\n" \
                "请输入传输协议[序号]：" 'IsNumValid ${ans} 1 10' "序号无效\n"
            serve_proto=`GetProtofromNum ${serve_proto} ${mode}`
            while true; do
                read -p "请输入 gost 监听端口[数字]: " serve_port
                IsPortValid ${serve_proto} ${serve_port}
                case $? in 
                    0)
                        break;
                        ;;
                    1)
                        echo -e "输入的端口格式无效"
                        ;;
                    2)
                        echo -e "该端口已被使用，请选择新的端口"
                        ;;
                esac
            done
            read -p "是否使用负载均衡？[y/n]: " ans
            if [[ ${ans} = y ]]; then
                mkdir -p ${TMPDIR}/${serve_proto}_${serve_port}
                echo -e "${PEER_FILE}" > ${TMPDIR}/${serve_proto}_${serve_port}/peer
                echo -e "peer    relay+${serve_proto}://:${serve_port}/:?ip=${TMPDIR}/${serve_proto}_${serve_port}/ip" >> ${TMPDIR}/${serve_proto}_${serve_port}/peer
                [[ ! -e ${TMPDIR}/${serve_proto}_${serve_port}/ip ]] && touch ${TMPDIR}/${serve_proto}_${serve_port}/ip
                echo -e "直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" > ${TMPDIR}/${serve_proto}_${serve_port}/ip
                sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                    -e "1 i 例如" \
                    -e "1 i www.baidu.com:443" \
                    -e "1 i 192.168.0.1:1234" \
                    -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" ${TMPDIR}/${serve_proto}_${serve_port}/ip
                nano ${TMPDIR}/${serve_proto}_${serve_port}/ip
                sed -i -e "1,6 d" ${TMPDIR}/${serve_proto}_${serve_port}/ip
                SERVENODES="\"ServeNodes\": [ \":?peer=${TMPDIR}/${serve_proto}_${serve_port}/peer\" ],"
            else
                InputwithCheck "ssr_ip" "" "SSR服务的ip地址或域名(与gost运行在同一机器直接回车)：" \
                    'IsAddressValid ${ans}' "无效的地址，请重新输入\n" "" "127.0.0.1"
                InputwithCheck "ssr_port" "" "SSR服务的端口：" 'IsNumValid ${ans} 0 65535' \
                    "输入的端口无效，请重新输入\n" ""
                SERVENODES="\"ServeNodes\": [ \"relay+${serve_proto}://:${serve_port}/${ssr_ip}:${ssr_port}\" ],"
            fi
            CHAINNODES="\"ChainNodes\": []"
        fi
        sed -i -e "/`echo -e ${SERVENODES}`/,+1 d" ${TMPDIR}/gost.json
        sed -i -e "/\"Routes\": \[/ a \ \ \ \ \ \ \ \ {" -e "/\"Routes\": \[/ a \ \ \ \ \ \ \ \ \ \ \ \ ${SERVENODES}" -e "/\"Routes\": \[/ a \ \ \ \ \ \ \ \ \ \ \ \ ${CHAINNODES}" -e "/\"Routes\": \[/ a \ \ \ \ \ \ \ \ }," ${TMPDIR}/gost.json
        echo -e "************************************************"
    done
    echo -e "==============================================="
}

function GetPortInfo() {
    local mode serve_port serve_proto serve_info chain_info nr_start nr_serve \
        nr_chain nr_end peerfile chain_proto iplist iplist_file listen_info
    serve_proto=`echo $1 | awk -F ',' '{print $1}'`
    serve_port=`echo $1 | awk -F ',' '{print $2}'`
    listen_info="${serve_proto}:${serve_port}"
    peerfile=${TMPDIR}/${serve_proto}_${serve_port}/peer
    nr_serve=`awk -v serve_proto=${serve_proto} -v serve_port=${serve_port} \
        -F '://:|[.]/[.]conftmp/|/peer|" []]|[[] "|/.*:[[:digit:]+]|_|+' \
        '/"ServeNodes": \[ ".+" \]/ && (($2 == serve_proto && $3 == serve_port) || \
        ($3 == serve_proto && $4 == serve_port)) {print NR}' ${TMPCONF}`
    [[ -z ${nr_serve} ]] && return 1
    nr_chain=$((${nr_serve}+1))
    nr_start=$((${nr_serve}-1))
    if [[ ${serve_proto} =~ tcp|udp ]]; then
        if [[ ! -z `awk -v nr=${nr_chain} -F ':|"' 'NR==nr {print $5}' ${TMPCONF}` ]]; then
            mode=0
            chain_info=`awk -v nr=${nr_chain} -F '+|(://)|"|:|[?]' 'NR==nr {print "("$6","$7":"$8")"}' ${TMPCONF}`
            serve_info="无"
        else
            mode=1
            local temp=$IFS; IFS=$'\n'
            for i in `cat ${peerfile} | sed -n -e '/^peer/ p'`
            do
                chain_group_proto=`echo ${i} | awk -F '+|(://)' '{print $2}'`
                chain_group_name=`echo ${i} | awk -F "${TMPDIR}/${serve_proto}_${serve_port}/|[&]" '{print $2}'`
                iplist_file=`echo ${i} | awk -F 'ip=|[&]' '{print $2}'`
                iplist=`sed ':a ; N;s/\n/,/ ; t a ; ' ${iplist_file}`
                chain_info="${chain_info}(${chain_group_name},${chain_group_proto},${iplist})"
                serve_info="无"
            done
            IFS=${temp}
        fi
    else
        if [[ ! -z `awk -v nr=${nr_serve} -F ':|"' 'NR==nr {print $5}' ${TMPCONF}` ]]; then
            mode=2
            serve_info=`awk -v nr=${nr_serve} -F '://:|[[] "|:|/|" []]|+' 'NR==nr {print "("$4","$6":"$7")"}' ${TMPCONF}`
            chain_info="无"
        else
            mode=3
            iplist_file=`awk -F 'ip=' '/^peer/ {print $2}' ${peerfile}`
            iplist=`sed ':a ; N;s/\n/,/ ; t a ; ' ${iplist_file}`
            serve_info="(${serve_proto},${iplist})"
            chain_info="无"
        fi
    fi
    echo "${listen_info}|${mode}|${serve_info}|${chain_info}|${nr_start}"
}

function GetAllPortsandProto() {
    awk -F '[[] "|" []]|[[] "relay[+]|[[] ":[?]peer=[.]/[.]conftmp/|/peer" []]' \
        '/"ServeNodes": \[ ".+" \]/ {print $2}' ${TMPCONF} | \
        awk -F '://:|_|/' '{print $1","$2}'
}

function ListRoutes() {
    [[ -z `GetAllPortsandProto` ]] && echo -e "尚未添加任何转发线路" && return 0
    for i in `GetAllPortsandProto`; do
        GetPortInfo $i | awk -F '|' 'BEGIN {print "========================================="} \
            { \
                print "监听端口: " $1; \
                if ($2==0) print "工作模式: 客户端无负载均衡\n" "转发(协议,地址): " $4; \
                else if ($2==1)  print "工作模式: 客户端负载均衡\n" "转发(协议组,协议,地址...): " $4; \
                else if ($2==2)  print "工作模式: 服务端无负载均衡\n" "转发(SSR 地址): " $3; \
                else if ($2==3)  print "工作模式: 服务端负载均衡\n" "转发(SSR 地址...): " $3 \
                } \
            END {print "========================================="}'
    done
}

function EditRoutes() {
    echo -e "=======================修改线路========================="
    local serve_port mode ans nr_start nr_serve nr_serve nr_end port_info \
        serve_proto chain_group_proto chain_group_name serve_port_des serve \
        ssr_ip ssr_ip_des serve_proto_des serve_port_des ssr_port ssr_port_des
    while true; do
        local port_list=(`GetAllPortsandProto`)
        [[ -z ${port_list} ]] && echo -e "尚未添加任何转发线路" && return 0
        echo -e "当前配置中的监听协议和端口："
        for i in ${!port_list[@]}; do
            echo -e "$((${i}+1)). ${port_list[${i}]}"
        done
        InputwithCheck "serve" "" "输入要修改的端口[序号][输入q退出]: " \
            'IsNumValid ${ans} 1 ${#port_list[@]}' "序号无效\n" "q"
        [[ ${serve} = q ]] && return 0
        serve=${port_list[$((${serve}-1))]}
        serve_port=`echo ${serve} | awk -F ',' '{print $2}'`
        serve_proto=`echo ${serve} | awk -F ',' '{print $1}'`
        while true; do
            serve="${serve_proto},${serve_port}"
            port_info=`GetPortInfo ${serve}`
            mode=`echo ${port_info} | awk -F '|' '{print $2}'`
            nr_start=`echo ${port_info} | awk -F '|' '{print $5}'`
            nr_serve=$((${nr_start}+1))
            nr_chain=$((${nr_start}+2))
            nr_end=$((${nr_start}+3))
            echo -e "***************修改线路>>修改端口${serve}***************"
            InputwithCheck "mode_edit" "1. 修改监听\n2. 修改转发\n" \
                "选择[序号][输入q返回上一级]：" 'IsNumValid ${ans} 1 2' "序号无效\n" "q" ""
            [[ ${mode_edit} = q ]] && break
            case ${mode_edit} in
                1)
                    case ${mode} in
                        0)
                            num=`GetNumfromProto ${serve_proto} 1`
                            InputwithCheck "serve_proto_des" "1. UDP\n2. TCP\n" "修改协议为[序号][不修改直接回车][输入q返回上一级]：" \
                                'IsNumValid ${ans} 1 2' "无效的序号\n" "q" "${num}"
                            [[ ${serve_proto_des} = q ]] && break
                            serve_proto_des=`GetProtofromNum ${serve_proto_des} 1`
                            InputwithCheck "serve_port_des" "" "修改端口为[不修改直接回车][输入q返回上一级]：" \
                                'IsPortValid ${serve_proto} ${ans}' "无效的端口\n" "q" "${serve_port}"
                            [[ ${serve_port_des} = q ]] && break
                            sed -i -e "${nr_serve} s/${serve_proto}/${serve_proto_des}/" \
                                -e "${nr_serve} s/${serve_port}/${serve_port_des}/" ${TMPCONF}
                            serve_port=${serve_port_des}; serve_proto=${serve_proto_des}; unset serve_proto_des serve_port_des
                            ;;
                        1)
                            num=`GetNumfromProto ${serve_proto} 1`
                            InputwithCheck "serve_proto_des" "1. UDP\n2. TCP\n" "修改协议为[序号][不修改直接回车][输入q返回上一级]：" \
                                'IsNumValid ${ans} 1 2' "无效的序号\n" "q" "${num}"
                            [[ ${serve_proto_des} = q ]] && break
                            serve_proto_des=`GetProtofromNum ${serve_proto_des} 1`
                            InputwithCheck "serve_port_des" "" "修改端口为[不修改直接回车][输入q返回上一级]：" \
                                'IsPortValid ${serve_proto} ${ans}' "无效的端口\n" "q" "${serve_port}"
                            [[ ${serve_port_des} = q ]] && break
                            sed -i -r -e "${nr_serve} s/${serve_proto}/${serve_proto_des}/" \
                                -e "${nr_serve} s/${serve_port}/${serve_port_des}/" \
                                -e "${nr_chain} s|(${TMPDIR}/)${serve_proto}_${serve_port}|\1${serve_proto_des}_${serve_port}|" ${TMPCONF}
                            sed -i -r -e "s|(${TMPDIR}/)${serve_proto}_${serve_port}|\1${serve_proto_des}_${serve_port_des}|" ${TMPDIR}/${serve_proto}_${serve_port}/peer
                            mv ${TMPDIR}/${serve_proto}_${serve_port} ${TMPDIR}/${serve_proto_des}_${serve_port_des}
                            serve_port=${serve_port_des}; serve_proto=${serve_proto_des}; unset serve_proto_des serve_port_des
                            ;;
                        2)
                            num=`GetNumfromProto ${serve_proto} 2`
                            InputwithCheck "serve_proto_des" "${PROTO_LIST}\n" "修改协议为[序号][不修改直接回车][输入q返回上一级]：" \
                                'IsNumValid ${ans} 1 10' "无效的序号\n" "q" "${num}"
                            [[ ${serve_proto_des} = q ]] && break
                            serve_proto_des=`GetProtofromNum ${serve_proto_des} 2`
                            InputwithCheck "serve_port_des" "" "修改端口为[不修改直接回车][输入q返回上一级]：" \
                                'IsPortValid ${serve_proto} ${ans}' "无效的端口\n" "q" "${serve_port}"
                            [[ ${serve_port_des} = q ]] && break
                            sed -i -e "${nr_serve} s/${serve_proto}/${serve_proto_des}/" \
                                -e "${nr_serve} s/${serve_port}/${serve_port_des}/" ${TMPCONF}
                            serve_port=${serve_port_des}; serve_proto=${serve_proto_des}; unset serve_proto_des serve_port_des
                            ;;
                        3)
                            num=`GetNumfromProto ${serve_proto} 2`
                            InputwithCheck "serve_proto_des" "${PROTO_LIST}\n" "修改协议为[序号][不修改直接回车][输入q返回上一级]：" \
                                'IsNumValid ${ans} 1 10' "无效的序号\n" "q" "${num}"
                            [[ ${serve_proto_des} = q ]] && break
                            serve_proto_des=`GetProtofromNum ${serve_proto_des} 2`
                            InputwithCheck "serve_port_des" "" "修改端口为[不修改直接回车][输入q返回上一级]：" \
                                'IsPortValid ${serve_proto} ${ans}' "无效的端口\n" "q" "${serve_port}"
                            [[ ${serve_port_des} = q ]] && break
                            sed -i -e "${nr_serve} s/${serve_proto}_${serve_port}/${serve_proto_des}_${serve_port_des}/" ${TMPCONF}
                            sed -i -r -e "s|(${TMPDIR}/)${serve_proto}_${serve_port}|\1${serve_proto_des}_${serve_port_des}|" ${TMPDIR}/${serve_proto}_${serve_port}/peer
                            mv ${TMPDIR}/${serve_proto}_${serve_port} ${TMPDIR}/${serve_proto_des}_${serve_port_des}
                            serve_port=${serve_port_des}; serve_proto=${serve_proto_des}; unset serve_proto_des serve_port_des
                            ;;
                    esac
                    ;;
                2)
                    case ${mode} in
                        0)
                            chain_info=`echo ${port_info} | awk -F '|' '{print $4}'`
                            chain_proto=`echo ${chain_info} | awk -F '[(),:]' '{print $2}'`
                            chain_ip=`echo ${chain_info} | awk -F '[(),:]' '{print $3}'`
                            chain_port=`echo ${chain_info} | awk -F '[(),:]' '{print $4}'`
                            num=`GetNumfromProto ${chain_proto} 2`
                            InputwithCheck "chain_proto_des" "${PROTO_LIST}\n" "转发协议修改为[序号][不修改直接回车][q返回上一级]：" \
                                'IsNumValid ${ans} 1 10' "序号无效\n" "q" "${num}"
                            [[ ${chain_proto_des} = q ]] && break
                            chain_proto_des=`GetProtofromNum ${chain_proto_des} 2`
                            InputwithCheck "chain_ip_des" "" "转发目标地址修改为[ip或域名][不修改直接回车][q返回上一级]：" \
                                'IsAddressValid ${ans}' "地址无效(域名需要先解析)\n" "q" "${chain_ip}"
                            [[ ${chain_ip_des} = q ]] && break
                            InputwithCheck "chain_port_des" "" "转发目标端口修改为[不修改直接回车][q返回上一级]：" \
                                'IsNumValid ${ans} 0 65535' "端口无效\n" "q" "${chain_port}"
                            [[ ${chain_port_des} = q ]] && break
                            [[ ${chain_proto_des} = quic ]] && \
                                sed -i -e "${nr_chain} c \ \ \ \ \ \ \ \ \ \ \ \ \"ChainNodes\": [ \"relay+${chain_proto_des}://${chain_ip_des}:${chain_port_des}?keepalive=true\" ]" ${TMPCONF} \
                                || \
                                sed -i -e "${nr_chain} c \ \ \ \ \ \ \ \ \ \ \ \ \"ChainNodes\": [ \"relay+${chain_proto_des}://${chain_ip_des}:${chain_port_des}\" ]" ${TMPCONF}
                            chain_proto=${chain_proto_des}; chain_ip=${chain_ip_des}; chain_port=${chain_port_des}; unset chain_proto_des chain_ip_des chain_port_des 
                            ;;
                        1)
                            while true; do
                                echo -e "#########修改线路>>修改端口${serve}>>修改转发###########"
                                echo -e "当前端口负载均衡协议组如下所示："
                                awk -F '+|(://:)|/' '/peer/ {print "协议组名：",$6,"协议：",$2}' \
                                    ${TMPDIR}/${serve_proto}_${serve_port}/peer
                                InputwithCheck "client_edit_mode" "选择操作：\n1. 增加协议组\n2. 修改已有协议组\n3. 删除协议组\n" \
                                    "选择[序号][输入q返回上一级]：" 'IsNumValid ${ans} 1 3' "序号无效\n" "q" ""
                                [[ ${client_edit_mode} = q ]] && break
                                case ${client_edit_mode} in
                                    1)
                                        while true; do
                                            echo -e "~~~~~~~~~~~~~~~~~端口${serve}增加协议组~~~~~~~~~~~~~~~~~"
                                            InputwithCheck "chain_group_name" "" "新建协议组的名称[输入q返回上一级]：" \
                                                '[[ ! -e ${TMPDIR}/${serve_proto}_${serve_port}/${ans} ]]' \
                                                "该协议组已存在\n" "q" ""
                                            [[ ${chain_group_name} = q ]] && break
                                            InputwithCheck "chain_group_proto" "${PROTO_LIST}\n" "输入协议[序号][输入q返回上一级]：" \
                                                'IsNumValid ${ans} 1 10' "序号无效\n" "q" ""
                                            chain_group_proto=`GetProtofromNum ${chain_group_proto} 2`
                                            [[ ! -e ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name} ]] && touch ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                            echo -e "直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" > ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                            sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                                                -e "1 i 例如" \
                                                -e "1 i www.baidu.com:443" \
                                                -e "1 i 192.168.0.1:1234" \
                                                -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                            nano ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                            sed -i -e "1,6 d" ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                            [[ ${chain_group_proto} = quic ]] && \
                                                echo -e "peer    relay+${chain_group_proto}://:?ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}&keepalive=true" >> ${TMPDIR}/${serve_proto}_${serve_port}/peer \
                                                || \
                                                echo -e "peer    relay+${chain_group_proto}://:?ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}" >> ${TMPDIR}/${serve_proto}_${serve_port}/peer
                                            echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                                        done
                                        ;;
                                    2)
                                        while true; do
                                            echo -e "~~~~~~~~~~~~~~~~~端口${serve}修改协议组~~~~~~~~~~~~~~~~~"
                                            chain_group_proto=`awk -F '+|(://:)|/' '/peer/ {print $2}' ${TMPDIR}/${serve_proto}_${serve_port}/peer`
                                            num=`GetNumfromProto ${chain_group_proto_des} 2`
                                            InputwithCheck "chain_group_name" "" "输入要修改的协议组名称[输入q返回上一级]：" \
                                                '[[ ! -z `ls ${TMPDIR}/${serve_proto}_${serve_port}/ | grep ${ans}` ]]' "该协议组\n" "q" "${chain_group_name}"
                                            [[ ${chain_group_name} = q ]] && break
                                            InputwithCheck "chain_group_proto_des" "${PROTO_LIST}\n" "输入协议[序号][不修改直接回车][输入q返回上一级]：" \
                                                'IsNumValid ${ans} 1 10' "序号无效\n" "q" "num"
                                            chain_group_proto_des=`GetProtofromNum ${chain_group_proto_des} 2`
                                            read -p "是否修改协议组内转发地址?[y/n]: " ans
                                            if [[ ${ans} = y ]]; then
                                                sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                                                    -e "1 i 例如" \
                                                    -e "1 i www.baidu.com:443" \
                                                    -e "1 i 192.168.0.1:1234" \
                                                    -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" \
                                                    -e "1 i 直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                                nano ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                                sed -i -e "1,6 d" ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                            fi
                                            [[ ${chain_group_proto_des} = quic ]] && \
                                                sed -i -e "\|ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}| c peer\ \ \ \ relay+${chain_group_proto_des}://:?ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}&keepalive=true" ${TMPDIR}/${serve_proto}_${serve_port}/peer \
                                                || \
                                                sed -i -e "\|ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}| c peer\ \ \ \ relay+${chain_group_proto_des}://:?ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}" ${TMPDIR}/${serve_proto}_${serve_port}/peer
                                            unset num chain_group_proto_des
                                            echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                                        done
                                        ;;
                                    3)
                                        while true; do
                                            echo -e "~~~~~~~~~~~~~~~~~端口${serve}删除协议组~~~~~~~~~~~~~~~~~"
                                            InputwithCheck "chain_group_name" "" "输入要删除的协议组名称[输入q退出]: " \
                                                '[[ ! -z `ls ${TMPDIR}/${serve_proto}_${serve_port}/ | grep ${ans}` ]]' \
                                                "该协议组不存在" "q" ""
                                            [[ ${chain_group_name} = q ]] && break
                                            rm -rf ${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}
                                            sed -i -e "\|ip=${TMPDIR}/${serve_proto}_${serve_port}/${chain_group_name}| d" ${TMPDIR}/${serve_proto}_${serve_port}/peer
                                            echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
                                        done
                                        ;;
                                esac
                                echo -e "########################################################"
                            done
                            ;;
                        2)
                            ssr_info=`echo ${port_info} | awk -F '|' '{print $3}'`
                            ssr_ip=`echo ${ssr_info} | awk -F '[(),:]' '{print $3}'`
                            ssr_port=`echo ${ssr_info} | awk -F '[(),:]' '{print $4}'`
                            InputwithCheck "ssr_ip_des" "" "转发目标ssr地址修改为[ip或域名][不修改直接回车][q返回上一级]：" \
                                'IsAddressValid ${ans}' "地址无效(域名需要先解析)\n" "q" "${ssr_ip}"
                            [[ ${ssr_ip_des} = q ]] && break
                            InputwithCheck "ssr_port_des" "" "转发目标ssr端口修改为[不修改直接回车][q返回上一级]：" \
                                'IsNumValid ${ans} 0 65535' "端口无效\n" "q" "${ssr_port}"
                            [[ ${ssr_port_des} = q ]] && break
                            sed -i -e "${nr_serve} c \ \ \ \ \ \ \ \ \ \ \ \ \"ServeNodes\": [ \"relay+${serve_proto}://:${serve_port}/${ssr_ip_des}:${ssr_port_des}\" ]," ${TMPCONF}
                            ssr_ip="${ssr_ip_des}"; ssr_port="${ssr_port_des}"; unset ssr_ip_des ssr_port_des
                            ;;
                        3)
                            sed -i -e "1 i 输入服务器地址和端口，格式 ip(或域名):port" \
                                -e "1 i 例如" \
                                -e "1 i www.baidu.com:443" \
                                -e "1 i 192.168.0.1:1234" \
                                -e "1 i 修改完 Ctrl+o 保存；再 Ctrl+x 退出" \
                                -e "1 i 直接在这行下面输入，包括这行在内，上面的内容不允许删除，否则后果自负" ${TMPDIR}/${serve_proto}_${serve_port}/ip
                            nano ${TMPDIR}/${serve_proto}_${serve_port}/ip
                            sed -i -e "1,6 d" ${TMPDIR}/${serve_proto}_${serve_port}/ip
                            ;;
                    esac
                    ;;
            esac
            echo -e "********************************************************"
        done
    done
    echo -e "======================================================="
}

function DeleteRoutes() {
    [[ -z `GetAllPortsandProto` ]] && echo -e "尚未添加任何转发线路" && return 0
    local nr ans serve_port
    echo -e "=======================删除转发========================="
    while true; do
        read -p "输入要删除的本地监听端口, 输入q退出: " serve_port
        [[ ${serve_port} = q ]] && break
        read -p "输入该端口对应的协议，输入q退出：" serve_proto
        [[ ${serve_proto} = q ]] && break
        [[ -z `GetPortInfo ${serve_proto},${serve_port}` ]] && echo -e "${serve_proto}:${serve_port}不存在" && continue
        nr=`GetPortInfo ${serve_proto},${serve_port} | awk -F '|' '{print $5}'`
        sed -i -e "${nr},$((${nr}+3)) d" ${CONF}
        rm -rf ${CONFDIR}/${serve_proto}_${serve_port}
        echo -e "端口${serve_port}(${serve_proto})的相关配置已经删除"
    done
    echo -e "========================================================"
}

while true; do
    echo -e "\n"
    echo -e "选择任务："
    echo -e "1. 安装"
    echo -e "2. 添加"
    echo -e "3. 查看"
    echo -e "4. 修改"
    echo -e "5. 删除"
    echo -e "6. 查看实时日志"
    echo -e "7. 启动/重启gost"
    echo -e "8. 停止gost"
    echo -e "9. 清理所有gost相关文件"
    echo -e "10. 优化网络连接参数(抄的，效果未知，执行一次就行)"
    read -p "选择一个任务[序号，按 q 或者 Ctrl+c 退出脚本]: " ans
    case ${ans} in
        1)
            echo -e "\n"
            InstallDependence
            InstallGost
            ;;
        2)
            echo -e "\n"
            ConfigtoTmp
            AddRoutes
            TmptoConfig
            ;;
        3)
            echo -e "\n"
            ConfigtoTmp
            ListRoutes
            TmptoConfig
            ;;
        4)
            echo -e "\n"
            ConfigtoTmp
            EditRoutes
            TmptoConfig
            ;;
        5)
            echo -e "\n"
            DeleteRoutes
            ;;
        6)
            journalctl -u gost -f
            ;;
        7)
            echo -e "\n"
            systemctl stop gost > /dev/null
            sleep 1s
            systemctl start gost.service
            sleep 2s
            if [[ ! -z `ss -ntlp | grep gost` ]]; then
                echo -e "gost 已启动/重新启动" && continue
            else
                echo -e "启动失败"
            fi
            ;;
        8)
            echo -e "\n"
            systemctl stop gost.service > /dev/null
            sleep 2s
            if [[ -z `ss -ntlp | grep gost` ]]; then
                echo -e "gost 已停止" && continue
            else
                echo -e "停止失败"
            fi
            ;;
        9)
            echo -e "\n"
            systemctl stop gost && systemctl disable gost
            rm -rf /usr/bin/gost && rm -rf /etc/gost && rm -rf /lib/systemd/system/gost.service
            systemctl daemon-reload
            echo -e "已清除所有与gost相关文件"
            ;;
        10)
            echo -e "\n"
            echo -e "${LIMIT}" >> /etc/security/limits.conf
            ulimit -n 51200
            echo -e "${SYS}" >> /etc/sysctl.conf
            sysctl -p
            echo -e "优化完成"
            ;;
        q)
            break
            ;;
    esac
done
