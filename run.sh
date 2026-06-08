#!/bin/bash

stack_name="lorawan-stack-v2"
curr_path=$(realpath .)

function log_yellow()
{
    echo -e "\033[33m$@\033[0m"
}

function log_error()
{
    echo -e "\033[31mError:$@\033[0m"
}

function log_warn()
{
    echo -e "\033[33mWarning:$@\033[0m"
}

function log_info()
{
    echo -e "\033[37mInfo:$@\033[0m"
}

function log()
{
    echo -e "\033[37m$@\033[0m"
}

function detect_host_primary_mac()
{
    local iface mac p

    _is_virtual_iface() {
        case "$1" in
            lo|docker*|br-*|veth*|virbr*|tun*|tap*|wg*) return 0 ;;
        esac
        # Some veth pairs don't start with "veth" (rare) — detect by DEVTYPE.
        if [ -f "/sys/class/net/$1/uevent" ] && grep -q "^DEVTYPE=veth$" "/sys/class/net/$1/uevent" 2>/dev/null; then
            return 0
        fi
        return 1
    }

    _read_mac() {
        mac=$(cat "/sys/class/net/$1/address" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
        if [[ "${mac}" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] && [[ "${mac}" != "00:00:00:00:00:00" ]]; then
            echo "${mac}"
            return 0
        fi
        return 1
    }

    _is_physical_up() {
        # Physical NICs usually have a device symlink and operstate up.
        [ -e "/sys/class/net/$1/device" ] || return 1
        [ "$(cat "/sys/class/net/$1/operstate" 2>/dev/null)" = "up" ] || return 1
        return 0
    }

    # 1) Prefer physical+UP interfaces first (best match for "device real MAC").
    for p in /sys/class/net/*/address; do
        iface=$(basename "$(dirname "$p")")
        _is_virtual_iface "${iface}" && continue
        _is_physical_up "${iface}" || continue
        _read_mac "${iface}" && return 0
    done

    # 2) Next, try default-route interface(s) (can be multiple) but still skip virtual ones.
    while read -r iface; do
        [ -z "${iface}" ] && continue
        _is_virtual_iface "${iface}" && continue
        _read_mac "${iface}" && return 0
    done < <(ip -o route show default 0.0.0.0/0 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1)}}')

    # 3) Final fallback: first non-virtual NIC MAC.
    for p in /sys/class/net/*/address; do
        iface=$(basename "$(dirname "$p")")
        _is_virtual_iface "${iface}" && continue
        _read_mac "${iface}" && return 0
    done

    return 1
}

function update_env_primary_mac()
{
    local mac
    mac=$(detect_host_primary_mac)
    if [ -z "${mac}" ]; then
        log_warn "Could not detect host primary MAC; CHIRPSTACK_PRIMARY_MAC not updated"
        return 0
    fi

    if [ -f "${curr_path}/.env" ]; then
        if grep -q '^CHIRPSTACK_PRIMARY_MAC=' "${curr_path}/.env"; then
            sed -i "s/^CHIRPSTACK_PRIMARY_MAC=.*/CHIRPSTACK_PRIMARY_MAC=${mac}/" "${curr_path}/.env"
        else
            echo "CHIRPSTACK_PRIMARY_MAC=${mac}" >> "${curr_path}/.env"
        fi
    else
        echo "CHIRPSTACK_PRIMARY_MAC=${mac}" > "${curr_path}/.env"
    fi
    export CHIRPSTACK_PRIMARY_MAC="${mac}"
    log_info "Detected host MAC: ${mac}"
}

function detect_host_timezone()
{
    local tz target

    if [ -r /etc/timezone ]; then
        tz=$(tr -d '\r\n' < /etc/timezone | tr -d '[:space:]')
        if [ -n "${tz}" ]; then
            echo "${tz}"
            return 0
        fi
    fi

    if command -v timedatectl >/dev/null 2>&1; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null | tr -d '[:space:]')
        if [ -n "${tz}" ] && [ "${tz}" != "n/a" ]; then
            echo "${tz}"
            return 0
        fi
    fi

    if [ -e /etc/localtime ]; then
        target=$(readlink -f /etc/localtime 2>/dev/null || true)
        case "${target}" in
            */zoneinfo/*)
                echo "${target#*/zoneinfo/}"
                return 0
                ;;
        esac
    fi

    return 1
}

