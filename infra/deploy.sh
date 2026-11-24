#!/bin/bash
# Your group's deploy script. Put every command you run here, in order,
# so any member can rebuild your infra from zero on their machine.
set -e
cd "$(dirname "$0")/.." && . ./env.sh
: "${GROUP:?export GROUP=gXX first}"

# ---------- M0, setup + IAM ----------

# One IAM user per member (solo project: just me)
MEMBERS="thomas"
for u in $MEMBERS; do
  aws iam create-user --user-name $GROUP-$u >/dev/null
done

# A group that holds the admin rights, so rights are managed once, not per person
aws iam create-group --group-name $GROUP-admins >/dev/null
aws iam attach-group-policy \
  --group-name $GROUP-admins \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
for u in $MEMBERS; do
  aws iam add-user-to-group --group-name $GROUP-admins --user-name $GROUP-$u
done

# Read-only auditor: read S3 and EC2, nothing else (no Allow means denied)
aws iam create-user --user-name $GROUP-auditor >/dev/null
aws iam put-user-policy \
  --user-name $GROUP-auditor \
  --policy-name read-only \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:List*", "s3:Get*", "ec2:Describe*"],
      "Resource": "*"
    }]
  }'

# The group bucket (status page from M1)
aws s3api create-bucket --bucket $GROUP-site >/dev/null

# The auditor's AccessDenied proof is run by hand once, see NOTES.md (M0)

# ---------- M1, compute + data (naive on purpose, fixed in M2/M3) ----------

# The app: traefik/whoami, listens on :80 and prints its Hostname
[ -d app-src ] || git clone --depth 1 https://github.com/traefik/whoami.git app-src
aws ecr create-repository --repository-name $GROUP-app >/dev/null
docker build -t $REGISTRY/$GROUP-app:v1 app-src
docker push $REGISTRY/$GROUP-app:v1          # Floci: push to $REGISTRY, not the ECR URI
aws ecr list-images --repository-name $GROUP-app

# Network, naive: default VPC, two subnets in two AZs, port 80 open to everyone (sin 1)
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC --query 'Subnets[0:2].SubnetId' --output text | tr '\t' ',')
ALB_SG=$(aws ec2 create-security-group --group-name $GROUP-alb-sg --description "ALB, open to the world" --vpc-id $VPC --query GroupId --output text)
APP_SG=$(aws ec2 create-security-group --group-name $GROUP-app-sg --description "App, open to the world (sin 1)" --vpc-id $VPC --query GroupId --output text)
for sg in $ALB_SG $APP_SG; do
  aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
done

# Load balancer: ALB -> listener :80 -> target group (ip targets, health check /)
ALB=$(aws elbv2 create-load-balancer --name $GROUP-alb --subnets ${SUBNETS//,/ } --security-groups $ALB_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG=$(aws elbv2 create-target-group --name $GROUP-tg --protocol HTTP --port 80 --vpc-id $VPC \
  --target-type ip --health-check-path / --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 create-listener --load-balancer-arn $ALB --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG >/dev/null

# ECS: cluster, task definition (Fargate, 0.25 vCPU / 512 MB), one service behind the ALB
aws ecs create-cluster --cluster-name $GROUP >/dev/null
aws ecs register-task-definition --family $GROUP-app --network-mode awsvpc \
  --requires-compatibilities FARGATE --cpu 256 --memory 512 \
  --container-definitions "[{\"name\":\"app\",\"image\":\"$REGISTRY/$GROUP-app:v1\",\"portMappings\":[{\"containerPort\":80}],\"essential\":true}]" >/dev/null
aws ecs create-service --cluster $GROUP --service-name $GROUP-app --task-definition $GROUP-app \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$APP_SG],assignPublicIp=ENABLED}" \
  --load-balancers targetGroupArn=$TG,containerName=app,containerPort=80 >/dev/null
echo "App: http://$(aws elbv2 describe-load-balancers --names $GROUP-alb --query 'LoadBalancers[0].DNSName' --output text)/"

# Database: public Postgres (sin 2). The password was in clear here (sin 3) until M3:
# it now lives in Secrets Manager, created first so no script ever types it.
SECRET_ARN=$(aws secretsmanager create-secret --name $GROUP/db-password \
  --secret-string "$(aws secretsmanager get-random-password --password-length 24 --exclude-punctuation --query RandomPassword --output text)" \
  --query ARN --output text)
db_password(){ aws secretsmanager get-secret-value --secret-id $GROUP/db-password --query SecretString --output text; }
aws rds create-db-instance --db-instance-identifier $GROUP-db --engine postgres \
  --db-instance-class db.t3.micro --allocated-storage 20 \
  --master-username app --master-user-password "$(db_password)" --publicly-accessible >/dev/null

