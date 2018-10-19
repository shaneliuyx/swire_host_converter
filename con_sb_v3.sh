#!/bin/bash
#example:
# bash ./con_sb_v3.sh instance.csv

profile='default'

try_function()
{
    local limit
    local pass
    #local result

    limit=10
    pass=1
    result=$(eval $1)

    while [ "$?" -ne 0 ]; do
        k=$((2**$pass))
        sleep $k
        echo -e " $(date "+%Y-%m-%d%  %H:%M:%S")\n $1 \n try $pass pass\n" >> covert_ec2.log
        pass=$(($pass+1))
        if [ $pass -eq $limit ]; then
            exit 1
        fi
        result=$(eval $1)
    done
    echo "$result"
}

get_instacne_id_by_name()
{
    local cmd
    local Instance_Id
    cmd="aws ec2 describe-instances --profile $profile   --query \"Reservations[].Instances[?State.Name!='terminated'][]|[?Placement.Tenancy!='$2'].InstanceId[]\"  --filters "\'"Name=tag:Name,Values=$1"\'
    Instance_Id=$(try_function "${cmd}")
    Instance_Id=$(echo "$Instance_Id"|sed 's/"//g'|sed 's/,//g'|sed 's/\[//' |sed 's/]//')
    Instance_Id=$(col -b <<< $Instance_Id)
    echo "$Instance_Id"
}

get_instacne_id_by_ip()
{
    local cmd
    local Instance_Id
    cmd="aws ec2 describe-instances --profile $profile --output text --query \"Reservations[].Instances[?PrivateIpAddress=='$1'][]|[?Placement.Tenancy!='$2'][]|[?State.Name!='terminated'].InstanceId[]\""
    Instance_Id=$(try_function "${cmd}")
    Instance_Id=$(col -b <<< $Instance_Id)
    echo "$Instance_Id"
}


#Main Program

