variable "aws_region" {
  description = "AWS region"
  default     = "us-west-2"
}

variable "domain" {
  description = "Root domain for the streaming service"
  default     = "racetrackstreaming.com"
}

variable "admin_subdomain" {
  description = "Subdomain for admin/web UI"
  default     = "stream"
}

variable "rtmp_subdomain" {
  description = "Subdomain for RTMP ingest + WebRTC media"
  default     = "rtmp"
}

variable "instance_type" {
  description = "EC2 instance type (c6i.large for 720p, c6i.xlarge for 1080p overlay)"
  default     = "c6i.xlarge"
}

variable "key_name" {
  description = "EC2 SSH key pair name"
  type        = string
}

variable "ami_id" {
  description = "AMI ID (Amazon Linux 2023 arm64 or x86_64). Leave empty to auto-select."
  default     = ""
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDRs (need 2 for ALB)"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to SSH into EC2"
  default     = ["0.0.0.0/0"]
}

variable "mediamtx_version" {
  description = "MediaMTX version to install"
  default     = "1.17.1"
}

variable "tags" {
  description = "Common tags for all resources"
  default = {
    Project = "racetrack-streaming"
    ManagedBy = "terraform"
  }
}
