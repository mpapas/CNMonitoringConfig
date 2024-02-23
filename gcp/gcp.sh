projectId="myprojectid1"
gkecluster="mygkecluster1"
region="us-east1"
zone="us-east1-b"
labels="owner=user1,department=it"
network="mynetwork"
subnet="mysubnet1-us-east1"

# Prerequesites: 
# - CLI and necessary tools are installed.
# - A virtual network and subnets exists in the project. For NAT configuration, see
#   here as an example: https://cloud.google.com/nat/docs/gke-example

#####################  Creating the managed K8S cluster ()  #####################

# Enable APIs - 2.9343s, 1 command, 1 parameters
gcloud services enable container.googleapis.com | gnomon

# Create private cluster spanning one zone - 432.8578s, 1 command, 35 parameters
# Be sure to update firewall rules in the network to allow traffic to and from the cluster
# OLD: 1.27.3-gke.100
gcloud beta container --project $projectId \
  clusters create $gkecluster \
  --zone $zone \
  --no-enable-basic-auth \
  --cluster-version "1.27.8-gke.1067004" \
  --release-channel "regular" \
  --machine-type "e2-standard-2" \
  --image-type "COS_CONTAINERD" \
  --disk-type "pd-balanced" \
  --disk-size "100" \
  --metadata disable-legacy-endpoints=true \
  --scopes "https://www.googleapis.com/auth/compute","https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/trace.append" \
  --num-nodes "4" \
  --logging=SYSTEM,WORKLOAD,API_SERVER,SCHEDULER,CONTROLLER_MANAGER \
  --monitoring=SYSTEM,API_SERVER,SCHEDULER,CONTROLLER_MANAGER,POD \
  --enable-private-nodes \
  --master-ipv4-cidr "172.16.0.0/28" \
  --enable-ip-alias \
  --network "projects/$projectId/global/networks/$network" \
  --subnetwork "projects/$projectId/regions/$region/subnetworks/$subnet" \
  --default-max-pods-per-node "110" \
  --security-posture standard \
  --workload-vulnerability-scanning disabled \
  --no-enable-master-authorized-networks \
  --addons HttpLoadBalancing,GcePersistentDiskCsiDriver \
  --enable-autoupgrade \
  --enable-autorepair \
  --binauthz-evaluation-mode DISABLED \
  --enable-managed-prometheus \
  --enable-shielded-nodes \
  --node-locations "us-east1-b" \
  --max-surge-upgrade 1 \
  --max-unavailable-upgrade 0 \
  --location-policy "BALANCED" \
  --labels $labels | gnomon

#####################  Configure metrics (managed prometheus) ()  #####################

# configure ns for application - not counted
kubectl apply -f https://raw.githubusercontent.com/dushyantgill/Citizerve-NodeJS/main/k8s/citizerve-ns.yaml

# deploy CRD for prometheus metrics scraping - 0.4577s, 1 command, 1 parameters
kubectl apply -f https://raw.githubusercontent.com/dushyantgill/Citizerve-NodeJS/main/k8s/gcp/metrics/citizenapi-pod-monitoring.yaml | gnomon

# deploy CRD for prometheus metrics scraping - 0.3677s, 1 command, 1 parameters
kubectl apply -f https://raw.githubusercontent.com/dushyantgill/Citizerve-NodeJS/main/k8s/gcp/metrics/resourceapi-pod-monitoring.yaml | gnomon

# Managed Service for Prometheus
#   Verify the PodMonitoring resources are installed in the intended namespace - not counted
kubectl get podmonitoring -A

# troubleshooting managed prometheus - not counted
# https://cloud.google.com/stackdriver/docs/managed-prometheus/troubleshooting 
kubectl logs -f -ngmp-system -lapp.kubernetes.io/part-of=gmp

kubectl logs -f -ngmp-system -lapp.kubernetes.io/name=collector -c prometheus
