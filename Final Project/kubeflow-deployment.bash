export PROJECT_ID=kubeflow-de
export EMAIL=dylansugito@gmail.com

gcloud services enable \
  compute.googleapis.com \
  container.googleapis.com \
  iam.googleapis.com \
  servicemanagement.googleapis.com \
  cloudresourcemanager.googleapis.com \
  ml.googleapis.com \
  iap.googleapis.com \
  sqladmin.googleapis.com \
  meshconfig.googleapis.com 

# Cloud Build API is optional, you need it if using Fairing.
# gcloud services enable cloudbuild.googleapis.com

#Initialize Anthos service mesh
curl --request POST \
  --header "Authorization: Bearer $(gcloud auth print-access-token)" \
  --data '' \
  https://meshconfig.googleapis.com/v1alpha1/projects/${PROJECT_ID}:initialize

#need to have a temporary cluster
LOCATION=asia-southeast2-a
gcloud beta container clusters create tmp-cluster \
  --release-channel regular \
  --workload-pool=${PROJECT_ID}.svc.id.goog \
  --zone=${LOCATION}

#Add Credentials
#Pick API & Services >> OAuth consent screen

# App name = Kubeflow
# email = dylansugito@gmail.com
# add domain = kubeflow-de.cloud.goog
# dev_email = dylansugito@gmail.com

#Pick Credential >> Create Credentials >> Oauth client ID 
#App type = Web Application
#Name = Kubeflow

CLIENT_ID=1021776887863-62oh5q5is4hhk30inv66bt1bf8p13usn.apps.googleusercontent.com
CLIENT_SECRET=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

#edit Kubeflow (pencil icon on the right)
#add URI = https://iap.googleapis.com/v1/oauth/clientIds/1021776887863-62oh5q5is4hhk30inv66bt1bf8p13usn.apps.googleusercontent.com:handleRedirect



### Setup Management Cluster ###

gcloud components install kubectl kpt anthoscli beta
gcloud components update
# If the output said the Cloud SDK component manager is disabled for installation, copy the command from output and run it.

#sudo apt-get install kubectl google-cloud-sdk-kpt google-cloud-sdk google-cloud-sdk
#sudo apt-get update && sudo apt-get --only-upgrade install google-cloud-sdk-config-connector google-cloud-sdk-anthos-auth google-cloud-sdk-datalab google-cloud-sdk-bigtable-emulator google-cloud-sdk-app-engine-grpc google-cloud-sdk-minikube google-cloud-sdk-app-engine-python google-cloud-sdk-app-engine-python-extras google-cloud-sdk-gke-gcloud-auth-plugin google-cloud-sdk-skaffold google-cloud-sdk-datastore-emulator google-cloud-sdk-app-engine-go google-cloud-sdk-local-extract google-cloud-sdk-terraform-validator google-cloud-sdk-cbt google-cloud-sdk-spanner-emulator google-cloud-sdk-kubectl-oidc google-cloud-sdk google-cloud-sdk-cloud-build-local google-cloud-sdk-kpt google-cloud-sdk-app-engine-java google-cloud-sdk-firestore-emulator kubectl google-cloud-sdk-pubsub-emulator

# Detect your OS and download corresponding latest Kustomize binary
curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"  | bash

# Add the kustomize package to your $PATH env variable
sudo mv ./kustomize /usr/local/bin/kustomize

sudo wget https://github.com/mikefarah/yq/releases/download/3.4.1/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq
yq --version
# yq version 3.4.1

#make directory kflow
mkdir kflow
cd kflow
#fetch blueprints for management cluster
git clone https://github.com/kubeflow/gcp-blueprints.git 
cd gcp-blueprints
git checkout tags/v1.3.1 -b v1.3.1

cd management

#change variable in env.sh
export MGMT_PROJECT=kubeflow-de
export MGMT_DIR=~/gcp-blueprints/management/
export MGMT_NAME=mgt-cluster
export LOCATION=asia-southeast2-a

#then source it
source env.sh 

#Configure kpt setter values
kpt cfg set -R . name "${MGMT_NAME}"
kpt cfg set -R . gcloud.core.project "${MGMT_PROJECT}"
kpt cfg set -R . location "${LOCATION}"

#if an error "Did you mean this? fn pkg" then run this
curl -L https://github.com/GoogleContainerTools/kpt/releases/download/v0.39.2/kpt_linux_amd64 > kpt_0_39_2
chmod +x kpt_0_39_2
alias kpt="$(readlink -f kpt_0_39_2)"
kpt version
#kpt needs to be version 0.39.2
#then run the kpt cfg set command again

#or use this
bash kpt-set.sh

#check values using this command
kpt cfg list-setters .

#Deploy the management cluster by applying cluster resources:
make apply-cluster

#Optionally, you can verify the management cluster spec before applying it by:
make hydrate-cluster

#Create a kubectl context for the management cluster, it will be named ${MGMT_NAME}
make create-context

#Install the Cloud Config Connector
make apply-kcc

#Optionally, you can verify the Config Connector installation before applying it by:
make hydrate-kcc


### Deploy Kubeflow ###
#go to default dir
cd ~
#and install jq
sudo apt install jq
jq --version

cd kflow/gcp-blueprints/kubeflow

#Run the following command to pull upstream manifests from kubeflow/manifests repository.
bash ./pull-upstream.sh

gcloud auth login
#click the link and copy the code to the command line

#Review and fill all the environment variables in 
#gcp-blueprints/kubeflow/env.sh
#then source it
source env.sh

#Set environment variables with OAuth Client ID and Secret for IAP:
CLIENT_ID=1021776887863-62oh5q5is4hhk30inv66bt1bf8p13usn.apps.googleusercontent.com
CLIENT_SECRET=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

#DO NOT omit the export because scripts triggered by make need these environment variables.
#Do not check in these two environment variables configuration to source control, they are secrets.

#set vars
bash ./kpt-set.sh

#check vars
kpt cfg list-setters .
kpt cfg list-setters common/managed-storage
kpt cfg list-setters apps/pipelines

#configure kubectl context
MGMTCTXT=mgt-cluster
KF_PROJECT=kubeflow-de
#kubectl config set-context NAME [--cluster=cluster_nickname] [--user=user_nickname] [--namespace=namespace]
kubectl config set-context mgt-cluster
kubectl config use-context "${MGMTCTXT}"
kubectl create namespace "${KF_PROJECT}"

MGMT_PROJECT=kubeflow-de
MGMT_NAME=mgt-cluster

#Redirect to management directory and configure kpt setter:
pushd "../management"
kpt cfg set -R . name "${MGMT_NAME}"
kpt cfg set -R . gcloud.core.project "${MGMT_PROJECT}"
kpt cfg set -R . managed-project "${KF_PROJECT}"

#Update the policy:
gcloud beta anthos apply ./managed-project/iam.yaml

#Return to gcp-blueprints/kubeflow directory:
popd

#Deploy Kubeflow
make apply

gcloud container clusters list
gcloud container clusters get-credentials mgt-cluster --zone asia-southeast2-a  --project kubeflow-de

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf HOME/.kube/config sudo chown (id -u):$(id -g) 
$HOME/.kube/config

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config