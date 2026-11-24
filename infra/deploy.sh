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

# Database: public Postgres with a password in clear (sins 2 and 3)
aws rds create-db-instance --db-instance-identifier $GROUP-db --engine postgres \
  --db-instance-class db.t3.micro --allocated-storage 20 \
  --master-username app --master-user-password 'ChangeMe-123' --publicly-accessible >/dev/null

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
