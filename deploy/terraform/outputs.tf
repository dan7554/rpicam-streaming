output "ec2_public_ip" {
  description = "Elastic IP of the streaming server"
  value       = aws_eip.streaming.public_ip
}

output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.streaming.id
}

output "alb_dns" {
  description = "ALB DNS name (HTTPS) — point stream.racetrackstreaming.com CNAME here in Cloudflare"
  value       = aws_lb.alb.dns_name
}

output "nlb_dns" {
  description = "NLB DNS name (RTMP + WebRTC) — point rtmp.racetrackstreaming.com CNAME here in Cloudflare"
  value       = aws_lb.nlb.dns_name
}

output "admin_url" {
  description = "Web UI URL"
  value       = "https://${local.admin_fqdn}"
}

output "rtmp_ingest" {
  description = "RTMP ingest URL for Pi cameras"
  value       = "rtmp://${local.rtmp_fqdn}:1935"
}

output "ssh_command" {
  description = "SSH command to connect to EC2"
  value       = "ssh -i ~/.ssh/racetrack-streaming.pem ec2-user@${aws_eip.streaming.public_ip}"
}

output "acm_validation" {
  description = "ACM cert DNS validation — add this CNAME in Cloudflare to validate the SSL cert"
  value = {
    for dvo in aws_acm_certificate.main.domain_validation_options : dvo.domain_name => {
      cname_name  = dvo.resource_record_name
      cname_value = dvo.resource_record_value
    }
  }
}

output "cloudflare_dns_records" {
  description = "DNS records to create in Cloudflare"
  value = <<-EOT
    
    Add these records in Cloudflare DNS:
    
    1. stream.racetrackstreaming.com  CNAME  ${aws_lb.alb.dns_name}  (Proxy OFF / DNS only)
    2. rtmp.racetrackstreaming.com    CNAME  ${aws_lb.nlb.dns_name}  (Proxy OFF / DNS only)
    
    ⚠️  Both MUST have Cloudflare proxy DISABLED (gray cloud) — RTMP/WebRTC need direct TCP/UDP.
  EOT
}
