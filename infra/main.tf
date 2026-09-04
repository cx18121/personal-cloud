data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "personal" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "personal-cloud"
  }
}

resource "aws_internet_gateway" "personal" {
  vpc_id = aws_vpc.personal.id

  tags = {
    Name = "personal-cloud"
  }
}

resource "aws_subnet" "workbox" {
  vpc_id                  = aws_vpc.personal.id
  availability_zone       = data.aws_availability_zones.available.names[0]
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "personal-cloud-workbox"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.personal.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.personal.id
  }

  tags = {
    Name = "personal-cloud-public"
  }
}

resource "aws_route_table_association" "workbox" {
  subnet_id      = aws_subnet.workbox.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "workbox" {
  name        = "personal-cloud-workbox"
  description = "No public ingress. Outbound access supports Tailscale and development tools."
  vpc_id      = aws_vpc.personal.id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = []
  }

  tags = {
    Name = "personal-cloud-workbox"
  }
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workbox" {
  name               = "personal-cloud-workbox"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.workbox.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "workbox" {
  name = "personal-cloud-workbox"
  role = aws_iam_role.workbox.name
}

resource "aws_instance" "workbox" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  availability_zone           = aws_subnet.workbox.availability_zone
  subnet_id                   = aws_subnet.workbox.id
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.workbox.name
  vpc_security_group_ids      = [aws_security_group.workbox.id]
  user_data                   = templatefile("${path.module}/cloud-init.sh.tftpl", {})

  root_block_device {
    encrypted             = true
    delete_on_termination = true
    volume_type           = "gp3"
    volume_size           = 30
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  maintenance_options {
    auto_recovery = "default"
  }

  lifecycle {
    # cloud-init runs only at first boot. Changing it on a live host would force a
    # stop and start without re-running anything. New hosts use the current file.
    ignore_changes = [ami, user_data]
  }

  depends_on = [aws_iam_role_policy_attachment.ssm]

  tags = {
    Name = "personal-cloud"
  }
}

resource "aws_ebs_volume" "home" {
  availability_zone = aws_instance.workbox.availability_zone
  encrypted         = true
  type              = "gp3"
  size              = var.data_volume_size
  snapshot_id       = var.home_snapshot_id
  final_snapshot    = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name     = "personal-cloud-home"
    Snapshot = "true"
  }
}

resource "aws_volume_attachment" "home" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.home.id
  instance_id  = aws_instance.workbox.id
  force_detach = false
}

data "aws_iam_policy_document" "dlm_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "personal-cloud-snapshots"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume_role.json
}

data "aws_iam_policy_document" "dlm" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:CreateSnapshot",
      "ec2:CreateSnapshots",
      "ec2:DeleteSnapshot",
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*::snapshot/*"]
  }
}

resource "aws_iam_role_policy" "dlm" {
  name   = "personal-cloud-snapshots"
  role   = aws_iam_role.dlm.id
  policy = data.aws_iam_policy_document.dlm.json
}

resource "aws_dlm_lifecycle_policy" "home" {
  description        = "Daily snapshots of the personal cloud home volume"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    schedule {
      name = "Fourteen daily snapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:00"]
      }

      retain_rule {
        count = 14
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = true
    }

    target_tags = {
      Snapshot = "true"
    }
  }
}

resource "aws_budgets_budget" "monthly" {
  name         = "personal-cloud-monthly-gross"
  budget_type  = "COST"
  limit_amount = "250"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 120
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}
