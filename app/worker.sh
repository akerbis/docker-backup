#!/bin/bash

set -eux

source $(dirname $0)/common.sh

install_docker

source=$1

type=$(get_source_parameter $source type)
source_container_id=$(get_container_id_from_config source $source)
source_container_name=$(docker_get_container_name_from_id $source_container_id)

declare -a volumes_to_backup

if [ "$type" == "mysqldump" ]; then
    username=$(get_source_parameter $source username "")
    if [ -z "$username" ]; then
        username=$(get_config_env_var sources $source username)
    fi
    password=$(get_source_parameter $source password "")
    if [ -z "$password" ]; then
        password=$(get_config_env_var sources $source password)
    fi
    databases=$(get_source_parameter $source databases)

    if [ "$databases" == "*" ]; then
        databases_opt="--all-databases"
    else
        databases_opt="--databases $(echo $databases | tr '\0' ' ')"
    fi

    tmp_dir="/tmp/mysql_backup_${source_container_name}"
    mkdir -p "${tmp_dir}"
    tmp_file="${tmp_dir}/mysql_backup_${source_container_name}_$(date +"%Y%m%d%H%M").sql"
    # TODO better security -> write ~/.my.cnf with [mysqldump]\nuser=user\npassword=secret and delete it afterwards
    eval docker exec -i ${source_container_id} mysqldump -u${username} -p${password} ${databases_opt} > ${tmp_file}

    volumes_to_backup[1]="${tmp_dir}"
fi

if [ "$type" == "fs" ]; then
    volumes=$(get_source_parameter $source volumes)
    i=1
    for volume in "${volumes[@]}"
    do
        volumes_to_backup[$i]="$volume"
        i=$(($i+1))
    done
fi

destination=$(get_source_parameter $source destination)
BACKUP_METHOD=$(get_destination_parameter $destination type)
BACKUP_KEEP_N_FULL=$(get_parameter backup_keep_n_full)

if [ "${BACKUP_METHOD}" == "ftp" ]
then
    server=$(get_destination_parameter $destination server "")
    if [ -z "${server}" ]; then
        server_id=$(get_container_id_from_config destination $destination)
        server=$(docker_get_container_name_from_id $server_id)
    fi
    port=$(get_destination_parameter $destination port 21)
    username=$(get_destination_parameter $destination username)
    path=$(get_destination_parameter $destination path /)
    BACKUP_URL="par2+ftp://${username}@${server}:${port}${path}${source_container_name}"
    ENV_FTP_PASSWORD=$(get_config_env_var destinations $destination password)
    if [ -n "${ENV_FTP_PASSWORD}" ]; then
        export FTP_PASSWORD=${ENV_FTP_PASSWORD}
    else
        export FTP_PASSWORD=$(get_destination_parameter $destination password "")
    fi
    for volume_to_backup in "${volumes_to_backup[@]}"
    do
        duplicity --full-if-older-than "$(get_parameter backup_full_if_older_than)" \
            --no-encryption --allow-source-mismatch \
            "${volume_to_backup}" "${BACKUP_URL}"
    done
fi

if [ "${BACKUP_METHOD}" == "s3" ]
then
    export AWS_ACCESS_KEY_ID=$(get_destination_parameter $destination access_key_id)
    export AWS_SECRET_ACCESS_KEY=$(get_destination_parameter $destination secret_access_key)
    AWS_REGION=$(get_destination_parameter $destination region)
    AWS_BUCKET_NAME=$(get_destination_parameter $destination bucket_name)
    BACKUP_URL="par2+s3://s3.${AWS_REGION}.amazonaws.com/${AWS_BUCKET_NAME}/${source_container_name}"
    for volume_to_backup in "${volumes_to_backup[@]}"
    do
        duplicity --full-if-older-than "$(get_parameter backup_full_if_older_than)" \
            --no-encryption --allow-source-mismatch \
            --s3-european-buckets --s3-use-new-style \
            "${volume_to_backup}" "${BACKUP_URL}"
    done
fi

duplicity remove-all-but-n-full --force --no-encryption "${BACKUP_KEEP_N_FULL}" "${BACKUP_URL}"

exit 0
