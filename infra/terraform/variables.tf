variable "aws_region"      { type = string }
variable "project_name"    { type = string  default = "fastapi-ecs" }
variable "ecr_repo_name"   { type = string  default = "fastapi-ecs" }

variable "vpc_id"          { type = string }
variable "public_subnet_ids"  { type = list(string) }
variable "private_subnet_ids" { type = list(string) }

variable "desired_count"   { type = number  default = 2 }
variable "container_port"  { type = number  default = 8080 }
variable "cpu"             { type = number  default = 256 }
variable "memory"          { type = number  default = 512 }

# GitHub OIDC / role assumption
variable "github_repo"     { type = string  description = "owner/repo" }
