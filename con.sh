#!/bin/bash
#example:
# bash ./con.sh -i i-0abf306a8623699b8  -a ami-d8578bb5  -k demo -g sg-0695ca0de00bdd034  -t dedicated
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
    -k|--KeyPair)
      KeyPair="$2"
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

SourceInstanceId=${SourceInstanceId}
#TargetAMI="ami-d8578bb5"
TargetAMI=${TargetAMI}
#KeyPair="demo"
KeyPair=${KeyPair}
#TargetSecurityGroupId="sg-0695ca0de00bdd034"
TargetSecurityGroupId=${TargetSecurityGroupId}
#TenancyType=="dedicated"
TenancyType=${TenancyType}
echo "Start to convert..."
SubnetId=$(aws ec2 describe-instances --instance-ids $SourceInstanceId  --query 'Reservations[].Instances[].SubnetId' --output text)
echo "Source SubnetId = $SubnetId"
PrivateIpAddress=$(aws ec2 describe-instances --instance-ids $SourceInstanceId  --query 'Reservations[].Instances[].PrivateIpAddress' --output text)
echo "Source PrivateIpAddress = $PrivateIpAddress"
# AZ=$(aws ec2 describe-instances --instance-ids $SourceInstanceId  --query 'Reservations[].Instances[].Placement.AvailabilityZone' --output text)
# echo "Source AZ = $AZ"
InstanceType=$(aws ec2 describe-instances --instance-ids $SourceInstanceId  --query 'Reservations[].Instances[].InstanceType' --output text)
echo "Source InstanceType = $InstanceType"

SourceRootDeviceName=$(aws ec2 describe-instances --instance-ids $SourceInstanceId  --query 'Reservations[].Instances[].RootDeviceName' --output text)
#SoueceBlockDataDevices=$(aws ec2 describe-instances --instance-ids $SourceInstanceId  --query 'Reservations[].Instances[].BlockDeviceMappings[].{name:DeviceName,id:Ebs.VolumeId}' --output text)>$SourceInstanceId.txt
echo "Source EBS Mapping:"
aws ec2 describe-instances --instance-ids $SourceInstanceId  --query 'Reservations[].Instances[].BlockDeviceMappings[].{name:DeviceName,id:Ebs.VolumeId}' --output text >$SourceInstanceId.txt

j=0
while IFS= read line
do
  DataVolumes[$j]=$(echo "$line"|awk '{print $1}')
  DataDevices[$j]=$(echo "$line"|awk '{print $2}')
  j=$((j+1))
done <"$SourceInstanceId.txt"

#echo "${DataVolumes[@]}"
#echo "${DataDevices[@]}"
k=${#DataDevices[*]}
for ((i=0; i<$k; i++));
do
  #  echo "DataDevices$i   ${DataDevices[i]}"
  if [ "${DataDevices[i]}" == "$SourceRootDeviceName" ]
  then
    RootDevice[$i]=$SourceRootDeviceName
    RootVolume[$i]=${DataVolumes[$i]}
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

echo "Stopping source EC2..."
aws ec2 stop-instances --instance-ids $SourceInstanceId

aws ec2 wait instance-stopped --instance-ids  $SourceInstanceId
echo "EC2 instance $SourceInstanceId is stopped"


echo "Detach source EC2 root device $SourceRootDeviceName ----> ${RootVolume[@]}"
aws ec2 detach-volume --volume-id ${RootVolume[@]}
k=${#DataDevices[*]}
for ((i=0; i<$k; i++));
do
  echo "Detach data volume ${DataVolumes[$i]} as ${DataDevices[$i]} from source EC2 instacne ( $SourceInstanceId )"
  aws ec2 detach-volume --volume-id ${DataVolumes[i]}
done

echo "Terninating source EC2"
aws ec2 terminate-instances --instance-ids $SourceInstanceId

aws ec2 wait instance-terminated --instance-ids  $SourceInstanceId
echo "EC2 instance $SourceInstanceId is terminated"

placement="Tenancy=$TenancyType"
echo "Creating target EC2"
aws ec2 run-instances --image-id $TargetAMI --instance-type $InstanceType --placement $placement --private-ip-address $PrivateIpAddress --count 1 --key-name $KeyPair --security-group-ids  $TargetSecurityGroupId --subnet-id $SubnetId >$SourceInstanceId.target

TargetInstanceId=$(cat $SourceInstanceId.target| egrep  InstanceId  |cut -d: -f2|sed 's/"//g' |sed 's/,//g')
echo "Target Instance ID = $TargetInstanceId"

TargetRootVolumeId=$(aws ec2 describe-instances --instance-ids $TargetInstanceId  --query 'Reservations[].Instances[].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
echo "Targe root volume ID =$TargetRootVolumeId"

TargetRootDeviceName=$(aws ec2 describe-instances --instance-ids $TargetInstanceId  --query 'Reservations[].Instances[].RootDeviceName' --output text)
echo "Target root device name = $TargetRootDeviceName"

echo "Waiting for instance ($TargetInstanceId) running ..."
aws ec2 wait instance-running --instance-ids  $TargetInstanceId

echo "Stopping target EC2"
aws ec2 stop-instances --instance-ids $TargetInstanceId

aws ec2 wait instance-stopped --instance-ids  $TargetInstanceId
echo "EC2 instance $TargetInstanceId is stopped"


echo "Detach target EC2 root device $TargetRootDeviceName ----> $TargetRootVolumeId"
aws ec2 detach-volume --volume-id $TargetRootVolumeId


echo "Delete target EC2 root volume: $TargetRootVolumeId"
aws ec2 delete-volume --volume-id $TargetRootVolumeId

echo "Attach root volume ${RootVolume[@]} as $TargetRootDeviceName to target EC2 instacne ($TargetInstanceId)"
aws ec2 attach-volume --device $TargetRootDeviceName --instance-id $TargetInstanceId  --volume-id ${RootVolume[@]}

k=${#DataDevices[*]}
for ((i=0; i<$k; i++));
do
  echo "Attach data volume ${DataVolumes[$i]} as ${DataDevices[$i]} to target EC2 instacne ($TargetInstanceId)"
  aws ec2 attach-volume --device ${DataDevices[$i]} --instance-id $TargetInstanceId  --volume-id ${DataVolumes[$i]}
done

echo "Starting target EC2..."
aws ec2 start-instances --instance-ids $TargetInstanceId

rm $SourceInstanceId.target
rm $SourceInstanceId.txt