function update_env_host_timezone()
{
    local tz

    tz=$(detect_host_timezone)
    if [ -z "${tz}" ]; then
        log_warn "Could not detect host timezone; CHIRPSTACK_HOST_TIMEZONE not updated"
        return 0
    fi

    if [ -f "${curr_path}/.env" ]; then
        if grep -q '^CHIRPSTACK_HOST_TIMEZONE=' "${curr_path}/.env"; then
            sed -i "s/^CHIRPSTACK_HOST_TIMEZONE=.*/CHIRPSTACK_HOST_TIMEZONE=${tz}/" "${curr_path}/.env"
        else
            echo "CHIRPSTACK_HOST_TIMEZONE=${tz}" >> "${curr_path}/.env"
        fi
    else
        echo "CHIRPSTACK_HOST_TIMEZONE=${tz}" > "${curr_path}/.env"
    fi
    export CHIRPSTACK_HOST_TIMEZONE="${tz}"
    log_info "Detected host timezone: ${tz}"
}

# Early exit for completion script to avoid any side effects or extra stdout
if [ "$1"x == "completion-script"x ]; then
cat << 'EOF'
# Bash completion for run.sh
_run_sh_complete()
{
    local curr prev words cword
    COMPREPLY=()
    curr="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Top-level commands exposed to users
    local top_cmds
    top_cmds=(
        pull_image
        setup
        config
        basic
        cluster_init
        cluster_tag
        volume_clean
        network_clean
        one_node
        start
        stop
        restart
        sql_export
        sql_import
    )

    # Subcommands and options per command
    local one_node_sub=(start stop restart)
    local setup_args=(0 1 2 clean)
    local basic_args=(stop)

    # Complete first argument (command)
    if [[ ${COMP_CWORD} -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "${top_cmds[*]}" -- "${curr}") )
        return 0
    fi

    # Complete second argument based on the first
    case "${COMP_WORDS[1]}" in
        one_node)
            COMPREPLY=( $(compgen -W "${one_node_sub[*]}" -- "${curr}") )
            return 0
            ;;
        setup)
            COMPREPLY=( $(compgen -W "${setup_args[*]}" -- "${curr}") )
            return 0
            ;;
        basic)
            COMPREPLY=( $(compgen -W "${basic_args[*]}" -- "${curr}") )
            return 0
            ;;
        *)
            ;;
    esac

    return 0
}

# Register completion for typical invocations
complete -F _run_sh_complete run.sh
complete -F _run_sh_complete ./run.sh
EOF
    exit 0
fi

# Function to check and fix .env file line endings
function fix_env_line_endings()
{
    if [ -f "${curr_path}/.env" ]; then
        # Check if file has Windows line endings
        if file "${curr_path}/.env" | grep -q "CRLF"; then
            echo "Converting .env file from Windows to Unix line endings..."
            # Create backup
            cp "${curr_path}/.env" "${curr_path}/.env.backup"
            # Convert line endings
            tr -d '\r' < "${curr_path}/.env.backup" > "${curr_path}/.env"
            echo "Line endings converted successfully"
        fi
    else
        echo "Warning: .env file not found at ${curr_path}/.env"
    fi
}

# Load all environment variables from .env file
function load_env_vars()
{
    if [ -f "${curr_path}/.env" ]; then
        # Process .env file to handle Windows line endings and comments
        set -a  # automatically export all variables
        
        # Read .env file, remove carriage returns, skip empty lines and comments
        while IFS= read -r line || [ -n "$line" ]; do
            # Remove carriage return characters (Windows line endings)
            line=$(echo "$line" | tr -d '\r')
            
            # Skip empty lines and comments
            if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
                # Export the variable
                export "$line"
            fi
        done < "${curr_path}/.env"
        
        set +a  # disable automatic export
    else
        echo "Warning: .env file not found at ${curr_path}/.env"
    fi
}

# Fix .env file line endings if needed
fix_env_line_endings

# Load environment variables at script startup
load_env_vars

# Function to reload environment variables (useful after config changes)
function reload_env()
{
    load_env_vars
    echo "Environment variables reloaded from .env file"
}

function check_is_master_node()
{
    if [ 0 -ne ${NODE_ID} ]; then
        log_warn "This operation is only permitted to be executed on the master node."
        exit 1
    fi
}

function start()
{
    check_is_master_node
    docker stack deploy --resolve-image never -c docker-stack.yml ${stack_name}
}

