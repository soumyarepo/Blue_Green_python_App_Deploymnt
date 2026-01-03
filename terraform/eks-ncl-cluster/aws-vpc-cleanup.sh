#!/bin/bash

set -e

# === Config ===
REGION="ap-south-1"
CLUSTER_NAME="blue_green_deploymt-cluster"

# === Colors ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# === Check Dependencies ===
if ! command -v jq &> /dev/null; then
  error "'jq' is not installed. Please install jq to proceed."
  exit 1
fi

# === Confirm Cleanup ===
info "🛡️ AWS Intelligent VPC & EKS Cleanup Tool"
info "Target Region: $REGION | EKS Cluster: $CLUSTER_NAME"
read -p "Are you sure you want to continue cleanup? [y/N] " confirm
if [[ "$confirm" != "y" ]]; then
  echo "Aborted."
  exit 0
fi

info "🔍 Starting intelligent cleanup in region: $REGION"

# === Delete EKS Resources ===
CLUSTER_EXISTS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" 2>/dev/null || true)
if [[ -z "$CLUSTER_EXISTS" ]]; then
  warn "EKS cluster '$CLUSTER_NAME' not found. Skipping EKS cleanup."
else
  info "🧹 Deleting EKS cluster: $CLUSTER_NAME"
  NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$REGION" | jq -r '.nodegroups[]')
  for ng in $NODEGROUPS; do
    info "Deleting nodegroup: $ng"
    aws eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$REGION"
  done

  FARGATE_PROFILES=$(aws eks list-fargate-profiles --cluster-name "$CLUSTER_NAME" --region "$REGION" | jq -r '.fargateProfileNames[]')
  for fp in $FARGATE_PROFILES; do
    info "Deleting Fargate profile: $fp"
    aws eks delete-fargate-profile --cluster-name "$CLUSTER_NAME" --fargate-profile-name "$fp" --region "$REGION"
  done

  info "Waiting for EKS cluster deletion..."
  aws eks delete-cluster --name "$CLUSTER_NAME" --region "$REGION"
fi

# === List VPCs ===
VPCS=$(aws ec2 describe-vpcs --region "$REGION" | jq -r '.Vpcs[].VpcId')

for VPC_ID in $VPCS; do
  info "🔍 Checking ELBs in VPC: $VPC_ID"

  # Classic ELBs
  ELBS=$(aws elb describe-load-balancers --region "$REGION" | jq -r ".LoadBalancerDescriptions[] | select(.VPCId==\"$VPC_ID\") | .LoadBalancerName")
  for elb in $ELBS; do
    info "Deleting Classic ELB: $elb"
    aws elb delete-load-balancer --load-balancer-name "$elb" --region "$REGION"
  done

  # ALBs/NLBs
  ALBS=$(aws elbv2 describe-load-balancers --region "$REGION" | jq -r ".LoadBalancers[] | select(.VpcId==\"$VPC_ID\") | .LoadBalancerArn")
  for alb in $ALBS; do
    info "Deleting ALB/NLB: $alb"
    aws elbv2 delete-load-balancer --load-balancer-arn "$alb" --region "$REGION"
  done

  # Wait a bit to detach dependencies
  sleep 5

  # Delete NAT Gateways
  NAT_GWS=$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values=$VPC_ID --region "$REGION" | jq -r '.NatGateways[].NatGatewayId')
  for nat in $NAT_GWS; do
    info "Deleting NAT Gateway: $nat"
    aws ec2 delete-nat-gateway --nat-gateway-id "$nat" --region "$REGION"
  done

  sleep 5

  # Delete Internet Gateways
  IGWS=$(aws ec2 describe-internet-gateways --filter Name=attachment.vpc-id,Values=$VPC_ID --region "$REGION" | jq -r '.InternetGateways[].InternetGatewayId')
  for igw in $IGWS; do
    info "Detaching and deleting Internet Gateway: $igw"
    aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC_ID" --region "$REGION"
    aws ec2 delete-internet-gateway --internet-gateway-id "$igw" --region "$REGION"
  done

  # Delete Route Tables (except main)
  RTBS=$(aws ec2 describe-route-tables --filter Name=vpc-id,Values=$VPC_ID --region "$REGION" | jq -r '.RouteTables[] | select(.Associations[]?.Main != true) | .RouteTableId')
  for rtb in $RTBS; do
    info "Deleting Route Table: $rtb"
    aws ec2 delete-route-table --route-table-id "$rtb" --region "$REGION"
  done

  # Delete Subnets
  SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID --region "$REGION" | jq -r '.Subnets[].SubnetId')
  for subnet in $SUBNETS; do
    info "Deleting Subnet: $subnet"
    aws ec2 delete-subnet --subnet-id "$subnet" --region "$REGION"
  done

  # Delete Security Groups (except default)
  SGS=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC_ID --region "$REGION" | jq -r '.SecurityGroups[] | select(.GroupName != "default") | .GroupId')
  for sg in $SGS; do
    info "Deleting Security Group: $sg"
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION"
  done

  # Delete Network Interfaces
  ENIS=$(aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC_ID --region "$REGION" | jq -r '.NetworkInterfaces[].NetworkInterfaceId')
  for eni in $ENIS; do
    ATTACH_ID=$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" --region "$REGION" | jq -r '.NetworkInterfaces[0].Attachment.AttachmentId // empty')
    if [[ -n "$ATTACH_ID" ]]; then
      info "Detaching ENI $eni"
      aws ec2 detach-network-interface --attachment-id "$ATTACH_ID" --force --region "$REGION"
      sleep 2
    fi
    info "Deleting ENI: $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION"
  done

  # Finally, delete VPC
  info "Deleting VPC: $VPC_ID"
  aws ec2 delete-vpc --vpc-id "$VPC_ID" --region "$REGION"
done

info "✅ Cleanup complete."
