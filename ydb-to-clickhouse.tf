# Infrastructure for the Yandex Managed Service for YDB, Managed Service for ClickHouse®, and Data Transfer
#
# RU: https://yandex.cloud/ru/docs/data-transfer/tutorials/ydb-to-clickhouse
# EN: https://yandex.cloud/en/docs/data-transfer/tutorials/ydb-to-clickhouse
#
# Configure the parameters of the source and target clusters and transfer:

locals {
  mch_version  = "" # Desired version of the ClickHouse®. For available versions, see the documentation main page: https://yandex.cloud/en/docs/managed-clickhouse/.
  mch_password = "" # ClickHouse® user's password

  # Specify these settings ONLY AFTER the cluster is created. Then run the "terraform apply" command again.
  transfer_enabled = 0 # Set to 1 to enable the transfer

  # The following settings are predefined. Change them only if necessary.
  network_name          = "mch-network"                     # Name of the network
  subnet_name           = "mch-subnet-a"                    # Name of the subnet
  zone_a_v4_cidr_blocks = "10.1.0.0/16"                     # CIDR block for the subnet in the ru-central1-a availability zone
  security_group_name   = "mch-security-group"              # Name of the security group
  sa_name               = "ydb-account"                     # Name of the service account
  ydb_name              = "ydb1"                            # Name of the YDB
  mch_cluster_name      = "clickhouse-cluster"              # Name of the ClickHouse® cluster
  mch_database_name     = "db1"                             # Name of the ClickHouse® database
  mch_username          = "user1"                           # Username of the ClickHouse® cluster
  source_endpoint_name  = "ydb-source"                      # Name of the source endpoint for the Managed Service for YBD
  target_endpoint_name  = "clickhouse-target"               # Name of the target endpoint for the Managed Service for ClickHouse® cluster
  transfer_name         = "transfer-from-ydb-to-clickhouse" # Name of the transfer between the Managed Service for YDB and Managed Service for ClickHouse® cluster
}

# Network infrastructure for the Managed Service for ClickHouse® cluster

resource "yandex_vpc_network" "mch-network" {
  description = "Network for the Managed Service for ClickHouse® cluster"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "mch-subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.mch-network.id
  v4_cidr_blocks = [local.zone_a_v4_cidr_blocks]
}

resource "yandex_vpc_security_group" "mch-security-group" {
  description = "Security group for the Managed Service for ClickHouse® cluster"
  name        = local.security_group_name
  network_id  = yandex_vpc_network.mch-network.id

  ingress {
    description    = "Allow incoming traffic from the port 8443"
    protocol       = "TCP"
    port           = 8443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow incoming traffic from the port 9440"
    protocol       = "TCP"
    port           = 9440
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allows all outgoing traffic"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}

# Infrastructure for the Managed Service for YDB

# Create the Yandex Managed Service for YDB
resource "yandex_ydb_database_serverless" "ydb" {
  name        = local.ydb_name
  location_id = "ru-central1"
}

# Create a service account
resource "yandex_iam_service_account" "ydb-account" {
  name = local.sa_name
}

# Grant a role to the service account. The role allows to perform any operations with database.
resource "yandex_ydb_database_iam_binding" "ydb-editor" {
  database_id = yandex_ydb_database_serverless.ydb.id
  role        = "ydb.editor"
  members = [
    "serviceAccount:${yandex_iam_service_account.ydb-account.id}",
  ]
}

# Infrastructure for the Managed Service for ClickHouse® cluster

resource "yandex_mdb_clickhouse_cluster" "clickhouse-cluster" {
  description        = "Managed Service for ClickHouse® cluster"
  name               = local.mch_cluster_name
  environment        = "PRODUCTION"
  version            = local.mch_version
  network_id         = yandex_vpc_network.mch-network.id
  security_group_ids = [yandex_vpc_security_group.mch-security-group.id]

  clickhouse {
    resources {
      resource_preset_id = "s2.micro"
      disk_type_id       = "network-ssd"
      disk_size          = 10 # GB
    }
  }
  host {
    type             = "CLICKHOUSE"
    zone             = "ru-central1-a"
    subnet_id        = yandex_vpc_subnet.mch-subnet-a.id
    assign_public_ip = true
  }

  database {
    name = local.mch_database_name
  }

  user {
    name     = local.mch_username
    password = local.mch_password
    permission {
      database_name = local.mch_database_name
    }
  }
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "ydb-source" {
  description = "Source endpoint for the Managed Service for YDB"
  name        = local.source_endpoint_name
  settings {
    ydb_source {
      database           = yandex_ydb_database_serverless.ydb.database_path
      service_account_id = yandex_iam_service_account.ydb-account.id
      paths              = ["table1"]
    }
  }
}

resource "yandex_datatransfer_endpoint" "mch_target" {
  description = "Target endpoint for the Managed Service for ClickHouse® cluster"
  name        = local.target_endpoint_name
  settings {
    clickhouse_target {
      connection {
        connection_options {
          mdb_cluster_id = yandex_mdb_clickhouse_cluster.clickhouse-cluster.id
          database       = local.mch_database_name
          user           = local.mch_username
          password {
            raw = local.mch_password
          }
        }
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "ydb-clickhouse-transfer" {
  description = "Transfer from the Managed Service for YDB to the Managed Service for ClickHouse® cluster"
  count       = local.transfer_enabled
  name        = local.transfer_name
  source_id   = yandex_datatransfer_endpoint.ydb-source.id
  target_id   = yandex_datatransfer_endpoint.mch_target.id
  type        = "SNAPSHOT_AND_INCREMENT" # Copy all data from the source and start replication
}
