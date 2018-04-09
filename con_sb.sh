#!/bin/bash
#example:
# bash ./con_sb.sh -i i-0abf306a8623699b8  -a ami-d8578bb5  -g sg-0695ca0de00bdd034  -t dedicated
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
    # -k|--KeyPair)
    #   KeyPair="$2"
    #   shift # past argument
    #   shift # past value
    #   ;;
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
begin_time=$(date +%s)
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

SID=$(aws ec2 describe-instance-attribute --instance-id $SourceInstanceId  --attribute groupSet --output text|egrep GROUPS |cut -f2|awk '{printf"%s " , $0}')
SourceSecurityGroupId=$(echo $SID|cut -c1-$((${#SID}-1)))

KeyPair=$(aws ec2 describe-instances  --instance-id $SourceInstanceId  --query 'Reservations[].Instances[].KeyName' --output text)
echo "KeyPair Name = $KeyPair"
echo "Source Security Groups: $SourceSecurityGroupId"

# get security groups of source instance
if [ $TargetSecurityGroupId == "S" ];
then
  TargetSecurityGroupId=$SourceSecurityGroupId
else
  TargetSecurityGroupId=$TargetSecurityGroupId" "$SourceSecurityGroupId
fi
echo "Target Security Group: $TargetSecurityGroupId"
SourceTags=$(aws ec2 describe-instances --instance-id $SourceInstanceId --query 'Reservations[].Instances[].Tags[]')

echo "Source tags:"
echo "$SourceTags"
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

# copy source instance tags to target
a="[]"
if  [[ $SourceTags != $a ]];
 then
   echo "Copying source tags to target"
   echo "$SourceTags" > $SourceInstanceId.json
   aws ec2 create-tags --resources $TargetInstanceId --tags file://$SourceInstanceId.json
fi

#Adding new namne tag
H_NO=$(echo $PrivateIpAddress | awk -F. '{OFS=""; printf "%.3d%.3d\n",$3,$4}')
HOST="SVC${H_NO}"
aws ec2 create-tags --resources $TargetInstanceId --tags Key=Name,Value=$HOST

TargetRootVolumeId=$(aws ec2 describe-instances --instance-ids $TargetInstanceId  --query 'Reservations[].Instances[].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
echo "Targe root volume ID =$TargetRootVolumeId"

TargetRootDeviceName=$(aws ec2 describe-instances --instance-ids $TargetInstanceId  --query 'Reservations[].Instances[].RootDeviceName' --output text)
echo "Target root device name =$TargetRootDeviceName"

echo "Waiting for instance ($HOST--$TargetInstanceId) running ..."
aws ec2 wait instance-running --instance-ids  $TargetInstanceId

echo "Stopping target EC2 ($HOST--$TargetInstanceId)"
aws ec2 stop-instances --instance-ids $TargetInstanceId

aws ec2 wait instance-stopped --instance-ids  $TargetInstanceId
echo "EC2 instance ($HOST--$TargetInstanceId) is stopped"

echo "Detach $HOST's root device $TargetRootDeviceName ----> $TargetRootVolumeId"
aws ec2 detach-volume --volume-id $TargetRootVolumeId

echo "Delete $HOST's root volume: $TargetRootVolumeId"
aws ec2 delete-volume --volume-id $TargetRootVolumeId

echo "Attach root volume ${RootVolume[@]} as $TargetRootDeviceName to target EC2 instacne ($HOST--$TargetInstanceId)"
aws ec2 attach-volume --device $TargetRootDeviceName --instance-id $TargetInstanceId  --volume-id ${RootVolume[@]}

k=${#DataDevices[*]}
for ((i=0; i<$k; i++));
do
  echo "Attach data volume ${DataVolumes[$i]} as ${DataDevices[$i]} to target EC2 instacne ($HOST--$TargetInstanceId)"
  aws ec2 attach-volume --device ${DataDevices[$i]} --instance-id $TargetInstanceId  --volume-id ${DataVolumes[$i]}
done

echo "Starting $HOST..."
aws ec2 start-instances --instance-ids $TargetInstanceId

rm $SourceInstanceId.*

end_time=$(date +%s)
cost_time=$(($end_time-$begin_time))

echo "Total execution time: $cost_time seconds"
