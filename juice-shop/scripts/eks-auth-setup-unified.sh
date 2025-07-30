#!/bin/bash
set -e

# This script sets up EKS authentication using both API and ConfigMap methods
# to ensure maximum compatibility and reliability

# Get the CodeBuild role ARN
CODEBUILD_ROLE_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
echo "Current role ARN: $CODEBUILD_ROLE_ARN"

# Extract the base role ARN (convert assumed-role to role format)
if [[ $CODEBUILD_ROLE_ARN == *"assumed-role"* ]]; then
  # For assumed roles
  BASE_ROLE_ARN=$(echo $CODEBUILD_ROLE_ARN | sed -E 's|^arn:aws:sts::(.*):assumed-role/(.*)/.*$|arn:aws:iam::\1:role/\2|')
  ASSUMED_ROLE_ARN=$CODEBUILD_ROLE_ARN
else
  # For direct IAM roles
  BASE_ROLE_ARN=$CODEBUILD_ROLE_ARN
  ASSUMED_ROLE_ARN=""
fi

echo "Base role ARN for auth: $BASE_ROLE_ARN"

# Get the EKS cluster name from environment variable or use default
CLUSTER_NAME=${EKS_CLUSTER_NAME:-netflix}
REGION=${AWS_DEFAULT_REGION:-us-west-1}

echo "Using cluster: $CLUSTER_NAME in region: $REGION"

# PART 1: Set up API-based authentication
echo "Setting up API-based authentication..."

# Enable API_AND_CONFIG_MAP authentication mode
# echo "Enabling API_AND_CONFIG_MAP authentication mode..."
# aws eks update-cluster-config \
#   --name $CLUSTER_NAME \
#   --region $REGION \
#   --access-config authenticationMode=API_AND_CONFIG_MAP || echo "Failed to update cluster config, continuing..."

# Create access entry for the base role
echo "Creating access entry for base role..."
aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --region $REGION \
  --principal-arn $BASE_ROLE_ARN

aws eks associate-access-policy \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $BASE_ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
echo "Access entry for base role created."

# If we have an assumed role, create an access entry for it too
# if [[ -n "$ASSUMED_ROLE_ARN" && "$ASSUMED_ROLE_ARN" != "$BASE_ROLE_ARN" ]]; then
#   echo "Creating access entry for assumed role..."
#   aws eks create-access-entry \
#     --cluster-name $CLUSTER_NAME \
#     --region $REGION \
#     --principal-arn $ASSUMED_ROLE_ARN
  
#   aws eks associate-access-policy \
#     --cluster-name $CLUSTER_NAME \
#     --principal-arn $ASSUMED_ROLE_ARN \
#     --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
#     --access-scope type=cluster
#   echo "Access entry for assumed role created."
# fi

sleep 60
echo "60 sec sleep to allow for API changes to propagate..."
# PART 2: Set up ConfigMap-based authentication
echo "Setting up ConfigMap-based authentication..."

# Check if aws-auth ConfigMap exists
if kubectl get configmap aws-auth -n kube-system &>/dev/null; then
  echo "aws-auth ConfigMap exists, updating it..."
  
  # Check if roles are already in the ConfigMap
  kubectl get configmap aws-auth -n kube-system -o yaml > existing-aws-auth.yaml
  
  # Extract current mapRoles content
  CURRENT_MAP_ROLES=$(kubectl get configmap aws-auth -n kube-system -o jsonpath='{.data.mapRoles}' || echo "")
  
  # Prepare new role entries
  NEW_ROLES=""
  
  # Add base role if not already present
  if ! grep -q "$BASE_ROLE_ARN" existing-aws-auth.yaml; then
    NEW_ROLES="    - rolearn: $BASE_ROLE_ARN\n      username: codebuild\n      groups:\n        - system:masters"
  fi
  
  # Add assumed role if not already present and different from base role
  if [[ -n "$ASSUMED_ROLE_ARN" && "$ASSUMED_ROLE_ARN" != "$BASE_ROLE_ARN" ]] && ! grep -q "$ASSUMED_ROLE_ARN" existing-aws-auth.yaml; then
    if [[ -n "$NEW_ROLES" ]]; then
      NEW_ROLES="$NEW_ROLES\n    - rolearn: $ASSUMED_ROLE_ARN\n      username: codebuild\n      groups:\n        - system:masters"
    else
      NEW_ROLES="    - rolearn: $ASSUMED_ROLE_ARN\n      username: codebuild\n      groups:\n        - system:masters"
    fi
  fi
  
  # Update ConfigMap if we have new roles to add
  if [[ -n "$NEW_ROLES" ]]; then
    if [[ -z "$CURRENT_MAP_ROLES" ]]; then
      # No existing mapRoles
      NEW_MAP_ROLES="$NEW_ROLES"
    else
      # Append to existing mapRoles
      NEW_MAP_ROLES="$CURRENT_MAP_ROLES\n$NEW_ROLES"
    fi
    
    echo "Updating aws-auth ConfigMap with new roles..."
    kubectl patch configmap aws-auth -n kube-system --type merge -p "{\"data\":{\"mapRoles\":\"$NEW_MAP_ROLES\"}}"
  else
    echo "No new roles to add to aws-auth ConfigMap"
  fi
else
  echo "aws-auth ConfigMap does not exist, creating it..."
  
  # Create a new aws-auth ConfigMap
  cat > aws-auth.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $BASE_ROLE_ARN
      username: codebuild
      groups:
        - system:masters
EOF

  # Add assumed role if different from base role
  if [[ -n "$ASSUMED_ROLE_ARN" && "$ASSUMED_ROLE_ARN" != "$BASE_ROLE_ARN" ]]; then
    sed -i '/mapRoles: |/a\    - rolearn: '"$ASSUMED_ROLE_ARN"'\n      username: codebuild\n      groups:\n        - system:masters' aws-auth.yaml
  fi

  echo "Created aws-auth.yaml with the following content:"
  cat aws-auth.yaml

  # Apply the ConfigMap
  kubectl apply -f aws-auth.yaml
fi

# Wait for the auth changes to propagate
echo "Waiting for authentication changes to propagate..."
sleep 30

# Verify access
echo "Verifying EKS access..."
kubectl auth can-i get namespaces --all-namespaces || echo "Warning: Permission check failed, but continuing..."

# Display the current aws-auth ConfigMap for debugging
echo "Current aws-auth ConfigMap:"
kubectl get configmap aws-auth -n kube-system -o yaml || echo "Could not retrieve aws-auth ConfigMap"

# Try to list namespaces as a final test
echo "Attempting to list namespaces:"
kubectl get namespaces || echo "Warning: Could not list namespaces, but continuing..."

echo "EKS authentication setup completed using both API and ConfigMap methods"

