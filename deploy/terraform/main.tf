terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment to use S3 backend for remote state
  # backend "s3" {
  #   bucket = "racetrack-streaming-tfstate"
  #   key    = "infra/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

# --- Data sources ---

data "aws_availability_zones" "available" {
  state = "available"
}

# Auto-select latest Ubuntu 24.04 LTS x86_64 AMI if not specified
data "aws_ami" "ubuntu" {
  count       = var.ami_id == "" ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id      = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu[0].id
  admin_fqdn  = "${var.admin_subdomain}.${var.domain}"
  rtmp_fqdn   = "${var.rtmp_subdomain}.${var.domain}"
}
