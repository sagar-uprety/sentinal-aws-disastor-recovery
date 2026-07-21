resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]
}

# Persistent bootstrap breaks the from-zero deployment credential cycle.
resource "aws_iam_role" "terraform_github_actions" {
  name = "${var.project_name}-terraform-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "terraform_state" {
  name = "${var.project_name}-terraform-state"
  role = aws_iam_role.terraform_github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:ListBucket"]
      Resource = [aws_s3_bucket.state.arn]
      }, {
      Effect   = "Allow"
      Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      Resource = ["${aws_s3_bucket.state.arn}/*"]
    }]
  })
}

resource "aws_iam_role_policy" "terraform_workload" {
  #checkov:skip=CKV_AWS_289,CKV_AWS_290,CKV_AWS_355:Terraform needs these explicit multi-service control-plane actions; many create, describe, and IAM bootstrap APIs cannot be ARN-scoped.
  name = "${var.project_name}-terraform-workload"
  role = aws_iam_role.terraform_github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:AllocateAddress", "ec2:AssociateRouteTable", "ec2:AttachInternetGateway", "ec2:AuthorizeSecurityGroupIngress", "ec2:CreateFlowLogs", "ec2:CreateInternetGateway", "ec2:CreateNatGateway", "ec2:CreateRoute", "ec2:CreateRouteTable", "ec2:CreateSecurityGroup", "ec2:CreateSubnet", "ec2:CreateTags", "ec2:CreateVpc", "ec2:CreateVpcEndpoint", "ec2:DeleteFlowLogs", "ec2:DeleteInternetGateway", "ec2:DeleteNatGateway", "ec2:DeleteRoute", "ec2:DeleteRouteTable", "ec2:DeleteSecurityGroup", "ec2:DeleteSubnet", "ec2:DeleteTags", "ec2:DeleteVpc", "ec2:DescribeAddresses", "ec2:DescribeAvailabilityZones", "ec2:DescribeFlowLogs", "ec2:DescribeInternetGateways", "ec2:DescribeNatGateways", "ec2:DescribeNetworkInterfaces", "ec2:DescribeRouteTables", "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVpcs", "ec2:DescribeVpcEndpoints", "ec2:DetachInternetGateway", "ec2:DisassociateRouteTable", "ec2:ModifyVpcAttribute", "ec2:ReleaseAddress", "ec2:RevokeSecurityGroupIngress",
        "elasticloadbalancing:AddTags", "elasticloadbalancing:CreateListener", "elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteListener", "elasticloadbalancing:DeleteLoadBalancer", "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:DescribeListeners", "elasticloadbalancing:DescribeLoadBalancerAttributes", "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetHealth", "elasticloadbalancing:ModifyLoadBalancerAttributes", "elasticloadbalancing:RemoveTags", "elasticloadbalancing:SetSecurityGroups", "elasticloadbalancing:SetSubnets",
        "ecs:CreateCluster", "ecs:CreateService", "ecs:DeleteCluster", "ecs:DeleteService", "ecs:DeregisterTaskDefinition", "ecs:DescribeClusters", "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:ListTagsForResource", "ecs:ListTaskDefinitions", "ecs:RegisterTaskDefinition", "ecs:TagResource", "ecs:UntagResource", "ecs:UpdateService",
        "ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:CreateRepository", "ecr:DeleteLifecyclePolicy", "ecr:DeleteRepository", "ecr:DescribeImages", "ecr:DescribeRegistry", "ecr:DescribeRepositories", "ecr:GetAuthorizationToken", "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:PutImageScanningConfiguration", "ecr:PutImageTagMutability", "ecr:PutLifecyclePolicy", "ecr:PutReplicationConfiguration", "ecr:TagResource", "ecr:UploadLayerPart",
        "rds:AddTagsToResource", "rds:CreateDBInstance", "rds:CreateDBInstanceReadReplica", "rds:CreateDBParameterGroup", "rds:CreateDBSubnetGroup", "rds:DeleteDBInstance", "rds:DeleteDBParameterGroup", "rds:DeleteDBSubnetGroup", "rds:DescribeDBEngineVersions", "rds:DescribeDBInstances", "rds:DescribeDBParameterGroups", "rds:DescribeDBSubnetGroups", "rds:DescribeDBSnapshots", "rds:ListTagsForResource", "rds:ModifyDBInstance", "rds:ModifyDBParameterGroup", "rds:RemoveTagsFromResource", "rds:StartDBInstanceAutomatedBackupsReplication", "rds:StopDBInstanceAutomatedBackupsReplication",
        "iam:AttachRolePolicy", "iam:CreateRole", "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy", "iam:GetRole", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies", "iam:PassRole", "iam:PutRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:UpdateAssumeRolePolicy",
        "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups", "logs:ListTagsForResource", "logs:PutRetentionPolicy", "logs:TagResource",
        "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms", "cloudwatch:PutMetricAlarm", "cloudwatch:TagResource",
        "events:DeleteRule", "events:DescribeRule", "events:ListTargetsByRule", "events:PutRule", "events:PutTargets", "events:RemoveTargets",
        "servicediscovery:CreatePrivateDnsNamespace", "servicediscovery:CreateService", "servicediscovery:DeleteNamespace", "servicediscovery:DeleteService", "servicediscovery:GetNamespace", "servicediscovery:GetService", "servicediscovery:ListNamespaces", "servicediscovery:ListServices",
        "sns:CreateTopic", "sns:DeleteTopic", "sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:Subscribe", "sns:TagResource", "sns:Unsubscribe",
        "ssm:AddTagsToResource", "ssm:DeleteParameter", "ssm:DescribeParameters", "ssm:PutParameter", "ssm:RemoveTagsFromResource",
        "route53:ChangeResourceRecordSets", "route53:ChangeTagsForResource", "route53:CreateHealthCheck", "route53:CreateHostedZone", "route53:DeleteHealthCheck", "route53:DeleteHostedZone", "route53:GetHealthCheck", "route53:GetHostedZone", "route53:ListHostedZonesByName", "route53:ListResourceRecordSets", "route53:UpdateHealthCheck",
        "route53-recovery-control-config:CreateCluster", "route53-recovery-control-config:CreateControlPanel", "route53-recovery-control-config:CreateRoutingControl", "route53-recovery-control-config:CreateSafetyRule", "route53-recovery-control-config:DeleteCluster", "route53-recovery-control-config:DeleteControlPanel", "route53-recovery-control-config:DeleteRoutingControl", "route53-recovery-control-config:DeleteSafetyRule", "route53-recovery-control-config:DescribeCluster", "route53-recovery-control-config:DescribeControlPanel", "route53-recovery-control-config:DescribeRoutingControl", "route53-recovery-control-config:DescribeSafetyRule", "route53-recovery-control-config:ListClusters", "route53-recovery-control-config:ListControlPanels", "route53-recovery-control-config:ListRoutingControls", "route53-recovery-control-config:ListSafetyRules",
        "kms:DescribeKey", "sts:GetCallerIdentity", "tag:GetResources"
      ]
      Resource = "*"
    }]
  })
}
