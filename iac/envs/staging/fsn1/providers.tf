# Token from environment only: export HCLOUD_TOKEN=...
# Never commit tokens. Dummy default allows validate/plan with provision=false.
provider "hcloud" {
  token = var.hcloud_token != "" ? var.hcloud_token : "0000000000000000000000000000000000000000000000000000000000000000"
}
