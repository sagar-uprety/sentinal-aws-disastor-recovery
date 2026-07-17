# Delegated subdomain zone. The parent sagaruprety.com.np stays on Cloudflare;
# only this subdomain's NS records move to Route53, via a one-time manual
# addition to the Cloudflare zone (see docs/cloudflare-mcp-setup.md).
resource "aws_route53_zone" "sentinel" {
  #checkov:skip=CKV2_AWS_38:DNSSEC signing needs a KMS key and adds operational overhead not worth it for a delegated subdomain zone on an ephemeral demo project, torn down and rebuilt every session
  #checkov:skip=CKV2_AWS_39:query logging needs a CloudWatch log group and resource policy; not worth the cost/setup for a zone rebuilt from zero every session
  name = "sentinel.sagaruprety.com.np"

  tags = {
    Name = "${local.project_name}-${local.environment}-sentinel-zone"
  }
}
