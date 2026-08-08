# Staging PostgreSQL on a private VPS with backup/PITR intent to object storage.
# Not inside the solo-app chart. Credentials never stored in Git.
# Prefer a managed cloud Postgres for production (see PROVIDER-DECISION).

locals {
  labels = merge(
    {
      "solo.empire/environment" = "staging"
      "solo.empire/managed-by"  = "opentofu"
      "solo.empire/component"   = "postgresql"
    },
    var.labels,
  )

  pitr = {
    enabled            = true
    retention_days     = var.pitr_retention_days
    wal_archive        = var.backup_bucket != "" ? "s3://${var.backup_bucket}/postgres/wal" : "s3://BACKUPS_BUCKET/postgres/wal"
    base_backup_path   = var.backup_bucket != "" ? "s3://${var.backup_bucket}/postgres/base" : "s3://BACKUPS_BUCKET/postgres/base"
    schedule_cron      = var.backup_cron
    tool               = "pgBackRest-or-wal-g"
    restore_drill_days = 30
  }
}

resource "random_password" "postgres_superuser" {
  count   = var.enabled ? 1 : 0
  length  = 32
  special = false
}

resource "hcloud_server" "postgres" {
  count        = var.enabled ? 1 : 0
  name         = "${var.name}-pg"
  server_type  = var.server_type
  location     = var.location
  image        = "ubuntu-24.04"
  ssh_keys     = var.ssh_key_ids
  firewall_ids = var.firewall_id != null ? [var.firewall_id] : []
  labels       = local.labels

  user_data = sensitive(templatefile("${path.module}/templates/postgres.yaml.tftpl", {
    postgres_version = var.postgres_version
    # Password never embedded here — load via secret manager after bootstrap.
    bootstrap_note = "Load password from secret manager path apps/platform/staging/postgres"
  }))
}

resource "hcloud_volume" "pgdata" {
  count    = var.enabled ? 1 : 0
  name     = "${var.name}-pgdata"
  size     = var.volume_size_gb
  location = var.location
  format   = "ext4"
  labels   = local.labels
}

resource "hcloud_volume_attachment" "pgdata" {
  count     = var.enabled ? 1 : 0
  volume_id = hcloud_volume.pgdata[0].id
  server_id = hcloud_server.postgres[0].id
  automount = true
}

resource "hcloud_server_network" "postgres" {
  count      = var.enabled && var.network_id != null ? 1 : 0
  server_id  = hcloud_server.postgres[0].id
  network_id = tonumber(var.network_id)
  ip         = var.private_ip
}

resource "terraform_data" "pitr_plan" {
  input = {
    enabled    = var.enabled
    databases  = var.databases
    private_ip = var.private_ip
    listen     = "private_network_only"
    pitr       = local.pitr
    restore = {
      procedure  = "operations/STAGING-DATA-BACKUP-RESTORE.md"
      drill_days = local.pitr.restore_drill_days
    }
    note = "PITR requires object-storage credentials delivered via secret manager, not Git."
  }
}
