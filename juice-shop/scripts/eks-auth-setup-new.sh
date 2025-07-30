#!/bin/bash

# This script uses AWS CLI to update EKS cluster authentication
# instead of directly modifying the aws-auth ConfigMap

# Get the CodeBuild role ARN
CODEBUILD_ROLE_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
echo "Current role ARN: $CODEBUILD_ROLE_ARN"

# Extract the base role ARN (convert assumed-role to role format)
BASE_ROLE_ARN=$(echo $CODEBUILD_ROLE_ARN | sed -E 's|^arn:aws:sts::(.*):assumed-role/(.*)/.*$|arn:aws:iam::\1:role/\2|')
echo "Base role ARN for aws-auth: $BASE_ROLE_ARN"

# Get the EKS cluster name from environment variable or use default
CLUSTER_NAME=${EKS_CLUSTER_NAME:-netflix}
REGION=${AWS_DEFAULT_REGION:-us-west-1}

echo "Using cluster: $CLUSTER_NAME in region: $REGION"

# Use AWS CLI to associate the IAM role with the cluster
echo "Using AWS CLI to associate IAM role with cluster..."

# Create a temporary JSON file for the access entry
cat > /tmp/access-entry.json << EOF
{
  "principalArn": "$BASE_ROLE_ARN",
  "accessPolicies": [
    {
      "policyArn": "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    }
  ]
}
EOF

echo "Created access entry configuration:"
cat /tmp/access-entry.json

# Create access entry for the base role
echo "Creating access entry for base role..."
aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --principal-arn $BASE_ROLE_ARN \
  --access-policies '[{"policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"}]' || echo "Failed to create access entry for base role, continuing..."

# If we have an assumed role, create an access entry for it too
if [[ $CODEBUILD_ROLE_ARN != $BASE_ROLE_ARN ]]; then
  echo "Creating access entry for assumed role..."
  aws eks create-access-entry \
    --cluster-name $CLUSTER_NAME \
    --region $REGION \
    --principal-arn $CODEBUILD_ROLE_ARN \
    --access-policies '[{"policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"}]' || echo "Failed to create access entry for assumed role, continuing..."
fi

# Wait for the changes to propagate
echo "Waiting for access changes to propagate..."
sleep 30

# Verify access
echo "Verifying EKS access..."
kubectl auth can-i get namespaces --all-namespaces || echo "Warning: Permission check failed"

echo "Attempting to list namespaces:"
kubectl get namespaces || echo "Warning: Could not list namespaces"

echo "EKS authentication setup completed"