function wait_stop_done()
{
    srv_name=$1

    docker stack rm ${srv_name}
    expect_result="Nothing found in stack: ${srv_name}"
    while true; do
        sleep 1
        actual_result=$(docker stack rm ${srv_name} 2>&1)
        if [ "${actual_result}"x == "${expect_result}"x ]; then
            break
        fi
        echo -n " ."
    done
    network_clean
    log_warn "${srv_name} stop done"
}

function stop()
{
    check_is_master_node
    wait_stop_done ${stack_name}
}

function restart()
{
    check_is_master_node
    stop
    start
}

function status()
{
    docker stack services ${stack_name}
}

function create_haproxy_config()
{
    cat > ${curr_path}/stack/haproxy-config << EOF
global
    daemon
    maxconn 2000
    log 127.0.0.1 local0
    insecure-fork-wanted
    external-check

defaults
    mode tcp
    timeout connect 5s
    timeout client 60s
    timeout server 60s
    timeout check 10s
    retries 3

listen stats
    mode http
    bind *:${HAPROXY_PORT}
    stats enable
    stats uri /
    stats refresh 5s

frontend redis_front
    bind *:${REDIS_FRONTEND_PORT}
    option clitcpka
    default_backend redis_backend

backend redis_backend
    balance roundrobin
    option srvtcpka
    option tcp-check
    tcp-check connect
    tcp-check send "ROLE\r\n"
    tcp-check expect string master
    tcp-check send "QUIT\r\n"
    tcp-check expect string +OK

    server redis_primary   ${CLUSTER_NODE0_IP}:${REDIS_PORT} check on-marked-down shutdown-sessions inter 5s rise 7 fall 2
    server redis_replica_1 ${CLUSTER_NODE1_IP}:${REDIS_PORT} check on-marked-down shutdown-sessions inter 5s rise 7 fall 2
    server redis_replica_2 ${CLUSTER_NODE2_IP}:${REDIS_PORT} check on-marked-down shutdown-sessions inter 5s rise 7 fall 2

frontend postgres_frontend
    bind *:${POSTGRES_PORT}
    mode tcp
    option clitcpka
    default_backend postgres_backend

backend postgres_backend
    mode tcp
    option srvtcpka
    balance roundrobin
    option external-check
    external-check command /usr/local/bin/check_primary.sh
    
    server postgres_primary   postgres-node-0:${POSTGRES_PORT} check on-marked-down shutdown-sessions inter 5s rise 7 fall 2
    server postgres_standby_1 postgres-node-1:${POSTGRES_PORT} check on-marked-down shutdown-sessions inter 5s rise 7 fall 2
    server postgres_standby_2 postgres-node-2:${POSTGRES_PORT} check on-marked-down shutdown-sessions inter 5s rise 7 fall 2
EOF
}

function create_redis_config()
{
    node=$1
    ip=$2
    cat > ${curr_path}/stack/redis-${node}-config << EOF
bind 0.0.0.0
port ${REDIS_PORT}
dir /data
appendonly yes
protected-mode no

replica-announce-ip ${ip}
replica-announce-port ${REDIS_PORT}
EOF

    if [ ${node} -eq 0 ]; then
        return
    fi

    cat >> ${curr_path}/stack/redis-${node}-config << EOF

replicaof ${CLUSTER_NODE0_IP} ${REDIS_PORT}
EOF
}

function create_sentinel_config()
{
    node=$1
    ip=$2
    cat > ${curr_path}/stack/sentinel-${node}-config << EOF
port ${REDIS_SENTINEL_PORT}
dir /tmp

sentinel announce-ip ${ip}

sentinel monitor mymaster ${CLUSTER_NODE0_IP} ${REDIS_PORT} 2
sentinel down-after-milliseconds mymaster 10000
sentinel failover-timeout mymaster 20000
sentinel parallel-syncs mymaster 1
EOF
}

function create_keepalived_config()
{
    node=$1
    ip0=$2
    ip1=$3
    ip2=$4

    priority=$((100 - node * 10))
    
    cat > ${curr_path}/stack/keepalived-${node}.conf << EOF
vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority ${priority}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass secret
    }
    virtual_ipaddress {
        ${VIP}/24
    }
    unicast_src_ip ${ip0}
    unicast_peer {
        ${ip1}
        ${ip2}
    }
}
EOF
}

