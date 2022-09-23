module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.14.2"

  name            = "vpc-ec2-active-passive-test"
  cidr            = "10.54.0.0/16"
  azs             = ["ap-southeast-1a", "ap-southeast-1b"]
  public_subnets  = ["10.54.0.0/24", "10.54.2.0/24"]
  private_subnets = ["10.54.1.0/24", "10.54.3.0/24"]

  # NAT
  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = false

}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_security_group" "allow_http" {
  name        = "allow_http"
  description = "allow http traffic"

  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "ssh" {
  name        = "allow_ssh"
  description = "allow ssh"

  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_instance" "test_vms" {
  for_each      = { for i, v in ["active", "passive"] : i => v }
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t2.micro"

  key_name        = "test-vm"
  monitoring      = true
  security_groups = [aws_security_group.allow_http.id, aws_security_group.ssh.id]
  subnet_id       = module.vpc.public_subnets[each.key]

  user_data = <<-EOF
  #!/bin/bash
  sudo apt update -y
  sudo apt install -y apache2
  sudo chmod -R 777 /var/www/html/index.html
  ip=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
  sudo echo $ip >> /var/www/html/index.html

  EOF

  tags = {
    Name = "test-${each.value}"
  }

}

resource "aws_lb" "frontend" {
  enable_http2       = true
  idle_timeout       = 60
  internal           = false
  ip_address_type    = "ipv4"
  load_balancer_type = "application"
  name               = "test-ec2-active-passive-alb"
  security_groups    = [aws_security_group.allow_http.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_listener" "front80" {
  load_balancer_arn = aws_lb.frontend.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      host        = "#{host}"
      path        = "/#{path}"
      port        = "443"
      protocol    = "HTTPS"
      query       = "#{query}"
      status_code = "HTTP_301"
    }
  }

  timeouts {}
}

resource "aws_lb_listener" "front443" {
  load_balancer_arn = aws_lb.frontend.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = data.aws_acm_certificate.issued.arn
  default_action {
    order            = 1
    target_group_arn = aws_lb_target_group.tg_active.arn
    type             = "forward"
  }

}


# active-tg

resource "aws_lb_target_group" "tg_active" {
  name        = "active-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"
  health_check {
    enabled = true
    path    = "/"
    timeout = 10
  }
}

# attach active ec2 -> tg
resource "aws_lb_target_group_attachment" "tg_active_instance_attachment" {
  target_group_arn = aws_lb_target_group.tg_active.arn
  target_id        = aws_instance.test_vms[0].id
  port             = 80
}

resource "aws_lb_target_group" "tg_passive" {
  name        = "standby-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"
  health_check {
    enabled = true
    path    = "/"
    timeout = 10
  }
}

# attach passive ec2 -> tg
resource "aws_lb_target_group_attachment" "tg_passive_instance_attachment" {
  target_group_arn = aws_lb_target_group.tg_passive.arn
  target_id        = aws_instance.test_vms[1].id
  port             = 80
}


data "aws_acm_certificate" "issued" {
  domain   = "www.aws.wkngw.com"
  statuses = ["ISSUED"]
}


# role policy for lambda

data "aws_iam_policy_document" "alb_check_policy" {
  statement {
    sid    = "ALBmodify"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:ModifyListener",
    ]
    resources = [resource.aws_lb.frontend.arn]
  }
  statement {
    sid    = "ALBCheck"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:DescribeTargetHealth"
    ]
    resources = [
      "*"
    ]
  }
}



module "alb_failover" {
  source = "./modules/failover-handler"

  name             = "alb-failover-handler"
  description      = "handles switch from active TG to standby TG"
  artifact_file    = "${path.module}/modules/failover-handler/.uploads/failover_handler.zip"
  handler          = "main.handler"
  runtime          = "python3.9"
  memory_size      = 128
  timeout          = 30
  alb_listener_arn = resource.aws_lb_listener.front443.arn

  environment = {
    "ACTIVE_TG_ARN"    = resource.aws_lb_target_group.tg_active.arn
    "PASSIVE_TG_ARN"   = resource.aws_lb_target_group.tg_passive.arn
    "ELB_LISTENER_ARN" = resource.aws_lb_listener.front443.arn
  }
}
