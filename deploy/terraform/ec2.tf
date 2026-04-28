# --- EC2 Instance ---

resource "aws_instance" "streaming" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    mediamtx_version = var.mediamtx_version
  })

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "racetrack-streaming" }
}

# Elastic IP for stable address (NLB + WebRTC ICE)
resource "aws_eip" "streaming" {
  instance = aws_instance.streaming.id
  domain   = "vpc"
  tags     = { Name = "racetrack-streaming" }
}
