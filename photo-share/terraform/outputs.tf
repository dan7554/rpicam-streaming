output "instance_id" {
  value = aws_instance.photos.id
}

output "elastic_ip" {
  value = aws_eip.photos.public_ip
}

output "s3_bucket" {
  value = aws_s3_bucket.photos.bucket
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.photos.public_ip}"
}

output "dns_instructions" {
  value = "Add an A record for ${var.domain_name} pointing to ${aws_eip.photos.public_ip}"
}
