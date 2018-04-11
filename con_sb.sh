#!/bin/bash
#example:
# bash ./con_sb.sh -i i-0abf306a8623699b8  -a ami-d8578bb5  -g sg-0695ca0de00bdd034  -t dedicated & > 2>&1 > output_`date +"\%Y\%m\%d"`.log

# add Name tag which is followed by Swire's naming convention
# -g S : copy target security group to target
# -g sg-xxx : copy target security group to target, and at the same time, add a new additional security group to target

POSITIONAL=()
while [[ $# -gt 0 ]]
do
  key="$1"
  case $key in
    -i|--SourceInstanceId)
      SourceInstanceId="$2"
      shift # past argument
      shift # past value
      ;;
    -a|--TargetAMI)
      TargetAMI="$2"
      shift # past argument
      shift # past value
      ;;
    -g|--TargetSecurityGroupId)
      TargetSecurityGroupId="$2"
      shift # past argument
      shift # past value
      ;;
    -t|--TenancyType)
      TenancyType="$2"
      shift # past argument
      shift # past value
      ;;
    *)    # unknown option
      POSITIONAL+=("$1") # save it in an array for later
      shift # past argument
      ;;
  esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters
if [[ -n $1 ]]; then
  echo "Last line of parameter specified as non-opt/last argument:"
  tail -1 "$1"
fi

try_function()
{ echo $1
  limit=5
  pass=1
  result=$(eval $1)

  while [ "$?" -ne 0 ]; do
    k=$((2**$pass))
    sleep $k
    echo "try $pass pass"
    pass=$(($pass+1))
    if [ $pass -eq $limit ]; then
      exit 1
    fi
    result=$(eval $1)
  done
  echo "$result"
}

