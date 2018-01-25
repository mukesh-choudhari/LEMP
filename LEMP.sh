#!/bin/bash
keyName=`ls ./pem/*.pem | xargs basename`
keyNameWithoutExtension=`echo $keyName | cut -f 1 -d '.'`
mySQLUser=lempUser
mySQLPass=lempUser1234

#### Obtain Default VPC Id and all its subnets

echo -e "\n Obtaining Default VPC Id..."
VpcId=`aws ec2 describe-vpcs --filters Name=isDefault,Values=true | grep VpcId | awk -F'"' '{print $4}'`
echo " Default VPC Id is : $VpcId"

echo -e "\n Obtaining Subnets in the Default VPC..."
aws ec2 describe-subnets --filters Name=vpc-id,Values=$VpcId | grep SubnetId > Subnets.txt
cat Subnets.txt
if [[ `cat Subnets.txt | wc -l` -lt 2 ]]; then
  echo -e "\n #### ERROR: Default VPC must have at least 2 Subnets !!"
  exit 1
fi
subnet1=`cat Subnets.txt | head -1 | awk -F'"' '{print $4}'`
subnet2=`cat Subnets.txt | tail -1 | awk -F'"' '{print $4}'`
rm -rf Subnets.txt

#### Create new security group with required configuration

echo -e "\n Creating new Security Group in the VPC for our LEMP Application..."
sGroupId=`aws ec2 create-security-group --group-name myLempApplicationSG --description "My security group for LEMP Application" --vpc-id $VpcId | grep GroupId | awk -F'"' '{print $4}'`
echo " Security Group created : Name = myLempApplicationSG, ID = $sGroupId"

echo -e "\n Adding inbound rules to the Security Group..."
aws ec2 authorize-security-group-ingress --group-id $sGroupId --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $sGroupId --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $sGroupId --protocol tcp --port 3306 --cidr 0.0.0.0/0
echo -e " Inbound rules added to the Security Group\n TCP ; Port 22,80,3306 ; CIDR 0.0.0.0/0"

#### Launch MySql Server in AWS RDS

echo -e "\n Launching a MySQL Server in AWS RDS..."
aws rds create-db-instance --db-name visitors --db-instance-identifier myLEMPApplicationDB --engine mysql --engine-version 5.7.17 --db-instance-class db.t2.micro --allocated-storage 20 --master-username $mySQLUser --master-user-password $mySQLPass --vpc-security-group-ids $sGroupId
echo " Please wait while the creation completes..."
sleep 5
while ! [[ `aws rds describe-db-instances --db-instance-identifier myLEMPApplicationDB | grep DBInstanceStatus | grep available` ]]
do
  if [[ `aws rds describe-db-instances --db-instance-identifier myLEMPApplicationDB | grep DBInstanceStatus | grep failure` ]]; then
    echo -e "\n #### ERROR: Failed to create MySQL Server in AWS RDS !!"
    exit 1
  fi
  sleep 40
done
mySQLHost=`aws rds describe-db-instances --db-instance-identifier myLEMPApplicationDB | grep -A 4 Endpoint | grep Address | awk -F'"' '{print $4}'`
echo " MySQL Server creation successful : Name = myLEMPApplicationDB, ConnectionPoint = $mySQLHost, Port = 3306"

#### Obtain the AMI Id of the LEMP Application Server, Create Instance and Copy the Application files on it

echo -e "\n Creating EC2 instance from the Shared AMI and uploading the php files..."
amiId=`aws ec2 describe-images --filters Name=description,Values="LEMP_Application" | grep ImageId | awk -F'"' '{print $4}'`
echo "AMI Id is : $amiId"
echo "Launching EC2 instance now..."
instanceID=`aws ec2 run-instances --image-id $amiId --count 1 --instance-type t2.micro --key-name $keyNameWithoutExtension --security-group-ids $sGroupId | grep InstanceId | awk -F'"' '{print $4}'`
echo " Instance Launched from the AMI. Instance ID is : $instanceID"
while ! [[ `aws ec2 describe-instances --instance-ids $instanceID | grep -A 3 State | grep Name | grep running` ]]
do
  if [[ `aws ec2 describe-instances --instance-ids $instanceID | grep -A 3 State | grep Name | grep failure` ]]; then
    echo -e "\n #### ERROR: Failed to launch EC2 from AMI. !!"
    exit 1
  fi
  sleep 20
done
publicDnsName=`aws ec2 describe-instances --instance-ids $instanceID | grep -m 1 PublicDnsName | awk -F'"' '{print $4}'`
echo " EC2 creation successful with PublcDnsName : $publicDnsName"

