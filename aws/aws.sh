awsAccount="555555555555"
eksclusterName="myekscluster1"
regionCode="us-east-2"
tags="Owner=mipapase,Department=IT"
ampAlias="myAwsManagedPrometheusAlias"
awsManagedGrafanaWorkspaceName="myAwsManagedGrafanaWorkspaceName"

# Prerequesites: 
# - CLI and necessary tools are installed.
# - A virtual network and subnets exists (e.g., default VPC)

#  Need to provide the subnets to create the cluster - not counted
subnetIds=$(aws ec2 describe-subnets --query 'Subnets[*].SubnetId' --output text)
echo $subnetIds

#####################  Creating the managed K8S cluster ()  #####################

# Create EKS cluster using eksctl - 840.2687s, 1 command, 11 parameters
eksctl create cluster \
    --name $eksclusterName \
    --tags $tags \
    --region $regionCode \
    --with-oidc \
    --version 1.26 \
    --vpc-public-subnets subnet-0e59a43676579bb67,subnet-08990971a46c01534,subnet-0b11c218a97a43909 \
    --node-type t3.large \
    --nodes-min 6 \
    --auto-kubeconfig \
    --asg-access \
    --nodes-max 6 | gnomon 

# check OIDC provider - not counted
oidc_id=$(aws eks describe-cluster --name $eksclusterName --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)
echo $oidc_id

# Determine if an IAM OIDC provider with your cluster's OIDC provider URL exists - not counted
aws iam list-open-id-connect-providers | grep $oidc_id | cut -d "/" -f4

# update kubeconfig - 2.5935s, 1 command, 2 parameters
# aws eks update-kubeconfig --region $regionCode --name $eksclusterName
aws eks update-kubeconfig --region $regionCode --name $eksclusterName | gnomon

# EBS CSI driver:  https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html

# Create an IAM policy that allows the CSI driver's service account to make calls to AWS APIs on your behalf.
# grab example (if you don't have one already) - 0.0123s, 1 command, 2 parameters
curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json | gnomon

# create the IAM policy - 2.3181s, 1 command, 2 parameters
aws iam create-policy \
    --policy-name AmazonEKS_EBS_CSI_Driver_Policy \
    --policy-document file://example-iam-policy.json | gnomon

# Create the IAM role and K8S service account - 34.1053s, 1 command, 7 parameters
eksctl create iamserviceaccount \
    --name ebs-csi-controller-sa \
    --namespace kube-system \
    --cluster $eksclusterName \
    --role-name AmazonEKS_EBS_CSI_DriverRole \
    --attach-policy-arn arn:aws:iam::$awsAccount:policy/AmazonEKS_EBS_CSI_Driver_Policy \
    --approve \
    --region $regionCode | gnomon 

# add the EBS CSI driver to the cluster - 2.4860s, 1 command, 4 parameters
eksctl create addon \
    --name aws-ebs-csi-driver \
    --cluster $eksclusterName \
    --service-account-role-arn arn:aws:iam::$awsAccount:role/AmazonEKS_EBS_CSI_DriverRole \
    --force | gnomon 

# to verify that the aws-ebs-csi-driver is running - not counted
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver | gnomon

#####################  Configure cluster logging ()  #####################

# Enable control plane logging - 71.1224s, 1 command, 4 parameters
eksctl utils update-cluster-logging \
  --enable-types api,scheduler,controllerManager \
  --region $regionCode \
  --cluster $eksclusterName \
  --approve | gnomon 

# Find the ClusterNodeGroupRoleName that eksctl created previously - 2.4802s, 1 command, 1 parameters
aws iam list-roles --query "Roles[?contains(RoleName, 'eksctl-$eksclusterName-nodegroup')].RoleName | [0]" | tr -d '"' | gnomon
clusterNodeGroupRoleName=$(aws iam list-roles --query "Roles[?contains(RoleName, 'eksctl-$eksclusterName-nodegroup')].RoleName | [0]" | tr -d '"')
echo $clusterNodeGroupRoleName

# Attach the CloudWatchAgentServerPolicy policy to the node group role created by eksctl when creating the cluster - 2.3062s, 1 command, 2 parameters
aws iam attach-role-policy \
  --role-name $clusterNodeGroupRoleName \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy | gnomon

# Follow the directions from the Quick Start setup for Container Insights
#   https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Container-Insights-setup-EKS-quickstart.html

# set up fluentbit for AWS container insights - 8.7861s, 3 commands, 2 parameters
ClusterName=$eksclusterName
RegionName=$regionCode
FluentBitHttpPort='2020'
FluentBitReadFromHead='Off'
[[ ${FluentBitReadFromHead} = 'On' ]] && FluentBitReadFromTail='Off'|| FluentBitReadFromTail='On'
[[ -z ${FluentBitHttpPort} ]] && FluentBitHttpServer='Off' || FluentBitHttpServer='On'
curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluent-bit-quickstart.yaml | sed 's/{{cluster_name}}/'${ClusterName}'/;s/{{region_name}}/'${RegionName}'/;s/{{http_server_toggle}}/"'${FluentBitHttpServer}'"/;s/{{http_server_port}}/"'${FluentBitHttpPort}'"/;s/{{read_from_head}}/"'${FluentBitReadFromHead}'"/;s/{{read_from_tail}}/"'${FluentBitReadFromTail}'"/' | kubectl apply -f - | gnomon


