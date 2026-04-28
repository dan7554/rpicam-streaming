# --- ALB (Application Load Balancer) ---
# Handles HTTPS termination for Web UI, API, and WHEP signaling

# ACM certificate for HTTPS
# After terraform apply, add the DNS validation CNAME in Cloudflare,
# then run `terraform apply` again to complete validation.
resource "aws_acm_certificate" "main" {
  domain_name       = local.admin_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "racetrack-streaming" }
}

# ALB
resource "aws_lb" "alb" {
  name               = "racetrack-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "racetrack-alb" }
}

# Target group → EC2:8080
resource "aws_lb_target_group" "app" {
  name        = "racetrack-app"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/api/status"
    protocol            = "HTTP"
    port                = "8080"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.streaming.id
  port             = 8080
}

# HTTPS listener
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.main.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# HTTP → HTTPS redirect
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
