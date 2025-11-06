#!/bin/bash

function is_exists()
{
    name=$1
    docker config inspect ${name} > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        return 0
    fi
    return 1
}

function import()
{
    name=$1
    is_exists ${name}
    if [ $? -eq 0 ]; then
        echo "Config ${name} already exists"
        return
    fi

    file=$2
    if [ ! -f ${file} ]; then
        echo "Config file ${file} not found"
        return
    fi
    
    echo "Importing config ${name} from ${file}"
    docker config create ${name} ${file}
    if [ $? -ne 0 ]; then
        echo "Failed to import config ${name}"
        exit 1
    fi
}

# Configuration list: [config_name, config_file]
configs=(
    "sbl-middleware-config:stack/sbl_middleware.yaml"
    "haproxy-config:stack/haproxy-config"
    "redis-0-conf:stack/redis-0-config"
    "redis-1-conf:stack/redis-1-config"
    "redis-2-conf:stack/redis-2-config"
    "sentinel-0-conf:stack/sentinel-0-config"
    "sentinel-1-conf:stack/sentinel-1-config"
    "sentinel-2-conf:stack/sentinel-2-config"
)

# Import all configurations
for config in "${configs[@]}";do
    IFS=':' read -r name file <<< "$config"
    import "$name" "$file"
done
