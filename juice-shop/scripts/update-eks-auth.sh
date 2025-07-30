#!/bin/bash

# This script updates the aws-auth ConfigMap to grant the CodeBuild role access to the EKS cluster

# Get the CodeBuild role ARN
CODEBUILD_ROLE_ARN=$(aws sts get-caller-identity --query 'Arn' --output text | sed -e 's/:assumed-role/:role/g' | cut -d'/' -f1-2)

echo "Updating aws-auth ConfigMap with role: $CODEBUILD_ROLE_ARN"

# Check if aws-auth ConfigMap exists
if kubectl get configmap aws-auth -n kube-system &> /dev/null; then
  echo "aws-auth ConfigMap exists, updating..."
  
  # Get current ConfigMap
  kubectl get configmap aws-auth -n kube-system -o yaml > aws-auth-current.yaml
  
  # Check if role is already in the ConfigMap
  if grep -q "$CODEBUILD_ROLE_ARN" aws-auth-current.yaml; then
    echo "Role already exists in aws-auth ConfigMap"
  else
    # Add the role to the ConfigMap
    echo "Adding role to aws-auth ConfigMap"
    
    # Extract current mapRoles
    CURRENT_MAP_ROLES=$(kubectl get configmap aws-auth -n kube-system -o jsonpath='{.data.mapRoles}' || echo "")
    
    # Append new role
    NEW_ROLE="- rolearn: $CODEBUILD_ROLE_ARN\n  username: codebuild\n  groups:\n    - system:masters"
    
    if [ -z "$CURRENT_MAP_ROLES" ]; then
      # No existing mapRoles
      NEW_MAP_ROLES="$NEW_ROLE"
    else
      # Append to existing mapRoles
      NEW_MAP_ROLES="$CURRENT_MAP_ROLES\n$NEW_ROLE"
    fi
    
    # Update ConfigMap
    kubectl patch configmap aws-auth -n kube-system --patch "{\"data\":{\"mapRoles\":\"$NEW_MAP_ROLES\"}}"
  fi
else
  echo "aws-auth ConfigMap does not exist, creating..."
  
  # Create ConfigMap from template
  cat > aws-auth.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: $CODEBUILD_ROLE_ARN
      username: codebuild
      groups:
        - system:masters
EOF
  
  kubectl apply -f aws-auth.yaml
fi

echo "aws-auth ConfigMap updated successfully"