variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "racetrack-photos"
}

variable "instance_type" {
  default = "t3.small"
}

variable "key_name" {
  description = "EC2 SSH key pair name"
  type        = string
}

variable "domain_name" {
  default = "photos.racetrackstreaming.com"
}

variable "s3_bucket_name" {
  default = "racetrack-photos-storage"
}

variable "google_client_id" {
  description = "Google OAuth client ID"
  type        = string
  sensitive   = true
}

variable "google_client_secret" {
  description = "Google OAuth client secret"
  type        = string
  sensitive   = true
}

variable "session_secret" {
  description = "Session encryption secret"
  type        = string
  sensitive   = true
}

variable "admin_emails" {
  description = "Comma-separated list of admin email addresses"
  type        = string
}

variable "venmo_username" {
  description = "Venmo username for buy-me-a-coffee"
  type        = string
  default     = ""
}

variable "ami_id" {
  description = "AMI ID for EC2 instance (Ubuntu 22.04)"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "VPC ID (uses default VPC if empty)"
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID (uses first default subnet if empty)"
  type        = string
  default     = ""
}