# Status page: static website on the group bucket, readable by anyone
echo "<h1>$GROUP is up</h1>" > /tmp/$GROUP-index.html
aws s3 cp /tmp/$GROUP-index.html s3://$GROUP-site/index.html --content-type text/html >/dev/null
aws s3 website s3://$GROUP-site/ --index-document index.html
aws s3api delete-public-access-block --bucket $GROUP-site
aws s3api put-bucket-policy --bucket $GROUP-site --policy "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [{\"Effect\": \"Allow\", \"Principal\": \"*\", \"Action\": \"s3:GetObject\",
                   \"Resource\": \"arn:aws:s3:::$GROUP-site/*\"}]}"
echo "Status: http://$GROUP-site.s3-website-us-east-1.localhost:4566/"

# The VM way (step 7) was a one-off demo: run-instances + user data serving :8080,
# checked with docker exec, then terminated. Not part of the platform.

# ---------- M2, private network ----------

# VPC 10.0.0.0/16: 2 public subnets (ALB) + 2 private subnets (app, DB), in 2 AZs
VPC2=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$GROUP-vpc}]" --query Vpc.VpcId --output text)
sub(){ aws ec2 create-subnet --vpc-id $VPC2 --cidr-block $1 --availability-zone $2 \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=$GROUP-$3}]" --query Subnet.SubnetId --output text; }
PUB_A=$(sub 10.0.1.0/24 us-east-1a pub-a);    PUB_B=$(sub 10.0.2.0/24 us-east-1b pub-b)
PRIV_A=$(sub 10.0.11.0/24 us-east-1a priv-a); PRIV_B=$(sub 10.0.12.0/24 us-east-1b priv-b)