sleep 100 #The EC2 machine is powered on but OS takes time to boot
echo -e "\n Modify the index.php file to point to the newly created MySQL service..."
cp ./php/index.php ./php/index.php_old
sed -i "/{MYSQL_HOST}/s/{MYSQL_HOST}/$mySQLHost/g" ./php/index.php
sed -i "/{MYSQL_USER}/s/{MYSQL_USER}/$mySQLUser/g" ./php/index.php
sed -i "/{MYSQL_PASS}/s/{MYSQL_PASS}/$mySQLPass/g" ./php/index.php
sed -i 's/\r//g' ./php/index.php
echo -e " Modification done. Now Copy the files to the AWS EC2 instance..."
ssh -o StrictHostKeyChecking=no -i ./pem/$keyName ec2-user@$publicDnsName "sudo chmod -R 777 /var/www/html"
scp -o StrictHostKeyChecking=no -i ./pem/$keyName -r ./php/*.php ec2-user@$publicDnsName:/var/www/html/
mv -f ./php/index.php_old ./php/index.php
echo -e " Files have been copied to the EC2 Instance. Now create AMI of the instance for Auto-Scaling..."
aws ec2 stop-instances --instance-ids $instanceID
while ! [[ `aws ec2 describe-instances --instance-ids $instanceID | grep -A 3 State | grep Name | grep stopped` ]]
do
  if [[ `aws ec2 describe-instances --instance-ids $instanceID | grep -A 3 State | grep Name | grep failure` ]]; then
    echo -e "\n #### ERROR: Failed to stop EC2 Instance for AMI creation. !!"
    exit 1
  fi
  sleep 20
done
AMIId=`aws ec2 create-image --instance-id $instanceID --name myLEMPApplicationAMI | grep ImageId | awk -F'"' '{print $4}'`
sleep 100 #Wait for AMI creation to complete 
aws ec2 terminate-instances --instance-ids $instanceID
echo " New AMI successfully created with AMI ID : $AMIId"

#### Now create and launch the Auto-Scaling group with new AMI

echo -e "\n Now creating Auto-Scale Group..."
echo " First Create Launch Configuration..."
aws autoscaling create-launch-configuration --launch-configuration-name myLEMPApplicationLC --key-name $keyNameWithoutExtension --image-id $AMIId --security-groups $sGroupId --instance-type t2.micro
sleep 5
echo " Launch Configuration successfully created !"
echo " Now create target groups for Load Balancer..."
aws elbv2 create-target-group --name myLEMPApplicationTG --protocol HTTP --port 80 --vpc-id $VpcId
sleep 5
TGArn=`aws elbv2 describe-target-groups --name myLEMPApplicationTG | grep TargetGroupArn | awk -F'"' '{print $4}'`
echo " Target Group successfully created !"
echo " Now create Auto-Scaling Group and link with the Target Group and Launch Configuration..."
aws autoscaling create-auto-scaling-group --auto-scaling-group-name myLEMPApplicationSG --launch-configuration-name myLEMPApplicationLC --min-size 1 --max-size 3 --default-cooldown 0 --target-group-arns $TGArn --no-new-instances-protected-from-scale-in --vpc-zone-identifier $subnet1
sleep 15

#### Create the Load Balancer 

aws elbv2 create-load-balancer --name myLEMPApplicationLB --subnets "$subnet1" "$subnet2" --security-groups $sGroupId --scheme internet-facing --type application --ip-address-type ipv4
sleep 5
while ! [[ `aws elbv2 describe-load-balancers --name myLEMPApplicationLB | grep -A 3 State | grep Code | grep active` ]]
do
  if [[ `aws elbv2 describe-load-balancers --name myLEMPApplicationLB | grep -A 3 State | grep Code | grep failure` ]]; then
    echo -e "\n #### ERROR: Failed to create Load Balancer !!"
    exit 1
  fi
  sleep 20
done
sleep 5
LBArn=`aws elbv2 describe-load-balancers --name myLEMPApplicationLB | grep LoadBalancerArn | awk -F'"' '{print $4}'`
LBDnsName=`aws elbv2 describe-load-balancers --name myLEMPApplicationLB | grep DNSName | awk -F'"' '{print $4}'`
echo " Load Balancer creation successful : Name = myLEMPApplicationLB, DNS Name = $LBDnsName"
echo " Now create listeners in the Load Balancer..."
aws elbv2 describe-listeners --load-balancer-arn $LBArn
aws elbv2 create-listener --load-balancer-arn $LBArn --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TGArn
sleep 20

echo -e "\n\n Complete deployment has been successful."
echo -e "\n Access the application via the Load Balancer Public DNS Name : $LBDnsName"
