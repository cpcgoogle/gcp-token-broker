#!/bin/bash

# Copyright 2019 Google LLC
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# In general we want to enable debug through -x
# But there are also some commands involving passwords/keys
# so make sure you turn it off (set +x) before such commands.
set -xeuo pipefail

#####################################################################
# WARNING: !! DO NOT USE IN PRODUCTION !!
# This script is an initialization action for Cloud Dataproc that
# installs dependencies to interact with the GCP token broker.
# This script is provided only as a reference and should *not* be
# used as-is in production.
#####################################################################


HADOOP_CONF_DIR="/etc/hadoop/conf"
HADOOP_LIB_DIR="/usr/lib/hadoop/lib"

NEW_JARS_BUCKET="gs://gcp-token-broker"
GCS_CONN_JAR="gcs-connector-hadoop2-2.0.0-SNAPSHOT-shaded.jar"
BROKER_CONN_JAR="broker-connector-hadoop2-0.1.0.jar"
ROLE="$(/usr/share/google/get_metadata_value attributes/dataproc-role)"
WORKER_COUNT="$(/usr/share/google/get_metadata_value attributes/dataproc-worker-count)"

# Flag checking whether init actions will run early.
# This will affect whether nodemanager should be restarted
readonly early_init="$(/usr/share/google/get_metadata_value attributes/dataproc-option-run-init-actions-early || echo 'false')"

readonly broker_tls_enabled="$(/usr/share/google/get_metadata_value attributes/gcp-token-broker-tls-enabled)"
readonly broker_tls_certificate="$(/usr/share/google/get_metadata_value attributes/gcp-token-broker-tls-certificate)"
readonly broker_uri_hostname="$(/usr/share/google/get_metadata_value attributes/gcp-token-broker-uri-hostname)"
readonly broker_uri_port="$(/usr/share/google/get_metadata_value attributes/gcp-token-broker-uri-port)"
readonly broker_realm="$(/usr/share/google/get_metadata_value attributes/gcp-token-broker-realm)"
readonly origin_kdc_hostname="$(/usr/share/google/get_metadata_value attributes/origin-kdc-hostname)"
readonly origin_realm="$(/usr/share/google/get_metadata_value attributes/origin-realm)"
readonly test_users="$(/usr/share/google/get_metadata_value attributes/test-users)"

function set_property_in_xml() {
  bdconfig set_property \
    --configuration_file $1 \
    --name "$2" --value "$3" \
    --create_if_absent \
    --clobber \
    || err "Unable to set $2"
}

function set_property_core_site() {
  set_property_in_xml "${HADOOP_CONF_DIR}/core-site.xml" "$1" "$2"
}

# Set some hadoop config properties
set_property_core_site "fs.gs.system.bucket" ""
set_property_core_site "fs.gs.delegation.token.binding" "com.google.cloud.broker.hadoop.fs.BrokerDelegationTokenBinding"
set_property_core_site "gcp.token.broker.tls.enabled" "$broker_tls_enabled"
set_property_core_site "gcp.token.broker.tls.certificate" "$broker_tls_certificate"
set_property_core_site "gcp.token.broker.uri.hostname" "$broker_uri_hostname"
set_property_core_site "gcp.token.broker.uri.port" "$broker_uri_port"
set_property_core_site "gcp.token.broker.realm" "$broker_realm"

# Download the JARs
gsutil cp "$NEW_JARS_BUCKET/$BROKER_CONN_JAR" "$HADOOP_LIB_DIR/"
OLD_GCS_CONN_JAR=$(ls /usr/lib/hadoop/lib/gcs-connector-*)
gsutil cp "$NEW_JARS_BUCKET/$GCS_CONN_JAR" .
mv $GCS_CONN_JAR $OLD_GCS_CONN_JAR

# Kerberos config
DATAPROC_REALM=$(sudo cat /etc/krb5.conf | grep "default_realm" | awk '{print $NF}')
sed -i "1s/^/[capaths]\n\t$origin_realm = {\n\t\t$broker_realm = .\n\t\t$DATAPROC_REALM = $broker_realm\n\t}\n\n/" "/etc/krb5.conf"
sed -i "/\[realms\]/a\ \t$origin_realm = {\n\t\tkdc = $origin_kdc_hostname\n\t}\n" "/etc/krb5.conf"

# Setup some useful env vars
PROJECT=$(curl -s "http://metadata.google.internal/computeMetadata/v1/project/project-id" -H "Metadata-Flavor: Google")
ZONE=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/zone" -H "Metadata-Flavor: Google" | awk -F/ '{print $NF}')
cat > /etc/profile.d/extra_env_vars.sh << EOL
export PROJECT=$PROJECT
export ZONE=$ZONE
export DATAPROC_REALM=$DATAPROC_REALM
export REALM=$origin_realm
EOL

# Create POSIX users (which need to exist on all nodes for Yarn to work)
USERS=${test_users}
if [[ -z "${USERS}" ]] ; then
  USERS=alice,bob,john
fi
for i in $(echo $USERS | sed "s/,/ /g")
do
    adduser --disabled-password --gecos "" $i
done

if [[ "${ROLE}" == 'Master' ]]; then
  # Add cross-realm trust user
  CROSS_REALM_TRUST_PASSWORD_URI=$(cat /tmp/cluster/properties/dataproc.properties | grep "kerberos.cross-realm-trust.shared-password.uri" | awk -F= '{print $NF}' | tr -d '\\')
  KMS_KEY_URI=$(cat /tmp/cluster/properties/dataproc.properties | grep "kerberos.kms.key.uri" | awk -F= '{print $NF}')
  set +x
  CROSS_REALM_TRUST_PASSWORD=$(gsutil cat "${CROSS_REALM_TRUST_PASSWORD_URI}" | \
    gcloud kms decrypt \
    --ciphertext-file - \
    --plaintext-file - \
    --key "${KMS_KEY_URI}")
  kadmin.local -q "addprinc -pw $CROSS_REALM_TRUST_PASSWORD krbtgt/$broker_realm@$DATAPROC_REALM"
  set -x
fi


# Restart services ---------------------------------------------------------------
if [[ "${ROLE}" == 'Master' ]]; then
  master_services=('hadoop-hdfs-namenode' 'hadoop-hdfs-secondarynamenode' 'hadoop-yarn-resourcemanager' 'hive-server2' 'hive-metastore' 'hadoop-yarn-timelineserver' 'hadoop-mapreduce-historyserver' 'spark-history-server' )
  for master_service in "${master_services[@]}"; do
    if ( systemctl is-enabled --quiet "${master_service}" ); then
      systemctl restart "${master_service}" || err "Cannot restart service: ${master_service}"
    fi
  done
fi
# In single node mode, we run datanode and nodemanager on the master.
if [[ "${ROLE}" == 'Worker' || "${WORKER_COUNT}" == '0' ]]; then
  if [[ "${early_init}" == 'false' ]]; then
    systemctl restart hadoop-yarn-nodemanager || err 'Cannot restart node manager'
  fi
fi