# Doors: public subnets route to the internet gateway, private ones go out through a NAT
# (Floci: these exist in the API but route nothing, real AWS needs them)
IGW=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC2
PUB_RT=$(aws ec2 create-route-table --vpc-id $VPC2 --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $PUB_RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW >/dev/null
for s in $PUB_A $PUB_B; do aws ec2 associate-route-table --route-table-id $PUB_RT --subnet-id $s >/dev/null; done
EIP=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
NAT=$(aws ec2 create-nat-gateway --subnet-id $PUB_A --allocation-id $EIP --query NatGateway.NatGatewayId --output text)
PRIV_RT=$(aws ec2 create-route-table --vpc-id $VPC2 --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id $PRIV_RT --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT >/dev/null
for s in $PRIV_A $PRIV_B; do aws ec2 associate-route-table --route-table-id $PRIV_RT --subnet-id $s >/dev/null; done

# Security-group chain: internet -> ALB:80 -> app:80 -> DB:5432
ALB_SG2=$(aws ec2 create-security-group --group-name $GROUP-alb-sg2 --description "ALB: 80 from the internet" --vpc-id $VPC2 --query GroupId --output text)
APP_SG2=$(aws ec2 create-security-group --group-name $GROUP-app-sg2 --description "App: 80 from the load balancer only" --vpc-id $VPC2 --query GroupId --output text)
DB_SG2=$(aws ec2 create-security-group --group-name $GROUP-db-sg2 --description "DB: 5432 from the app only" --vpc-id $VPC2 --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $ALB_SG2 --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
# Floci's ALB is not a container, it sits on the Docker bridge. Real AWS: --source-group $ALB_SG2
aws ec2 authorize-security-group-ingress --group-id $APP_SG2 --protocol tcp --port 80 --cidr 172.17.0.0/16 >/dev/null
aws ec2 authorize-security-group-ingress --group-id $DB_SG2 --protocol tcp --port 5432 --source-group $APP_SG2 >/dev/null

# The only public door: ALB in the public subnets
ALB2=$(aws elbv2 create-load-balancer --name $GROUP-alb2 --subnets $PUB_A $PUB_B --security-groups $ALB_SG2 \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG2=$(aws elbv2 create-target-group --name $GROUP-tg2 --protocol HTTP --port 80 --vpc-id $VPC2 \
  --target-type ip --health-check-path / --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 create-listener --load-balancer-arn $ALB2 --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG2 >/dev/null

# App moves in: private subnets, no public IP
aws ecs create-service --cluster $GROUP --service-name $GROUP-app2 --task-definition $GROUP-app \
  --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIV_A,$PRIV_B],securityGroups=[$APP_SG2],assignPublicIp=DISABLED}" \
  --load-balancers targetGroupArn=$TG2,containerName=app,containerPort=80 >/dev/null

# DB moves in: private subnets, not public, password from Secrets Manager
aws rds create-db-subnet-group --db-subnet-group-name $GROUP-db-subnets \
  --db-subnet-group-description "private subnets" --subnet-ids $PRIV_A $PRIV_B >/dev/null
aws rds create-db-instance --db-instance-identifier $GROUP-db2 --engine postgres \
  --db-instance-class db.t3.micro --allocated-storage 20 \
  --master-username app --master-user-password "$(db_password)" \
  --vpc-security-group-ids $DB_SG2 --db-subnet-group-name $GROUP-db-subnets --no-publicly-accessible >/dev/null
echo "App: http://$(aws elbv2 describe-load-balancers --names $GROUP-alb2 --query 'LoadBalancers[0].DNSName' --output text)/"

# Tear down the naive M1 deploy (service, ALB, target group, public DB, open SGs)
aws ecs update-service --cluster $GROUP --service $GROUP-app --desired-count 0 >/dev/null
aws ecs delete-service --cluster $GROUP --service $GROUP-app >/dev/null
aws elbv2 delete-listener --listener-arn $(aws elbv2 describe-listeners --load-balancer-arn $ALB --query 'Listeners[0].ListenerArn' --output text)
aws elbv2 delete-load-balancer --load-balancer-arn $ALB
aws elbv2 delete-target-group --target-group-arn $TG
aws rds delete-db-instance --db-instance-identifier $GROUP-db --skip-final-snapshot >/dev/null
aws ec2 delete-security-group --group-id $ALB_SG
aws ec2 delete-security-group --group-id $APP_SG

# Proof, run by hand: ./checks/intruder.sh  ->  app BLOCKED (see NOTES.md, M2)

# ---------- M3, secrets + monitoring + least privilege ----------

# The secret $GROUP/db-password exists since the M1 DB step. Rotation: the DB gets
# the secret's value, so the old hard-coded password no longer works anywhere.
aws rds modify-db-instance --db-instance-identifier $GROUP-db2 --apply-immediately \
  --master-user-password "$(db_password)" >/dev/null

# Execution role: ECS may read this one secret and write logs, nothing else
EXEC_ROLE=$(aws iam create-role --role-name $GROUP-exec-role --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "ecs-tasks.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}' --query Role.Arn --output text)
aws iam put-role-policy --role-name $GROUP-exec-role --policy-name read-secret-write-logs --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": \"secretsmanager:GetSecretValue\", \"Resource\": \"$SECRET_ARN\"},
    {\"Effect\": \"Allow\", \"Action\": [\"logs:CreateLogStream\", \"logs:PutLogEvents\"], \"Resource\": \"*\"}]}"

# Logs + task revision 2: DB host/port as plain config, the password injected from the secret
aws logs create-log-group --log-group-name /ecs/$GROUP-app
read DB_HOST DB_PORT < <(aws rds describe-db-instances --db-instance-identifier $GROUP-db2 \
  --query 'DBInstances[0].Endpoint.[Address,Port]' --output text)
aws ecs register-task-definition --family $GROUP-app --network-mode awsvpc \
  --requires-compatibilities FARGATE --cpu 256 --memory 512 --execution-role-arn $EXEC_ROLE \
  --container-definitions "[{
    \"name\": \"app\", \"image\": \"$REGISTRY/$GROUP-app:v1\", \"essential\": true,
    \"portMappings\": [{\"containerPort\": 80}],
    \"environment\": [{\"name\": \"DB_HOST\", \"value\": \"$DB_HOST\"}, {\"name\": \"DB_PORT\", \"value\": \"$DB_PORT\"}],
    \"secrets\": [{\"name\": \"DB_PASSWORD\", \"valueFrom\": \"$SECRET_ARN\"}],
    \"logConfiguration\": {\"logDriver\": \"awslogs\", \"options\": {
      \"awslogs-group\": \"/ecs/$GROUP-app\", \"awslogs-region\": \"us-east-1\", \"awslogs-stream-prefix\": \"app\"}}}]" >/dev/null
aws ecs update-service --cluster $GROUP --service $GROUP-app2 --task-definition $GROUP-app >/dev/null

# Pager: alarm -> SNS topic -> SQS queue (Floci sends no email)
TOPIC=$(aws sns create-topic --name $GROUP-alerts --query TopicArn --output text)
PAGER=$(aws sqs create-queue --queue-name $GROUP-pager --query QueueUrl --output text)
PAGER_ARN=$(aws sqs get-queue-attributes --queue-url $PAGER --attribute-names QueueArn --query Attributes.QueueArn --output text)
aws sns subscribe --topic-arn $TOPIC --protocol sqs --notification-endpoint $PAGER_ARN >/dev/null
aws cloudwatch put-metric-alarm --alarm-name $GROUP-errors --namespace $GROUP --metric-name Errors \
  --statistic Sum --period 60 --evaluation-periods 1 --threshold 1 \
  --comparison-operator GreaterThanOrEqualToThreshold --alarm-actions $TOPIC
# Test, by hand: put-metric-data Errors=3, then sqs receive-message on $PAGER (see NOTES.md, M3)

# Deployer role: can roll the app service and read its logs, nothing else
aws iam create-role --role-name $GROUP-deployer --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"AWS": "arn:aws:iam::000000000000:root"}, "Action": "sts:AssumeRole"}]
}' >/dev/null
aws iam put-role-policy --role-name $GROUP-deployer --policy-name deploy-only --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": [\"ecs:DescribeServices\", \"ecs:UpdateService\"],
     \"Resource\": \"arn:aws:ecs:us-east-1:000000000000:service/$GROUP/$GROUP-app2\"},
    {\"Effect\": \"Allow\", \"Action\": [\"ecs:RegisterTaskDefinition\", \"ecs:DescribeTaskDefinition\",
       \"logs:GetLogEvents\", \"logs:FilterLogEvents\", \"logs:DescribeLogStreams\"], \"Resource\": \"*\"},
    {\"Effect\": \"Allow\", \"Action\": \"iam:PassRole\", \"Resource\": \"$EXEC_ROLE\"}]}"
# Proof, by hand: sts assume-role as the deployer, update-service works,
# rds delete-db-instance is AccessDenied (see NOTES.md, deployer proof)

# ---------- M4, scale + survive + CDN ----------

# Two containers; the service's private subnets are in 2 AZs
aws ecs update-service --cluster $GROUP --service $GROUP-app2 --desired-count 2 >/dev/null

# Our own autoscaler: alarm -> SNS -> Lambda that moves desiredCount by 1, clamped to [2, 4]
python3 -m zipfile -c /tmp/$GROUP-scaler.zip infra/scaler.py
aws iam create-role --role-name $GROUP-scaler-role --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": ["lambda.amazonaws.com", "scheduler.amazonaws.com"]}, "Action": "sts:AssumeRole"}]
}' >/dev/null
aws iam put-role-policy --role-name $GROUP-scaler-role --policy-name scale-one-service --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\": \"Allow\", \"Action\": [\"ecs:DescribeServices\", \"ecs:UpdateService\"],
     \"Resource\": \"arn:aws:ecs:us-east-1:000000000000:service/$GROUP/$GROUP-app2\"},
    {\"Effect\": \"Allow\", \"Action\": [\"logs:CreateLogGroup\", \"logs:CreateLogStream\", \"logs:PutLogEvents\",
       \"lambda:InvokeFunction\"], \"Resource\": \"*\"}]}"
SCALER=$(aws lambda create-function --function-name $GROUP-scaler --runtime python3.12 --handler scaler.handler \
  --zip-file fileb:///tmp/$GROUP-scaler.zip --role arn:aws:iam::000000000000:role/$GROUP-scaler-role \
  --environment "Variables={CLUSTER=$GROUP,SERVICE=$GROUP-app2,MIN=2,MAX=4}" --query FunctionArn --output text)
SCALE_TOPIC=$(aws sns create-topic --name $GROUP-scale --query TopicArn --output text)
aws sns subscribe --topic-arn $SCALE_TOPIC --protocol lambda --notification-endpoint $SCALER >/dev/null
aws lambda add-permission --function-name $GROUP-scaler --statement-id from-sns --action lambda:InvokeFunction \
  --principal sns.amazonaws.com --source-arn $SCALE_TOPIC >/dev/null
# Floci has no CPU metric: the app's load is a custom metric $GROUP/Load. OK scales back in.
aws cloudwatch put-metric-alarm --alarm-name $GROUP-load-high --namespace $GROUP --metric-name Load \
  --statistic Average --period 60 --evaluation-periods 1 --threshold 70 \
  --comparison-operator GreaterThanThreshold --alarm-actions $SCALE_TOPIC --ok-actions $SCALE_TOPIC
# Load test, by hand: put-metric-data Load=95 (2 -> 3), then Load=10 (3 -> 2), see NOTES.md

# CloudFront in front of the status page
CF_ID=$(aws cloudfront create-distribution --origin-domain-name $GROUP-site.s3.amazonaws.com \
  --default-root-object index.html --query Distribution.Id --output text)
echo "Status via CDN: http://$CF_ID.cloudfront.localhost.floci.io:4566/"
