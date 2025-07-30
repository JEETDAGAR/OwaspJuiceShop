
# Deploy OWASP-JuiceShop Application on AWS Cloud using AWS Codepipeline on to Amazon EKS - DevSecOps Project!

### **Phase 1: Initial Setup and Prerequisites**

**Step 1: Launch EC2 (Ubuntu 22.04) or latest LTS :**

- Provision an EC2 instance on AWS with Ubuntu 22.04.
- Connect to the instance using SSH.

**Step 2: Install Docker on EC2 instance :**

- Set up Docker on the EC2 instance:
    
    ```bash
    sudo apt-get update
    sudo apt-get install docker.io -y
    sudo usermod -aG docker $USER  # Replace with your system's username, e.g., 'ubuntu'
    newgrp docker
    sudo chmod 777 /var/run/docker.sock
    ```

**Step 3: Create the Amazon EKS cluster:**

- There are several ways to create an Amazon EKS (Elastic Kubernetes Service) cluster, depending on your preferred tools and level of control.
- Follow this link https://docs.aws.amazon.com/eks/latest/userguide/create-cluster.html to create and get started with the cluster with AWS console, make sure while creating the cluster the Authentication mode is EKS API and ConfigMap.

## Step a: Create EKS Cluster with eksclt

Let's create an EKS cluster in the `us-east-1` region using eksctl(Make sure you have eksctl installed in you environment):

```bash
eksctl create cluster --name owasp_cluster \
  --nodegroup-name mcp-worker-nodes \
  --node-type t3.medium \
  --nodes 3 --nodes-min 1 --nodes-max 4 \
  --region us-east-1
```

## Step b: Update the kubeconfing file to point to the cluster and associate the OIDC provider to eks cluster

```bash
aws eks update-kubeconfig --region us-east-1 --name owasp_cluster
```

Associate the OIDC provider to your eks cluster
```bash
eksctl utils associate-iam-oidc-provider --region=us-east-1 --cluster=owasp_cluster --approve
```

## Step c: Add EKS Add-ons

