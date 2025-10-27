output "ecr_repository_url"     { value = aws_ecr_repository.repo.repository_url }
output "alb_dns_name"           { value = aws_lb.alb.dns_name }
output "ecs_cluster_name"       { value = aws_ecs_cluster.cluster.name }
output "ecs_service_name"       { value = aws_ecs_service.svc.name }
output "task_execution_role_arn"{ value = aws_iam_role.task_execution.arn }
output "task_role_arn"          { value = aws_iam_role.task_role.arn }
output "gha_role_arn"           { value = aws_iam_role.gha_oidc.arn }