begin_time=$(date +%s)
SourceInstanceId=${SourceInstanceId}
TargetAMI=${TargetAMI}
KeyPair=${KeyPair}
TargetSecurityGroupId=${TargetSecurityGroupId}
TenancyType=${TenancyType}
echo "Start to convert..."
cmd="aws ec2 describe-instances --instance-ids $SourceInstanceId --query "\'"Reservations[].Instances[].{KeyName:KeyName,AttachmentId:NetworkInterfaces[0].Attachment.AttachmentId, PrivateIpAddress:PrivateIpAddress, NetworkInterfaceId:NetworkInterfaces[0].NetworkInterfaceId,InstanceType:InstanceType,RootDeviceName:RootDeviceName,BlockDeviceMappings:BlockDeviceMappings[].{name:DeviceName,id:Ebs.VolumeId}}"\'
try_function "${cmd}"
PrivateIpAddress=$(echo "$result"|grep PrivateIpAddress|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
PrivateIpAddress=$(col -b <<< $PrivateIpAddress)
AttachmentId=$(echo "$result"|grep AttachmentId|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
AttachmentId=$(col -b <<< $AttachmentId)
NetworkInterfaceId=$(echo "$result"|grep NetworkInterfaceId|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
NetworkInterfaceId=$(col -b <<< $NetworkInterfaceId)
InstanceType=$(echo "$result"|grep InstanceType|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
InstanceType=$(col -b <<< $InstanceType)
SourceRootDeviceName=$(echo "$result"|grep RootDeviceName|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
SourceRootDeviceName=$(col -b <<< $SourceRootDeviceName)
KeyPair=$(echo "$result"|grep KeyName|cut -d: -f2|sed 's/"//g' |sed 's/,//g')
KeyPair=$(col -b <<< $KeyPair)
echo "KeyPair Name =$KeyPair"
DataVolumes=($(echo "$result"|grep id|cut -d: -f2|sed 's/"//g' |sed 's/,//g'))
DataDevices=($(echo "$result"|grep name|cut -d: -f2|sed 's/"//g' |sed 's/,//g'))
echo "Source PrivateIpAddress = $PrivateIpAddress"
echo "NetworkInterfaceId = $NetworkInterfaceId"
cmd="aws ec2 modify-network-interface-attribute --attachment AttachmentId=\"$AttachmentId\",DeleteOnTermination=false --network-interface-id $NetworkInterfaceId"
try_function "${cmd}"
echo "Source InstanceType = $InstanceType"
echo "Source EBS Mapping:"
echo "${DataVolumes[@]}"
echo "${DataDevices[@]}"
k=${#DataDevices[*]}
for ((i=0; i<$k; i++));
do
  DataDevices[i]=$(col -b <<< ${DataDevices[i]})
  if [ "${DataDevices[i]}" == "$SourceRootDeviceName" ]
  then
    RootDevice[$i]="$SourceRootDeviceName"
    RootVolume[$i]=$(col -b <<< ${DataVolumes[i]})
    unset DataVolumes[i]
    unset DataDevices[i]
    DataVolumes=( "${DataVolumes[@]}" )
    DataDevices=( "${DataDevices[@]}" )
  fi
done

echo "    RootDevice----${RootDevice[@]}"
echo "    RootVolume----${RootVolume[@]}"

k=${#DataDevices[*]}
for ((i=0; i<$k; i++));
do
  echo "    DataDevices----${DataDevices[i]}"
  echo "    DataVolumes----${DataVolumes[i]}"
done


echo "KeyPair Name = $KeyPair"

echo "Target Security Group: $TargetSecurityGroupId"
cmd="aws ec2 describe-instances --instance-id $SourceInstanceId --query "\'"Reservations[].Instances[].Tags[]"\'
try_function "${cmd}"
SourceTags="$result"
SourceTags=$(col -b <<< $SourceTags)
SourceTags=$(echo $SourceTags |sed 's/"/\\\"/g')
echo "Source tags:"
echo "$SourceTags"
echo "Stopping source EC2..."
cmd="aws ec2 stop-instances --instance-ids $SourceInstanceId"
try_function "${cmd}"
cmd="aws ec2 wait instance-stopped --instance-ids $SourceInstanceId"
try_function "${cmd}"
echo "EC2 instance $SourceInstanceId is stopped"

echo "Detach source EC2 root device $SourceRootDeviceName ----> ${RootVolume[@]}"
cmd="aws ec2 detach-volume --volume-id ${RootVolume[@]}"
try_function "${cmd}"
k=${#DataDevices[*]}
for ((i=1; i<=$k; i++));
do
  ${DataVolumes[i]}=$(col -b <<< ${DataVolumes[i]})
  ${DataDevices[i]}=$(col -b <<< ${DataDevices[i]})
  echo "Detach data volume ${DataVolumes[$i]} as ${DataDevices[$i]} from source EC2 instacne ( $SourceInstanceId )"
  cmd="aws ec2 detach-volume --volume-id ${DataVolumes[i]}"
  try_function "${cmd}"
done

echo "Terninating source EC2"
cmd="aws ec2 terminate-instances --instance-ids $SourceInstanceId"
try_function "${cmd}"

#cmd="aws ec2 wait instance-terminated --instance-ids  $SourceInstanceId"
#try_function "${cmd}"
#echo "EC2 instance $SourceInstanceId is terminated"

cmd="aws ec2 describe-network-interfaces --network-interface-id $NetworkInterfaceId --output text --query "\'"NetworkInterfaces[].Status"\'
try_function "${cmd}"
while [[ $result == "in-use" ]]
do try_function "${cmd}"
done

placement="Tenancy=$TenancyType"
echo "Creating target EC2"
cmd="aws ec2 run-instances --image-id $TargetAMI --instance-type $InstanceType --placement $placement --network-interfaces DeviceIndex=0,NetworkInterfaceId=$NetworkInterfaceId --count 1 --key-name $KeyPair"
try_function "${cmd}"
TargetInstanceId=$(echo "$result"| egrep  InstanceId  |cut -d: -f2|sed 's/"//g' |sed 's/,//g')
TargetInstanceId=$(col -b <<< $TargetInstanceId)
echo "Target Instance ID = $TargetInstanceId"

# copy source instance tags to target
a="[]"
if  [[ $SourceTags != $a ]];
 then
   echo "Copying source tags to target"
   #echo "$SourceTags" > $SourceInstanceId.json
   #cmd="aws ec2 create-tags --resources $TargetInstanceId --tags file://$SourceInstanceId.json"
   cmd="aws ec2 create-tags --resources $TargetInstanceId --tags \"$SourceTags\""
   try_function "${cmd}"
fi

#Adding new namne tag
H_NO=$(echo $PrivateIpAddress | awk -F. '{OFS=""; printf "%.3d%.3d\n",$3,$4}')
HOST="SRC${H_NO}"
cmd="aws ec2 create-tags --resources $TargetInstanceId --tags Key=Name,Value=$HOST"
try_function "${cmd}"

if [ $TargetSecurityGroupId != "S" ];
then
  cmd="aws ec2 modify-instance-attribute --instance-id $TargetInstanceId --groups $TargetSecurityGroupId"
  try_function "${cmd}"
fi
cmd="aws ec2 describe-instances --instance-ids $TargetInstanceId --query "\'"Reservations[].Instances[].{KeyName:KeyName,AttachmentId:NetworkInterfaces[0].Attachment.AttachmentId, PrivateIpAddress:PrivateIpAddress, NetworkInterfaceId:NetworkInterfaces[0].NetworkInterfaceId,InstanceType:InstanceType,RootDeviceName:RootDeviceName,BlockDeviceMappings:BlockDeviceMappings[].{name:DeviceName,id:Ebs.VolumeId}}"\'
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
cmd="aws ec2 wait instance-running --instance-ids  $TargetInstanceId"
try_function "${cmd}"

echo "Stopping target EC2 ($HOST--$TargetInstanceId)"
cmd="aws ec2 stop-instances --instance-ids $TargetInstanceId"
try_function "${cmd}"

cmd="aws ec2 wait instance-stopped --instance-ids  $TargetInstanceId"
try_function "${cmd}"

echo "EC2 instance ($HOST--$TargetInstanceId) is stopped"

echo "Detach $HOST's root device $TargetRootDeviceName ----> $TargetRootVolumeId"
cmd="aws ec2 detach-volume --volume-id $TargetRootVolumeId"
try_function "${cmd}"


echo "Delete $HOST's root volume: $TargetRootVolumeId"
cmd="aws ec2 delete-volume --volume-id $TargetRootVolumeId"
try_function "${cmd}"

echo "Attach root volume ${RootVolume[@]} as $TargetRootDeviceName to target EC2 instacne ($HOST--$TargetInstanceId)"
cmd="aws ec2 attach-volume --device $TargetRootDeviceName --instance-id $TargetInstanceId  --volume-id ${RootVolume[@]}"
try_function "${cmd}"

k=${#DataDevices[*]}
for ((i=1; i<=$k; i++));
do
  echo "Attach data volume ${DataVolumes[$i]} as ${DataDevices[$i]} to target EC2 instacne ($HOST--$TargetInstanceId)"
  cmd="aws ec2 attach-volume --device ${DataDevices[$i]} --instance-id $TargetInstanceId  --volume-id ${DataVolumes[$i]}"
  try_function "${cmd}"
done

cmd="aws ec2 modify-network-interface-attribute --attachment AttachmentId=\"$AttachmentId\",DeleteOnTermination=true --network-interface-id $NetworkInterfaceId"
try_function "${cmd}"

echo "Starting $HOST..."
cmd="aws ec2 start-instances --instance-ids $TargetInstanceId"
try_function "${cmd}"

end_time=$(date +%s)
cost_time=$(($end_time-$begin_time))

echo "Total execution time: $cost_time seconds"
