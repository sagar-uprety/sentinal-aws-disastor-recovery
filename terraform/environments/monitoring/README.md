# Monitoring Environment

Independent eu-west-1 monitoring plane with its own state, VPC, ECS service, ALB, ECR repository, DynamoDB persistence, IAM, certificate, and apex DNS record.

Apply this root independently from workload primary and secondary roots. Workload drill and destroy workflows must not target this state.
