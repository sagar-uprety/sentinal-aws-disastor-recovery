# Persistent delegated zone keeps nameservers stable across workload rebuilds.
resource "aws_route53_zone" "pilotlight" {
  #checkov:skip=CKV2_AWS_38:DNSSEC signing needs a KMS key and adds operational overhead not worth it for this demo project
  #checkov:skip=CKV2_AWS_39:query logging needs a CloudWatch log group and resource policy not justified for this demo project
  name = "pilotlight.sagaruprety.com.np"

  tags = {
    Name = "${var.project_name}-shared-pilotlight-zone"
  }
}