if [[ $1 != "" ]];then
    i=0
    echo "Reading instance file ($1)..."
    while IFS=',' read -r SourceInstanceId SourceInstanceName SourceInstanceIP TargetAMI hostid TargetSecurityGroupId TargetHostname TenancyType ; do
        if [ $i != 0 ]; then
            begin_time=$(date +%s)
            SourceInstanceId=$(col -b <<< $SourceInstanceId)
            SourceInstanceName=$(col -b <<< $SourceInstanceName)
            SourceInstanceIP=$(col -b <<< $SourceInstanceIP)
            TargetAMI=$(col -b <<< $TargetAMI)
            hostid=$(col -b <<< $hostid)
            TargetSecurityGroupId=$(col -b <<< $TargetSecurityGroupId)
            TenancyType=$(col -b <<< $TenancyType)
            TargetHostname=$(col -b <<< $TargetHostname)

            if [[ $SourceInstanceId == "" ]]; then
                if [[ $SourceInstanceName != "" ]]; then
                    SourceInstanceId=$(get_instacne_id_by_name $SourceInstanceName $TenancyType)
                else
                    if [[ $SourceInstanceIP != "" ]]; then
                        SourceInstanceId=$(get_instacne_id_by_ip $SourceInstanceIP $TenancyType)
                    fi
                fi
            fi
            echo "SourceInstanceId=$SourceInstanceId"
            cmd="aws ec2 describe-instances --profile $profile --instance-ids $SourceInstanceId --query \"Reservations[].Instances[]\" --output text"
            instance_exist=$(try_function "${cmd}")

            if [[ ( $SourceInstanceId != "" ) && ( $instance_exist != "" ) ]]; then
                cmd="aws ec2 describe-instances --profile $profile --instance-ids $SourceInstanceId --output text --query \"Reservations[].Instances[].Placement.Tenancy\""
                source_tenancy=$(try_function "${cmd}")
                echo "source_tenancy=$source_tenancy"
                echo "TenancyType=$TenancyType"
                #if [[ $source_tenancy != $TenancyType ]]; then
                echo "Start to convert ($SourceInstanceId)..."
                cmd="aws ec2 describe-instances --profile $profile --instance-ids $SourceInstanceId --query "\'"Reservations[].Instances[].{KeyName:KeyName,AttachmentId:NetworkInterfaces[0].Attachment.AttachmentId, PrivateIpAddress:PrivateIpAddress, NetworkInterfaceId:NetworkInterfaces[0].NetworkInterfaceId,InstanceType:InstanceType,RootDeviceName:RootDeviceName,BlockDeviceMappings:BlockDeviceMappings[].{name:DeviceName,id:Ebs.VolumeId}}"\'
                try_function "${cmd}"
                PrivateIpAddress=$(echo "$result"|grep PrivateIpAddress|cut -d: -f2|sed 's/"//g' |sed 's/,//g'|sed 's/ //g')
                PrivateIpAddress=$(col -b <<< $PrivateIpAddress)
                AttachmentId=$(echo "$result"|grep AttachmentId|cut -d: -f2|sed 's/"//g' |sed 's/,//g'|sed 's/ //g')
                AttachmentId=$(col -b <<< $AttachmentId)
                NetworkInterfaceId=$(echo "$result"|grep NetworkInterfaceId|cut -d: -f2|sed 's/"//g' |sed 's/,//g'|sed 's/ //g')
                NetworkInterfaceId=$(col -b <<< $NetworkInterfaceId)
                InstanceType=$(echo "$result"|grep InstanceType|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
                InstanceType=$(col -b <<< $InstanceType)
                SourceRootDeviceName=($(echo "$result"|grep RootDeviceName|cut -d: -f2|sed 's/"//g' |sed 's/,//g'|sed 's/ //g'))
                SourceRootDeviceName[0]=$(col -b <<< $SourceRootDeviceName)
                KeyPair=$(echo "$result"|grep KeyName|cut -d: -f2|sed 's/"//g' |sed 's/,//g'|sed 's/ //g')
                KeyPair=$(col -b <<< $KeyPair)
                echo "KeyPair Name =$KeyPair"
                DataVolumes=($(echo "$result"|grep id|cut -d: -f2|sed 's/"//g' |sed 's/,//g'))
                DataDevices=($(echo "$result"|grep name|cut -d: -f2|sed 's/"//g' |sed 's/,//g'))
                echo "Source PrivateIpAddress = $PrivateIpAddress"
                echo "NetworkInterfaceId = $NetworkInterfaceId"
                echo "SourceRootDeviceName =${SourceRootDeviceName[0]}"
                cmd="aws ec2 modify-network-interface-attribute --profile $profile --attachment AttachmentId=\"$AttachmentId\",DeleteOnTermination=false --network-interface-id $NetworkInterfaceId"
                try_function "${cmd}"
                echo "Source InstanceType = $InstanceType"
                echo "Source EBS Mapping:"
                echo "${DataVolumes[@]}"
                echo "${DataDevices[@]}"
                k=${#DataDevices[*]}

                for ((i=0; i<$k; i++));
                do
                    DataDevices[i]=$(col -b <<< ${DataDevices[i]})
                    if [ "${DataDevices[i]}" == "${SourceRootDeviceName[0]}" ]
                    then
                        RootDevice[$i]="$SourceRootDeviceName"
                        RootVolume[$i]=$(col -b <<< ${DataVolumes[i]})
                        DataVolumes=("${DataVolumes[@]/${DataVolumes[i]}}")
                        DataDevices=("${DataDevices[@]/${DataDevices[i]}}")
                        DataVolumes=( "${DataVolumes[@]}" )
                        DataDevices=( "${DataDevices[@]}" )
                    fi
                done

                echo "    RootDevice----${RootDevice[@]}"
                echo "    RootVolume----${RootVolume[@]}"

                k=${#DataDevices[*]}


                for ((i=0; i<$k; i++));
                do
                    #  echo " --- $i DataDevices----${DataDevices[i]}"
                    if [ ${#DataDevices[i]} != 0 ] && [ ${#DataVolumes[i]} != 0 ]
                    then
                        echo "     DataDevices----${DataDevices[i]}"
                        echo "     DataVolumes----${DataVolumes[i]}"
                    fi
                done


                echo "KeyPair Name = $KeyPair"

                echo "Target Security Group: $TargetSecurityGroupId"
                cmd="aws ec2 describe-instances --profile $profile --instance-id $SourceInstanceId --query "\'"Reservations[].Instances[].Tags[]"\'
                try_function "${cmd}"
                SourceTags="$result"
                SourceTags=$(col -b <<< $SourceTags)
                SourceTags=$(echo $SourceTags |sed 's/"/\\\"/g')
                echo "Source tags:"
                echo "$SourceTags"
                echo "Stopping source EC2..."
                cmd="aws ec2 stop-instances --profile $profile --instance-ids $SourceInstanceId"
                try_function "${cmd}"
                cmd="aws ec2 wait instance-stopped --profile $profile --instance-ids $SourceInstanceId"
                try_function "${cmd}"
                echo "EC2 instance $SourceInstanceId is stopped"

                echo "Detach source EC2 root device $SourceRootDeviceName ----> ${RootVolume[@]}"
                cmd="aws ec2 detach-volume --profile $profile --volume-id ${RootVolume[@]}"
                try_function "${cmd}"
                k=${#DataDevices[*]}
                for ((i=0; i<$k; i++));
                do
                    DataVolumes[i]=$(col -b <<< ${DataVolumes[i]})
                    DataDevices[i]=$(col -b <<< ${DataDevices[i]})
                    if [ ${#DataDevices[i]} != 0 ] && [ ${#DataVolumes[i]} != 0 ];
                    then
                        echo "Detach data volume ${DataVolumes[$i]} as ${DataDevices[$i]} from source EC2 instacne ( $SourceInstanceId )"
                        cmd="aws ec2 detach-volume --profile $profile --volume-id ${DataVolumes[i]}"
                        try_function "${cmd}"
                    fi
                done

                echo "Terninating source EC2"
                cmd="aws ec2 terminate-instances --profile $profile --instance-ids $SourceInstanceId"
                try_function "${cmd}"

                cmd="aws ec2 wait instance-terminated --profile $profile --instance-ids  $SourceInstanceId"
                try_function "${cmd}"
                echo "EC2 instance $SourceInstanceId is terminated"

                cmd="aws ec2 describe-network-interfaces --profile $profile --network-interface-id $NetworkInterfaceId --output text --query "\'"NetworkInterfaces[].Status"\'
                try_function "${cmd}"
                while [[ $result == "in-use" ]]
                do try_function "${cmd}"
                done

                placement="Tenancy=$TenancyType"
                if [[ $hostid != "" ]]
                then
                    placement="Tenancy=$TenancyType,HostId=$hostid"
                fi
                echo "Creating target EC2"
                if [[ $KeyPair != "null" ]]; then
                    cmd="aws ec2 run-instances --profile $profile --image-id $TargetAMI --instance-type $InstanceType --placement $placement --network-interfaces \"DeviceIndex=0,NetworkInterfaceId=$NetworkInterfaceId\" --count 1 --key-name $KeyPair"
                else
                    cmd="aws ec2 run-instances --profile $profile --image-id $TargetAMI --instance-type $InstanceType --placement $placement --network-interfaces \"DeviceIndex=0,NetworkInterfaceId=$NetworkInterfaceId\" --count 1"
                fi
                try_function "${cmd}"
                #cmd="aws ec2 wait instance-running --profile $profile --instance-ids"
                #try_function "${cmd}"
                TargetInstanceId=$(echo "$result"| egrep  InstanceId  |cut -d: -f2|sed 's/"//g' |sed 's/,//g')
                TargetInstanceId=$(col -b <<< $TargetInstanceId)
                echo "Target Instance ID = $TargetInstanceId"

                # copy source instance tags to target
                a="[]"
                if  [[ $SourceTags != $a ]];
                then
                    echo "Copying source tags to target"
                    cmd="aws ec2 create-tags --profile $profile --resources $TargetInstanceId --tags \"$SourceTags\""
                    try_function "${cmd}"
                fi

                #Adding new namne tag
                if [[ $TargetHostname == "" ]]; then
                    H_NO=$(echo $PrivateIpAddress | awk -F. '{OFS=""; printf "%.3d%.3d\n",$3,$4}')
                    HOST="SRC${H_NO}"
                else
                    HOST=$TargetHostname
                fi

                cmd="aws ec2 create-tags --profile $profile --resources $TargetInstanceId --tags Key=Name,Value=$HOST"
                try_function "${cmd}"

                if [[ $TargetSecurityGroupId != "" ]];
                then
                    cmd="aws ec2 modify-instance-attribute --profile $profile --instance-id $TargetInstanceId --groups $TargetSecurityGroupId"
                    try_function "${cmd}"
                fi
                cmd="aws ec2 describe-instances --profile $profile --instance-ids $TargetInstanceId --query "\'"Reservations[].Instances[].{KeyName:KeyName,AttachmentId:NetworkInterfaces[0].Attachment.AttachmentId, PrivateIpAddress:PrivateIpAddress, NetworkInterfaceId:NetworkInterfaces[0].NetworkInterfaceId,InstanceType:InstanceType,RootDeviceName:RootDeviceName,BlockDeviceMappings:BlockDeviceMappings[].{name:DeviceName,id:Ebs.VolumeId}}"\'
                try_function "${cmd}"
                TargetRootDeviceName=$(echo "$result"|grep RootDeviceName|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
                TargetRootDeviceName=$(col -b <<< $TargetRootDeviceName)
                TargetRootVolumeId=($(echo "$result"|grep id|cut -d: -f2|sed 's/"//g' |sed 's/,//g'))
                TargetRootVolumeId=$(col -b <<< $TargetRootVolumeId)
                AttachmentId=$(echo "$result"|grep AttachmentId|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
                AttachmentId=$(col -b <<< $AttachmentId)

                echo "Targe root volume ID =$TargetRootVolumeId"
                echo "Target root device name =$TargetRootDeviceName"
                echo "Waiting for instance ($HOST--$TargetInstanceId) running ..."
                cmd="aws ec2 wait instance-status-ok  --profile $profile --instance-ids  $TargetInstanceId"
                try_function "${cmd}"

                echo "Stopping target EC2 ($HOST--$TargetInstanceId)"
                cmd="aws ec2 stop-instances --profile $profile --instance-ids $TargetInstanceId"
                try_function "${cmd}"

                cmd="aws ec2 wait instance-stopped --profile $profile --instance-ids  $TargetInstanceId"
                try_function "${cmd}"

                echo "EC2 instance ($HOST--$TargetInstanceId) is stopped"

                echo "Detach $HOST's root device $TargetRootDeviceName ----> $TargetRootVolumeId"
                cmd="aws ec2 detach-volume --profile $profile --volume-id $TargetRootVolumeId"
                try_function "${cmd}"


                echo "Delete $HOST's root volume: $TargetRootVolumeId"
                cmd="aws ec2 delete-volume --profile $profile --volume-id $TargetRootVolumeId"
                try_function "${cmd}"

                echo "Attach root volume ${RootVolume[@]} as $TargetRootDeviceName to target EC2 instacne ($HOST--$TargetInstanceId)"
                cmd="aws ec2 attach-volume --profile $profile --device $TargetRootDeviceName --instance-id $TargetInstanceId  --volume-id ${RootVolume[@]}"
                try_function "${cmd}"

                k=${#DataDevices[*]}
                for ((i=0; i<$k; i++));
                do
                    if [ ${#DataDevices[i]} != 0 ] && [ ${#DataVolumes[i]} != 0 ]
                    then
                        echo "Attach data volume ${DataVolumes[$i]} as ${DataDevices[$i]} to target EC2 instacne ($HOST--$TargetInstanceId)"
                        cmd="aws ec2 attach-volume --profile $profile --device ${DataDevices[$i]} --instance-id $TargetInstanceId  --volume-id ${DataVolumes[$i]}"
                        try_function "${cmd}"
                    fi
                done

                cmd="aws ec2 modify-network-interface-attribute --profile $profile --attachment AttachmentId=\"$AttachmentId\",DeleteOnTermination=true --network-interface-id $NetworkInterfaceId"
                try_function "${cmd}"

                #echo "Starting $HOST..."
                #cmd="aws ec2 start-instances --profile $profile --instance-ids $TargetInstanceId"
                #try_function "${cmd}"

                end_time=$(date +%s)
                cost_time=$(($end_time-$begin_time))

                echo "Total execution time: $cost_time seconds"
                #fi
            fi
        fi
        let i=i+1
    done < "$1"
fi