# Check CloudWatch Log groups. There should be 5. - not counted
aws logs describe-log-groups --log-group-name-pattern $eksclusterName --output json | jq '.logGroups | length' | gnomon

#####################  Configure metrics (managed prometheus) ()  #####################

# create the AMP workspace - 2.7255s, 1 commands, 2 parameters
aws amp create-workspace --alias $ampAlias --tags $tags | gnomon

# install certificate manager - 13.3777s, 1 commands, 1 parameters
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.8.2/cert-manager.yaml | gnomon

# grant permissions to EKS add-ons to install ADOT - 5.2656s, 1 commands, 1 parameters
kubectl apply -f https://amazon-eks.s3.amazonaws.com/docs/addons-otel-permissions.yaml | gnomon

# install ADOT add-on - 2.4988s, 1 commands, 3 parameters
aws eks create-addon --addon-name adot --addon-version v0.78.0-eksbuild.1 --cluster-name $eksclusterName | gnomon                                                      

# verify add-on - not counted
aws eks describe-addon --addon-name adot --cluster-name $eksclusterName --output json | jq .addon.status | gnomon

# setup IAM role for service account for ADOT collector - 32.0877s, 1 commands, 8 parameters
eksctl create iamserviceaccount \
    --name adot-collector \
    --namespace default \
    --cluster $eksclusterName \
    --attach-policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess \
    --attach-policy-arn arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess \
    --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
    --approve \
    --override-existing-serviceaccounts | gnomon

# get AMP workspace id - 1.8703s, 2 commands, 4 parameters
aws amp list-workspaces --alias $ampAlias --output json | jq .workspaces[0].workspaceId -r | gnomon
WORKSPACE_ID=$(aws amp list-workspaces --alias $ampAlias --output json | jq .workspaces[0].workspaceId -r)
echo $WORKSPACE_ID

# get AMP workspace endpoint - 1.9367s, 2 commands, 4 parameters
aws amp describe-workspace --workspace-id $WORKSPACE_ID --output json | jq .workspace.prometheusEndpoint -r | gnomon
AMP_ENDPOINT_URL=$(aws amp describe-workspace --workspace-id $WORKSPACE_ID --output json | jq .workspace.prometheusEndpoint -r)
echo $AMP_ENDPOINT_URL

# set the AMP remote write URL -- not counted
AMP_REMOTE_WRITE_URL=${AMP_ENDPOINT_URL}api/v1/remote_write
echo $AMP_REMOTE_WRITE_URL

# uncomment the following only if you want to download a new file, otherwise use the one in the aws directory - 0.0062s, 1 command, 2 parameter
curl -O https://raw.githubusercontent.com/aws-observability/aws-otel-community/master/sample-configs/operator/collector-config-amp.yaml | gnomon

# replace the region placeholder in the file - 0.0064s, 1 command, 2 parameters
sed -i -e s/\<YOUR_AWS_REGION\>/$regionCode/g collector-config-amp.yaml | gnomon

# replace the remote write endpoint placeholder in the file - 0.0056s, 1 command, 2 parameters
sed -i -e s^\<YOUR_REMOTE_WRITE_ENDPOINT\>^$AMP_REMOTE_WRITE_URL^g collector-config-amp.yaml | gnomon

# apply the configuration - 2.8568s, 1 command, 1 parameters
kubectl apply -f ./collector-config-amp.yaml | gnomon

# check to see that metrics are being collected into AMP - not counted
#   pip3 install awscurl
AMP_QUERY_ENDPOINT_URL=${AMP_ENDPOINT_URL}api/v1/query
echo $AMP_QUERY_ENDPOINT_URL

# call prometheus query endpoint - not counted
awscurl -X POST --region $regionCode --service aps "$AMP_QUERY_ENDPOINT_URL?query=up" | gnomon

#####################  Configure traces (otel) ()  #####################

# install the OTel collector CRD for xray traces - my-collector-xray
# Make sure to set the OTEL_EXPORTER_OTLP_ENDPOINT to the correct value when configuration the application:
#   e.g.  'http://my-collector-xray-collector.default.svc.cluster.local:4317'
# uncomment the following only if you want to download a new file, otherwise use the one in the aws directory

# download the file - 0.0055s, 1 command, 2 parameters
curl -O https://raw.githubusercontent.com/aws-observability/aws-otel-community/master/sample-configs/operator/collector-config-xray.yaml | gnomon

# replace the region placeholder in the file - 0.0056s, 1 command, 2 parameters
sed -i -e s/\<YOUR_AWS_REGION\>/$regionCode/g collector-config-xray.yaml | gnomon

# apply the configuration - 2.0106s, 1 command, 1 parameters
kubectl apply -f ./collector-config-xray.yaml | gnomon