function update_env_config()
{
    node=$1
    sed -i "s/NODE_ID=.*/NODE_ID=${node}/g" ${curr_path}/.env
    arch=$(uname -m)
    sed -i "s/ARCH=.*/ARCH=${arch}/g" ${curr_path}/.env
    if [ "aarch64"x == "${arch}"x ]; then
        sed -i "s/KEEPALIVED_IMAGE=.*/KEEPALIVED_IMAGE=mvilla\/keepalived:arm64/g" ${curr_path}/.env
    else
        sed -i "s/KEEPALIVED_IMAGE=.*/KEEPALIVED_IMAGE=osixia\/keepalived:2.0.20/g" ${curr_path}/.env
    fi

    sed -i "s/ONE_NODE=.*/ONE_NODE=false/g" ${curr_path}/.env
    sed -i '/^CURR_PATH=/d' ${curr_path}/.env
    echo "CURR_PATH=${curr_path}" >> ${curr_path}/.env
}

function is_image_exist()
{
    image_name=$1
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep ${image_name}; then
        echo 1
    fi

    echo 0
}

function pull_image()
{
    arch=$(uname -m)
    keepalived_img="osixia/keepalived:2.0.20"
    if [ "aarch64"x == "${arch}"x ]; then
        keepalived_img="mvilla/keepalived:arm64"
    fi

    list="
${keepalived_img}
portainer/portainer-ce:latest
leedarson/cartsbl:${arch}-v1.8.4
chirpstack/chirpstack-gateway-bridge:4
chirpstack/chirpstack-rest-api:4
bitnamilegacy/postgresql-repmgr:14.12.0
leedarson/haproxy:${arch}-V1.02.00
redis:7-alpine
emqx/emqx:5.6.0
"

    for img in ${list}; do
        if [ "0"x == "$(is_image_exist ${img})"x ]; then
            log_warn "pull ${img} ..."
            docker pull ${img}
        fi
    done
}

function setup_command()
{
    echo "source <( ${curr_path}/run.sh completion-script )" >> ~/.bashrc
    log_warn "setup command completed, please source ~/.bashrc to take effect"
}

function setup()
{
    if [ "command"x == "$2"x ]; then
        setup_command $@
        exit 0
    fi

    if [ "clean"x == "$2"x ]; then
        log_warn "delete ${curr_path}/storage"
        sudo rm -rf ${curr_path}/storage
        exit 0
    fi

    node=$2
    if [ ""x == "${node}"x ]; then
        log_error "Node is required, usage: $0 setup <node:0,1,2>"
        exit 1
    fi

    # clean 
    rm -rf ${curr_path}/stack
    mkdir -p ${curr_path}/stack
    mkdir -p ${curr_path}/storage/tmp
    mkdir -p ${curr_path}/storage/logs

    if [ ${node} -eq 0 ]; then
        create_keepalived_config ${node} ${CLUSTER_NODE0_IP} ${CLUSTER_NODE1_IP} ${CLUSTER_NODE2_IP}
        mkdir -p ${curr_path}/storage/redisdata-0
        if [ ! -d ${curr_path}/storage/postgresqldata-0 ]; then
            sudo tar zxvf ${curr_path}/postgresqldata-0.tgz -C ${curr_path}/storage
            sudo chmod 777 ${curr_path}/storage/postgresqldata-0/conf/pg_hba.conf
            sudo chmod 777 ${curr_path}/storage/postgresqldata-0/conf/postgresql.conf
            sudo chown -R 1001:root ${curr_path}/storage/postgresqldata-0/data
            sudo chown -R 1001:root ${curr_path}/storage/postgresqldata-0/lock
        fi
    elif [ ${node} -eq 1 ]; then
        create_keepalived_config ${node} ${CLUSTER_NODE1_IP} ${CLUSTER_NODE0_IP} ${CLUSTER_NODE2_IP}
        mkdir -p ${curr_path}/storage/postgresqldata-1
        sudo chmod 777 -R ${curr_path}/storage/postgresqldata-1
        mkdir -p ${curr_path}/storage/redisdata-1
    elif [ ${node} -eq 2 ]; then
        create_keepalived_config ${node} ${CLUSTER_NODE2_IP} ${CLUSTER_NODE0_IP} ${CLUSTER_NODE1_IP}
        mkdir -p ${curr_path}/storage/postgresqldata-2
        sudo chmod 777 -R ${curr_path}/storage/postgresqldata-2
        mkdir -p ${curr_path}/storage/redisdata-2
    fi

    update_env_config ${node}
    pull_image
}