Follow the [AWS documentation](https://docs.aws.amazon.com/eks/latest/userguide/creating-an-add-on.html) to add and update the required add-ons.

Make sure you have VPC CNI, CoreDNS, and KubeProxy add-ons on the cluster and also update those addons to the latest versions

```bash
# Core DNS
eksctl update addon --name coredns --cluster owasp_cluster --region us-east-1 --version latest

# KubeProxy
eksctl update addon --name kube-proxy --cluster owasp_cluster --region us-east-1 --version latest

#VPC CNI
eksctl update addon --name vpc-cni --cluster owasp_cluster --region us-east-1 --version latest

```
> **Note** To update manually you can go to the EKS cluster page and move to Add ons tab in the cluster and update the individual addon to the latest version

![c](/static/eks/4.png)

> **Note** if you don't have the latest versions or compatable versions of addons your load balancer controller installation would fail.

## Step d: Add AWS Load Balancer Controller

### Create IAM Policy
```bash
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam-policy.json
```


### Create IAM Role & Service Account
```bash
eksctl create iamserviceaccount \
  --cluster mcp-servers \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

Replace the `AWS_ACCOUNT_ID` with your aws account id, which you can find in from top right corner of you AWS console.

### Install AWS Load Balancer Controller
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=owasp_cluster \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=<YOUR_VPC_ID>
```
Replace the `vcpId` with actual vpcid where your eks cluster has been deployed you can find it from the Networking tab in the EKS service or in the VPC section

### verify the loadbalancer controller has been properly setup 

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
```
An example output is as follows

```bash
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   2/2     2            2           84s
```



**Step 4: Clone this github repo or fork this repo into your github account and configure your AWS credentials on local machine:**

- Run this command on your local machine to clone the repository
    
    ```bash
    git clone https://github.com/JEETDAGAR/OwaspJuiceShop.git
    ```
    
- Push the repository on to your github account if you have not done so.
- if you have fored the repo directly no need to push to the github

- Install the AWS CLI on your local machine and configure your aws credentials with 
    
    ```bash
    aws configure
    ```


**Step 5: Create the codestar connection for your github repository:**

- To create the codestar connection follow these steps : https://docs.aws.amazon.com/dtconsole/latest/userguide/connections-create-github.html

**Step 6: Store parameters in AWS Systems Manager Parameter Store**

- Run the below commands to store the parameters.

```bash
# Store your AWS account ID
aws ssm put-parameter --name "/juice-shop/aws-account-id" --value "YOUR_AWS_ACCOUNT_ID" --type "String"
# Store your EKS cluster name
aws ssm put-parameter --name "/juice-shop/eks-cluster-name" --value "YOUR_EKS_CLUSTER_NAME" --type "String"
# Store your AWS Region 
aws ssm put-parameter --name "/juice-shop/aws-default-region" --value "YOUR_AWS_REGION" --type "String"
```

**Phase 2: Security**

1. **Install SonarQube on EC2 instance :**
    - Install SonarQube and Trivy on the EC2 instance to scan for vulnerabilities.
        
        sonarqube
        ```
        docker run -d --name sonar -p 9000:9000 sonarqube:lts-community
        ```
        
        
        To access: 
        
        publicIP:9000 (by default username & password is admin)
        
        To install Trivy:
        ```
        sudo apt-get install wget apt-transport-https gnupg lsb-release
        wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
        echo deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main | sudo tee -a /etc/apt/sources.list.d/trivy.list
        sudo apt-get update
        sudo apt-get install trivy        
        ```
        
        to scan image using trivy
        ```
        trivy image <imageid>
        ```

2. **Integrate SonarQube and Configure:**
    - Integrate SonarQube with your CI/CD pipeline.
    - Configure SonarQube to analyze code for quality and security issues.
    - Create the project in the sonarqube and note down the Projectkey, HostURL(Which is PUBLIC_IP:9000)
3. **Store parameters in AWS Systems Manager Parameter Store**

- Run the below commands to store the parameters of SonarQube.

```bash
# Store your HOST_URL
aws ssm put-parameter --name "/sonarcloud/host" --value "YOUR_HOST_URL" --type "String"
# Store your PROJECT_KEY
aws ssm put-parameter --name "/sonarcloud/project" --value "YOUR_PROJECT_KEY" --type "String"
# Store your SONAR_TOKEN
aws ssm put-parameter --name "/sonarcloud/token" --value "YOUR_SONAR_TOKEN" --type "String"
```
**Phase 3: CI/CD Setup**

- Run the codepipeline cloudformation template in your project with filename (codepipeline-template.yaml)
- This template would create the codepipeline with two codebuild project 1.Security stage 2.Build and Deploy stage.
- In security stage the code is checked for the vulnerabilities with the sonarcube , trivy for image scan and AWS inspector for image and souce code scan. and the results are then stored into s3
- In build and deploy stage the docker image is created and is pushed into the ECR repository that is created after running the codepipeline cfn template.

```bash
aws cloudformation create-stack \
  --stack-name netflix-cicd-pipeline \
  --template-body /path to your template/codepipeline-template.yaml \
  --parameters \
    ParameterKey=GitHubOwner,ParameterValue=YOUR_GITHUB_USERNAME \
    ParameterKey=GitHubBranchr,ParameterValue=YOUR_GITHUB_BRANCH \
    ParameterKey=GitHubRepo,ParameterValue=YOUR_GITHUB_REPO \
    ParameterKey=ExistingCodeStarConnectionArn,ParameterValue=YOUR_CODESTAR_CONNECTION_ARN \
    ParameterKey=EksClusterName,ParameterValue=YOUR_EKS_CLUSTER_NAME \
    ParameterKey=EcrRepositoryName, ParameterValue=YOUR_ECR_REPO_NAME \
  --capabilities CAPABILITY_IAM
```
