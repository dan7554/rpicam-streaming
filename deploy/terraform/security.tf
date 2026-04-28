# --- Security Groups ---

# EC2 instance security group
resource "aws_security_group" "ec2" {
  name_prefix = "racetrack-ec2-"
  vpc_id      = aws_vpc.main.id
  description = "EC2 instance for streaming server"

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  # RTMP ingest from Pi cameras (via NLB — NLB preserves source IP)
  ingress {
    description = "RTMP ingest"
    from_port   = 1935
    to_port     = 1935
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WebRTC media (ICE UDP mux)
  ingress {
    description = "WebRTC UDP"
    from_port   = 8189
    to_port     = 8189
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # WebRTC TCP fallback
  ingress {
    description = "WebRTC TCP fallback"
    from_port   = 8189
    to_port     = 8189
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Go server from ALB
  ingress {
    description     = "HTTP from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # NLB health checks (NLB has no SG, uses VPC CIDR)
  ingress {
    description = "NLB health checks"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # All outbound (YouTube RTMP, MYLAPS API, package updates)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "racetrack-ec2" }
}

# ALB security group
resource "aws_security_group" "alb" {
  name_prefix = "racetrack-alb-"
  vpc_id      = aws_vpc.main.id
  description = "ALB for HTTPS termination"

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP redirect"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "racetrack-alb" }
}
