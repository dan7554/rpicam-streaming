# --- NLB (Network Load Balancer) ---
# Handles RTMP (TCP 1935) and WebRTC media (UDP 8189)
# NLB is L4 — passes through raw TCP/UDP without HTTP parsing

resource "aws_lb" "nlb" {
  name               = "racetrack-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = aws_subnet.public[*].id

  tags = { Name = "racetrack-nlb" }
}

# --- RTMP target group + listener (TCP 1935) ---

resource "aws_lb_target_group" "rtmp" {
  name        = "racetrack-rtmp"
  port        = 1935
  protocol    = "TCP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "1935"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }
}

resource "aws_lb_target_group_attachment" "rtmp" {
  target_group_arn = aws_lb_target_group.rtmp.arn
  target_id        = aws_instance.streaming.id
  port             = 1935
}

resource "aws_lb_listener" "rtmp" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 1935
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rtmp.arn
  }
}

# --- WebRTC target group + listener (TCP_UDP 8189) ---
# TCP_UDP handles both UDP (primary) and TCP fallback on same port

resource "aws_lb_target_group" "webrtc" {
  name        = "racetrack-webrtc"
  port        = 8189
  protocol    = "TCP_UDP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "8080"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }
}

resource "aws_lb_target_group_attachment" "webrtc" {
  target_group_arn = aws_lb_target_group.webrtc.arn
  target_id        = aws_instance.streaming.id
  port             = 8189
}

resource "aws_lb_listener" "webrtc" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 8189
  protocol          = "TCP_UDP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webrtc.arn
  }
}