function config()
{
    check_is_master_node

    # delete all configs
    docker config ls -q | xargs docker config rm
    create_haproxy_config
    create_redis_config 0 ${CLUSTER_NODE0_IP}
    create_redis_config 1 ${CLUSTER_NODE1_IP}
    create_redis_config 2 ${CLUSTER_NODE2_IP}
    create_sentinel_config 0 ${CLUSTER_NODE0_IP}
    create_sentinel_config 1 ${CLUSTER_NODE1_IP}
    create_sentinel_config 2 ${CLUSTER_NODE2_IP}
    
    ./import_config.sh 
}


function basic()
{
    if [[ ""x == "${NODE_ID}"x ]] || [[ "undefined"x == "${NODE_ID}"x ]]; then
        echo "NODE_ID is not set, please run <./run.sh setup <node:0,1,2>> to set NODE_ID"
        exit 1
    fi

    if [ "$2"x == "stop"x ]; then
        docker compose -f docker-basic-compose.yml down
        exit 0
    fi

    docker compose -f docker-basic-compose.yml up -d
}

function cluster_init()
{
    check_is_master_node

    docker swarm init --advertise-addr ${CLUSTER_NODE0_IP}
    if [ 0 -ne $? ]; then
        log_warn "The cluster has already been initialized, skip ..."
        exit 0
    fi

    command=$(docker swarm join-token manager | grep "token")
    if [ 0 -ne $? ]; then
        log_error "Getting the join token failure for manager"
        exit 1
    fi

    log_warn "Please execute the follow command on other nodes:"
    log_yellow "${command}"
}

function cluster_tag()
{
    check_is_master_node

    node0_id=$(docker node inspect $(docker node ls -q) --format '{{.ID}}:{{.Status.Addr}}' | grep "${CLUSTER_NODE0_IP}" | cut -d":" -f1)
    node1_id=$(docker node inspect $(docker node ls -q) --format '{{.ID}}:{{.Status.Addr}}' | grep "${CLUSTER_NODE1_IP}" | cut -d":" -f1)
    node2_id=$(docker node inspect $(docker node ls -q) --format '{{.ID}}:{{.Status.Addr}}' | grep "${CLUSTER_NODE2_IP}" | cut -d":" -f1)
    
    if [[ ""x == "${node0_id}"x ]] || [[ ""x == "${node1_id}"x ]] || [[ ""x == "${node2_id}"x ]]; then
        log_warn "Some nodes has not ready!!!"
        exit 0
    fi

    docker node update --label-add node.id=1 ${node0_id}
    docker node update --label-add node.id=2 ${node1_id}
    docker node update --label-add node.id=3 ${node2_id}
}

function volume_clean()
{
    docker volume ls --filter label=com.docker.stack.namespace=${stack_name} -q | xargs -r docker volume rm
}

function network_clean()
{
    docker network prune -f
}

function one_node_start()
{
    update_env_primary_mac
    update_env_host_timezone
    if [ ! -d ${CURR_PATH}/storage/postgresqldata ]; then
        sudo tar zxvf postgresqldata.tgz -C storage
    fi
    ARCH=$(uname -m) docker compose -f docker-compose.yml up -d
}

function one_node_stop()
{
    ARCH=$(uname -m) docker compose -f docker-compose.yml down
}

function one_node_restart()
{
    one_node_stop
    one_node_start
}

function one_node()
{
    arch=$(uname -m)
    sed -i "s/ARCH=.*/ARCH=${arch}/g" ${curr_path}/.env
    sed -i "s/ONE_NODE=.*/ONE_NODE=true/g" ${curr_path}/.env
    one_node_$2 ${@:3}
}

function sql_export()
{
    pg_dump -h ${CLUSTER_NODE0_IP} -p ${POSTGRES_PORT} -U chirpstack -d chirpstack \
        -Fc \
        --clean \
        --if-exists \
        --no-owner \
        --no-acl \
        --no-tablespaces \
        --section=pre-data --section=data --section=post-data \
        -f sqldata.dump
}

function sql_import()
{
    pg_restore -h ${CLUSTER_NODE0_IP} -p ${POSTGRES_PORT} -U chirpstack -d chirpstack \
        -Fc \
        --clean \
        --if-exists \
        --no-owner \
        --no-acl \
        < sqldata.dump
}

if [[ "setup"x != "$1"x ]] && [[ "one_node"x != "$1"x ]]; then
    if [[ -z ${CURR_PATH} ]] || [[ "${curr_path}"x != "${CURR_PATH}"x ]]; then
        echo "CURR_PATH is invalid, please run <./run.sh setup <node:0,1,2>> to set CURR_PATH"
        exit 1
    fi
fi

if [ "$1"x == ""x ]; then
    time start $@
    exit 0
fi

time $1 $@

