# Delegated subdomain zone. The parent sagaruprety.com.np stays on Cloudflare;
# only this subdomain's NS records move to Route53 through a one-time parent-zone update.
resource "aws_route53_zone" "sentinel" {
  #checkov:skip=CKV2_AWS_38:DNSSEC signing needs a KMS key and adds operational overhead not worth it for an ephemeral demo project
  #checkov:skip=CKV2_AWS_39:query logging needs a CloudWatch log group and resource policy not justified for an ephemeral demo project
  name = "sentinel.sagaruprety.com.np"

  tags = {
    Name = "${local.project_name}-${local.environment}-sentinel-zone"
  }
}