# verify the OTel collectors are running - not counted
kubectl get all

#####################  Configure Grafana ()  #####################

# create AWS Managed Grafana workspace

# NOTE: The ability for Amazon Managed Grafana to create and update IAM roles on behalf of the user is 
# supported only in the Amazon Managed Grafana console, where the permission-type value may be set to SERVICE_MANAGED.
GRAFANA_ROLE_NAME=AmazonManagedGrafana-Role

# create trust policy - 2.0584s, 2 commands, 5 parameters
aws iam create-role --role-name $GRAFANA_ROLE_NAME --assume-role-policy-document file://grafana-trust-policy.json --output json | jq .Role.Arn -r | gnomon
# GRAFANA_ROLE_ARN=$(aws iam create-role --role-name $GRAFANA_ROLE_NAME --assume-role-policy-document file://grafana-trust-policy.json --output json | jq .Role.Arn -r)
GRAFANA_ROLE_ARN=arn:aws:iam::886674496073:role/AmazonManagedGrafana-Role
echo $GRAFANA_ROLE_ARN

# create prometheus policy for Grafana - 2.0461s, 2 commands, 5 parameters
aws iam create-policy --policy-name AmazonGrafanaPrometheusPolicy-custom --policy-document file://AmazonGrafanaPrometheusPolicy-custom.json --output json | jq .Policy.Arn -r | gnomon
# Grafana_Prometheus_Policy_arn=$(aws iam create-policy --policy-name AmazonGrafanaPrometheusPolicy-custom --policy-document file://AmazonGrafanaPrometheusPolicy-custom.json | jq .Policy.Arn -r)
Grafana_Prometheus_Policy_arn=arn:aws:iam::886674496073:policy/AmazonGrafanaPrometheusPolicy-custom
echo $Grafana_Prometheus_Policy_arn

# create SNS policy for Grafana - 2.1533s, 2 commands, 5 parameters
aws iam create-policy --policy-name AmazonGrafanaSNSPolicy-custom --policy-document file://AmazonGrafanaSNSPolicy-custom.json --output json | jq .Policy.Arn -r | gnomon
# Grafana_SNS_Policy_arn=$(aws iam create-policy --policy-name AmazonGrafanaSNSPolicy-custom --policy-document file://AmazonGrafanaSNSPolicy-custom.json --output json | jq .Policy.Arn -r)
Grafana_SNS_Policy_arn=arn:aws:iam::886674496073:policy/AmazonGrafanaSNSPolicy-custom
echo $Grafana_SNS_Policy_arn

# attach cloudwatch access policy to the grafana role - 2.1161s, 1 command, 2 parameters
aws iam attach-role-policy \
    --role-name $GRAFANA_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonGrafanaCloudWatchAccess | gnomon

# attach xray access policy to the grafana role - 1.9318s, 1 command, 2 parameters
aws iam attach-role-policy \
    --role-name $GRAFANA_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AWSXrayReadOnlyAccess | gnomon

# attach prometheus policy to the grafana role - 2.0461s, 1 command, 2 parameters
aws iam attach-role-policy \
    --role-name $GRAFANA_ROLE_NAME \
    --policy-arn $Grafana_Prometheus_Policy_arn | gnomon

# attach SNS policy to the grafana role - 2.1113s, 1 command, 2 parameters
aws iam attach-role-policy \
    --role-name $GRAFANA_ROLE_NAME \
    --policy-arn $Grafana_SNS_Policy_arn | gnomon

# create the AWS Managed Grafana workspace - 2.5062s, 1 command, 7 parameters
aws grafana create-workspace \
  --workspace-name $awsManagedGrafanaWorkspaceName \
  --account-access-type CURRENT_ACCOUNT \
  --authentication-providers AWS_SSO \
  --permission-type CUSTOMER_MANAGED \
  --workspace-role-arn $GRAFANA_ROLE_ARN \
  --query 'workspace.id' \
  --output text | gnomon

# get the workspace id - 1.8703s, 1 commands, 2 parameters
aws grafana list-workspaces --query 'workspaces[?name==`'$awsManagedGrafanaWorkspaceName'`].id' --output text | gnomon
Grafana_Workspace_Id=$(aws grafana list-workspaces --query 'workspaces[?name==`'$awsManagedGrafanaWorkspaceName'`].id' --output text)
echo $Grafana_Workspace_Id

# Add users to the grafana workspace
# Refer to: https://docs.aws.amazon.com/grafana/latest/userguide/AMG-manage-users-and-groups-AMG.html

# add my user id to ADMIN role in the Grafana workspace - 2.9831s, 1 command, 2 parameters
aws grafana update-permissions \
  --workspace-id $Grafana_Workspace_Id \
  --update-instruction-batch "action=ADD,role=ADMIN,users=[{id=9a672d4e17-22f11247-c68d-48f2-8cac-a2ca250c7e94,type=SSO_USER}]" | gnomon

# verify the permissions - not counted
aws grafana list-permissions --workspace-id $Grafana_Workspace_Id --output json | gnomon

