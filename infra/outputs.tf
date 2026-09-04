output "instance_id" {
  description = "EC2 instance used by Systems Manager and recovery commands."
  value       = aws_instance.workbox.id
}

output "public_ip" {
  description = "Public address used only for outbound connectivity and Tailscale transport."
  value       = aws_instance.workbox.public_ip
}

output "availability_zone" {
  description = "Availability Zone containing the host and persistent home volume."
  value       = aws_instance.workbox.availability_zone
}

output "data_volume_id" {
  description = "Persistent EBS volume mounted at /home."
  value       = aws_ebs_volume.home.id
}

output "ssm_start_session" {
  description = "Break glass command used before Tailscale is connected."
  value       = "aws ssm start-session --profile personal-cloud-admin --region us-east-1 --target ${aws_instance.workbox.id}"
}
