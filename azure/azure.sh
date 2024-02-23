resourceGroup="myresurcegroup1"
location="eastus"
aksClusterName="myakscluster1"
logAnalyticsWorkspaceName="myloganalyticsworkspace1"
azureMonitorWorkspaceName="myazuremonitorworkspace1"
azureManagedGrafanaWorkspaceName="mygrafanaws1"
storageAccountName="mystorageaccount1"
tags="Owner=mipapase Department=IT"
appInsightsAppName="myappinsightsapp1"

# Prerequesites: 
# - CLI and necessary tools are installed.

# create resource group - not counted
az group create --name $resourceGroup --location $location --tags $tags --query id -o tsv | gnomon
resourceGroupId=$(az group show --name $resourceGroup --query id -o tsv)
echo $resourceGroupId

#####################  Creating the managed K8S cluster (1m 26.3481s)  #####################
# create AKS cluster - 285.1305s, 1 commands, 11 parameters
az aks create \
  --resource-group $resourceGroup \
  --name $aksClusterName \
  --generate-ssh-keys \
  --enable-cluster-autoscaler \
  --enable-managed-identity \
  --max-count 4 \
  --min-count 1 \
  --node-vm-size Standard_D2s_v3 \
  --tier standard \
  --os-sku Ubuntu \
  --tags $tags | gnomon

# get credentials for the cluster - 2.7405s, 1 commands, 2 parameters
az aks get-credentials --name $aksClusterName --resource-group $resourceGroup | gnomon

#####################  Configure cluster logging (1m 26.3481s)  #####################
# create log analytics workspace - 6.4912s, 1 commands, 6 parameters
# requires RP to be registered: 'Microsoft.OperationalInsights'
az monitor log-analytics workspace create \
  --resource-group $resourceGroup \
  --location $location \
  --workspace-name $logAnalyticsWorkspaceName \
  --tags $tags \
  --query id -o tsv | gnomon
logAnalyticsWorkspaceResourceId=$(az monitor log-analytics workspace show --resource-group $resourceGroup --workspace-name $logAnalyticsWorkspaceName --query id -o tsv)
echo $logAnalyticsWorkspaceResourceId

# Enable Container Insights - 2 minutes 44 seconds, 1 commands, 4 parameters
az aks enable-addons \
  --resource-group $resourceGroup \
  --name $aksClusterName \
  --addons monitoring \
  --workspace-resource-id $logAnalyticsWorkspaceResourceId | gnomon

# Get AKS cluster resource id for use in diagnostic settings - not counted
aksClusterId=$(az aks show --resource-group $resourceGroup --name $aksClusterName --query id -o tsv)
echo $aksClusterId

# Add diagnostic setting to AKS cluster to send control plane logs to Log Analytics workspace - 3.7877s, 1 commands, 4 parameters
az monitor diagnostic-settings create \
    --name AKS-Diagnostics \
    --resource $aksClusterId \
    --logs '[{"category": "kube-apiserver", "enabled": true}, {"category": "kube-controller-manager", "enabled": true}, {"category": "kube-scheduler", "enabled": true}, {"category": "cloud-controller-manager", "enabled": true}]' \
    --workspace $logAnalyticsWorkspaceResourceId | gnomon


#####################  Configure metrics (managed prometheus) #####################
# create Azure Monitor workspace - 11.5193s, 1 commands, 6 parameters
# requires RP to be registered: 'Microsoft.Monitor'
az monitor account create \
  --name $azureMonitorWorkspaceName \
  --resource-group $resourceGroup \
  --location $location \
  --tags $tags \
  --query id -o tsv | gnomon
azureMonitorWorkspaceResourceId=$(az monitor account show --name $azureMonitorWorkspaceName -g $resourceGroup --query id -o tsv)
echo $azureMonitorWorkspaceResourceId

#####################  Configure traces (otel) #####################
# create Application Insights resource and grab Connection String for ConfigMap - 2.7976s, 1 commands, 9 parameters
az monitor app-insights component create \
  --app $appInsightsAppName \
  --location $location \
  --kind web \
  --resource-group $resourceGroup \
  --application-type web \
  --workspace $logAnalyticsWorkspaceName \
  --tags $tags --query connectionString -o tsv | gnomon

appInsightsConnectionString=$(az monitor app-insights component show --app $appInsightsAppName -g $resourceGroup --query connectionString -o tsv)
echo $appInsightsConnectionString

#####################  Configure Grafana  #####################
# create Azure Managed Grafana workspace - 197.0025s, 1 commands, 6 parameters
#  Refer to: https://github.com/Azure/azure-cli/issues/26630 for possible issue if the amg CLI extension is not installed.
az grafana create \
  --name $azureManagedGrafanaWorkspaceName \
  --resource-group $resourceGroup \
  --location $location \
  --tags $tags \
  --query id -o tsv | gnomon
azureManagedGrafanaResourceId=$(az grafana show --name $azureManagedGrafanaWorkspaceName --resource-group $resourceGroup --query id -o tsv)
echo $azureManagedGrafanaResourceId

# Configure Prometheus agents on cluster and link prometheus and Grafana to container insights - 3 minutes, 1 commands, 5 parameters
az aks update \
  --enable-azure-monitor-metrics \
  -n $aksClusterName \
  -g $resourceGroup \
  --azure-monitor-workspace-resource-id $azureMonitorWorkspaceResourceId \
  --grafana-resource-id $azureManagedGrafanaResourceId | gnomon

# Verify deployment of Prometheus metrics collection on AKS

# There should be ama-metrics-node pod(s) for the DaemonSet deployed - one for each node - not counted
kubectl get ds ama-metrics-node --namespace=kube-system

# There should be two ama-metrics-* ReplicaSets - not counted
kubectl get rs --namespace=kube-system

# Create ConfigMap to be used by ReplicaSet for Prometheus metrics collection
# Use file from GitHub Repo:Citizerve-NodeJS\k8s\azure\prometheus-config
# Every Azure Monitor metrics Windows DaemonSet pod restarts in 30-60 secs to apply the new config.

# download the prometheus-config file from GitHub - 0.0046s, 1 commands, 2 parameters
curl -O https://raw.githubusercontent.com/dushyantgill/Citizerve-NodeJS/main/k8s/azure/prometheus-config | gnomon

# Create ConfigMap to be used by ReplicaSet for Prometheus metrics collection - 0.0304s, 1 commands, 2 parameters
kubectl create configmap ama-metrics-prometheus-config --from-file=prometheus-config -n kube-system | gnomon

# Verify the ConfigMap is created - not counted
kubectl get configmap ama-metrics-prometheus-config --namespace=kube-system
