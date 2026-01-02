provider "aws" {
  region = "ap-south-1"
}

resource "aws_ecr_repository" "blue_green_deploymt" {
  name                 = "blue_green_deploymemnt"
  image_tag_mutability = "MUTABLE"
  force_delete    = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Project = "3TierBankingApp"
    Managed = "Terraform"
  }
}
resource "aws_ecr_lifecycle_policy" "cleanup" {
  repository = aws_ecr_repository.blue_green_deploymt.name

  policy = <<EOF
{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Delete images older than 30 days",
      "selection": {
        "tagStatus": "any",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 30
      },
      "action": {
        "type": "expire"
      }
    }
  ]
}
EOF
}

