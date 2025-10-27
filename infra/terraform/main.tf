locals {
  name = var.project_name
}

# ECR
resource "aws_ecr_repository" "repo" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = true }
  lifecycle {
    prevent_destroy = false
  }
}

# CloudWatch Logs
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${local.name}"
  retention_in_days = 14
}

# Security groups
resource "aws_security_group" "alb_sg" {
  name        = "${local.name}-alb-sg"
  description = "ALB SG"
  vpc_id      = var.vpc_id
  ingress { from_port = 80  to_port = 80  protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  egress  { from_port = 0   to_port = 0   protocol = "-1"  cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_security_group" "svc_sg" {
  name        = "${local.name}-svc-sg"
  description = "Service SG"
  vpc_id      = var.vpc_id
  ingress {
    from_port                = var.container_port
    to_port                  = var.container_port
    protocol                 = "tcp"
    security_groups          = [aws_security_group.alb_sg.id]
    description              = "ALB to service"
  }
  egress  { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }
}

# ALB + TG + Listener
resource "aws_lb" "alb" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_target_group" "tg" {
  name        = "${local.name}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"
  health_check {
    path                = "/healthz"
    port                = var.container_port
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# ECS cluster
resource "aws_ecs_cluster" "cluster" {
  name = "${local.name}-cluster"
}

# IAM roles for ECS
data "aws_iam_policy_document" "task_exec_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service" identifiers = ["ecs-tasks.amazonaws.com"] }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.task_exec_trust.json
}

resource "aws_iam_role_policy_attachment" "task_exec_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "task_exec_ecr" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Task role (for app permissions; empty for now)
data "aws_iam_policy_document" "task_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service" identifiers = ["ecs-tasks.amazonaws.com"] }
  }
}
resource "aws_iam_role" "task_role" {
  name               = "${local.name}-task-role"
  assume_role_policy = data.aws_iam_policy_document.task_trust.json
}

# Task definition (a base revision; image gets updated by GitHub Actions)
resource "aws_ecs_task_definition" "task" {
  family                   = "${local.name}-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role.arn

  container_definitions = jsonencode([{
    name      = "fastapi"
    image     = "${aws_ecr_repository.repo.repository_url}:bootstrap"
    essential = true
    portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
    environment = [{ name = "APP_ENV", value = "prod" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ecs"
      }
    }
    healthCheck = {
      "retries" : 3,
      "command" : ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/healthz || exit 1"],
      "timeout" : 5,
      "interval": 15,
      "startPeriod": 10
    }
  }])
}

# ECS Service on Fargate behind ALB
resource "aws_ecs_service" "svc" {
  name            = "${local.name}-svc"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    assign_public_ip = false
    security_groups  = [aws_security_group.svc_sg.id]
    subnets          = var.private_subnet_ids
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "fastapi"
    container_port   = var.container_port
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  lifecycle {
    ignore_changes = [task_definition] # updated by pipeline
  }
}

# GitHub OIDC provider (create if you don’t have it)
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    # GitHub Actions OIDC root CA thumbprint (current as of 2025; update if AWS errors)
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]
}

# IAM Role for GitHub Actions OIDC, scoped to this repo
data "aws_iam_policy_document" "gha_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals { type = "Federated" identifiers = [aws_iam_openid_connect_provider.github.arn] }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "gha_oidc" {
  name               = "${local.name}-gha-oidc"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
}

# Permissions for pipeline: ECR push/pull, ECS update, task registration, logs describe
data "aws_iam_policy_document" "gha_policy" {
  statement {
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecs:RegisterTaskDefinition",
      "ecs:DescribeTaskDefinition",
      "ecs:UpdateService",
      "ecs:DescribeServices",
      "ecs:DescribeClusters",
      "ecs:ListTasks",
      "ecs:DescribeTasks"
    ]
    resources = ["*"]
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.task_execution.arn, aws_iam_role.task_role.arn]
  }
  statement {
    actions   = ["logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:GetLogEvents"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_inline" {
  role   = aws_iam_role.gha_oidc.id
  name   = "${local.name}-gha-inline"
  policy = data.aws_iam_policy_document.gha_policy.json
}