#!/bin/bash
set -e

# This script creates a simple aws-auth ConfigMap for EKS cluster access

# Get the CodeBuild role ARN
CODEBUILD_ROLE_ARN=$(aws sts get-caller-identity --query 'Arn' --output text)
echo "Current role ARN: $CODEBUILD_ROLE_ARN"

# Extract the base role ARN (convert assumed-role to role format)
if [[ $CODEBUILD_ROLE_ARN == *"assumed-role"* ]]; then
  # For assumed roles
  BASE_ROLE_ARN=$(echo $CODEBUILD_ROLE_ARN | sed -E 's|^arn:aws:sts::(.*):assumed-role/(.*)/.*$|arn:aws:iam::\1:role/\2|')
  # Also keep the original assumed role ARN
  ASSUMED_ROLE_ARN=$CODEBUILD_ROLE_ARN
else
  # For direct IAM roles
  BASE_ROLE_ARN=$CODEBUILD_ROLE_ARN
  ASSUMED_ROLE_ARN=""
fi

echo "Base role ARN for aws-auth: $BASE_ROLE_ARN"

# Check if aws-auth ConfigMap exists
if kubectl get configmap aws-auth -n kube-system &>/dev/null; then
  echo "aws-auth ConfigMap exists, updating it..."
  # Get existing ConfigMap
  kubectl get configmap aws-auth -n kube-system -o yaml > existing-aws-auth.yaml
  
  # Check if role is already in the ConfigMap
  if grep -q "$BASE_ROLE_ARN" existing-aws-auth.yaml; then
    echo "Role $BASE_ROLE_ARN already exists in aws-auth ConfigMap"
  else
    echo "Adding role $BASE_ROLE_ARN to aws-auth ConfigMap"
    # Extract current mapRoles content
    CURRENT_MAP_ROLES=$(kubectl get configmap aws-auth -n kube-system -o jsonpath='{.data.mapRoles}' || echo "")
    
    # Append new role mapping for base role
    NEW_ROLE="    - rolearn: $BASE_ROLE_ARN\n      username: codebuild\n      groups:\n        - system:masters"
    
    # Also add the assumed role if it exists and is different
    if [[ -n "$ASSUMED_ROLE_ARN" && "$ASSUMED_ROLE_ARN" != "$BASE_ROLE_ARN" ]]; then
      ASSUMED_ROLE="    - rolearn: $ASSUMED_ROLE_ARN\n      username: codebuild\n      groups:\n        - system:masters"
      NEW_ROLE="$NEW_ROLE\n$ASSUMED_ROLE"
    fi
    
    if [ -z "$CURRENT_MAP_ROLES" ]; then
      # If mapRoles is empty, create new content
      NEW_MAP_ROLES="$NEW_ROLE"
    else
      # Append to existing content
      NEW_MAP_ROLES="$CURRENT_MAP_ROLES\n$NEW_ROLE"
    fi
    
    # Update ConfigMap
    kubectl patch configmap aws-auth -n kube-system --type merge -p "{\"data\":{\"mapRoles\":\"$NEW_MAP_ROLES\"}}"
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

  # If we have an assumed role ARN that's different from the base role, add it too
  if [[ -n "$ASSUMED_ROLE_ARN" && "$ASSUMED_ROLE_ARN" != "$BASE_ROLE_ARN" ]]; then
    # Add the assumed role ARN to the ConfigMap
    sed -i '/mapRoles: |/a\    - rolearn: '"$ASSUMED_ROLE_ARN"'\n      username: codebuild\n      groups:\n        - system:masters' aws-auth.yaml
  fi

  echo "Created aws-auth.yaml with the following content:"
  cat aws-auth.yaml

  # Apply the ConfigMap
  kubectl apply -f aws-auth.yaml
fi

# Wait for the auth changes to propagate
echo "Waiting for auth changes to propagate..."
sleep 10

# Verify access
echo "Verifying EKS access..."
kubectl auth can-i get namespaces --all-namespaces || echo "Warning: Permission check failed, but continuing..."

# Display the current aws-auth ConfigMap for debugging
echo "Current aws-auth ConfigMap:"
kubectl get configmap aws-auth -n kube-system -o yaml || echo "Could not retrieve aws-auth ConfigMap"

# Try to list namespaces as a final test
echo "Attempting to list namespaces:"
kubectl get namespaces || echo "Warning: Could not list namespaces, but continuing..."

echo "aws-auth ConfigMap setup completed"