variable "name" {
  default     = "gitlab-tutorial"
  description = "Used to prefix all created resource names."
}

variable "cidr" {
  default = "10.30.0.0/16"
}

variable "availability_zones" {
  default = ["us-east-1a", "us-east-1b"]
}

provider "aws" {
  region  = "us-east-1"
  profile = "gitlab-tutorial"
}

module "vpc" {
  source             = "git@github.com:alchemy-aws-modules/terraform-aws-vpc"
  version            = "0.1"
  name               = "${var.name}"
  environment        = "development"
  cidr               = "${var.cidr}"
  availability_zones = ["${var.availability_zones}"]
  private_subnets    = ["10.30.0.0/19", "10.30.64.0/19"]
  public_subnets     = ["10.30.32.0/20", "10.30.96.0/20"]
  use_nat_instances  = true
}

module "security_groups" {
  source      = "git@github.com:alchemy-aws-modules/terraform-aws-security-groups"
  version     = "0.1"
  name        = "${var.name}"
  vpc_id      = "${module.vpc.id}"
  environment = "development"
  cidr        = "${module.vpc.cidr_block}"
}

output "vpc_id" {
  value = "${module.vpc.id}"
}

variable "key_name" {
  description = "Name of the EC2 key pair to assign to instances."
}

variable "ssh_private_key" {
  description = "Local filepath to the ssh private key associated with var.key_name"
}

module "bastion" {
  source          = "git@github.com:alchemy-aws-modules/terraform-aws-bastion"
  version         = "0.1"
  name            = "${var.name}"
  environment     = "development"
  security_groups = "${module.security_groups.external_ssh}"
  key_name        = "${var.key_name}"
  subnet_id       = "${element(module.vpc.public_subnets, 0)}"
}

output "bastion_ip" {
  value = "${module.bastion.public_ip}"
}

variable "gitlab_postgres_password" {
  default = "supersecret"
}

resource "aws_db_instance" "gitlab_postgres" {
  allocated_storage      = 50
  storage_type           = "gp2"
  engine                 = "postgres"
  engine_version         = "9.6.6"
  instance_class         = "db.m4.large"
  multi_az               = true
  db_subnet_group_name   = "${module.vpc.default_db_subnet_group}"
  name                   = "gitlabhq_production"
  username               = "gitlab"
  password               = "${var.gitlab_postgres_password}"
  vpc_security_group_ids = ["${module.security_groups.internal_psql}"]
  skip_final_snapshot    = true
}

resource "aws_elasticache_subnet_group" "gitlab_redis" {
  name       = "${var.name}-redis-subnet-group"
  subnet_ids = ["${module.vpc.private_subnets}"]
}

resource "aws_elasticache_replication_group" "gitlab_redis" {
  replication_group_id          = "${var.name}"
  replication_group_description = "Redis cluster powering GitLab"
  engine                        = "redis"
  engine_version                = "3.2.10"
  node_type                     = "cache.m4.large"
  number_cache_clusters         = 2
  port                          = 6379
  availability_zones            = ["${var.availability_zones}"]
  automatic_failover_enabled    = true
  security_group_ids            = ["${module.security_groups.internal_redis}"]
  subnet_group_name             = "${aws_elasticache_subnet_group.gitlab_redis.name}"
}

output "gitlab_postgres_address" {
  value = "${aws_db_instance.gitlab_postgres.address}"
}

output "gitlab_redis_endpoint_address" {
  value = "${aws_elasticache_replication_group.gitlab_redis.primary_endpoint_address}"
}

resource "aws_security_group" "nfs" {
  vpc_id      = "${module.vpc.id}"
  name_prefix = "${var.name}-gitlab-nfs-"

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = ["${var.cidr}"]
  }

  ingress {
    from_port   = 111
    to_port     = 111
    protocol    = "tcp"
    cidr_blocks = ["${var.cidr}"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_ami" "centos" {
  owners      = ["aws-marketplace"]
  most_recent = true

  filter {
    name   = "product-code"
    values = ["aw0evgkw8e5c1q413zgy5pjce"]
  }
}

resource "aws_iam_role" "nfs_server" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "nfs_server_ebs" {
  role = "${aws_iam_role.nfs_server.id}"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "nfs_server" {
  role = "${aws_iam_role.nfs_server.name}"
}

resource "aws_instance" "nfs_server" {
  ami                    = "${data.aws_ami.centos.id}"
  instance_type          = "t2.micro"
  key_name               = "${var.key_name}"
  subnet_id              = "${element(module.vpc.private_subnets, 0)}"
  vpc_security_group_ids = ["${module.security_groups.internal_ssh}", "${aws_security_group.nfs.id}"]

  iam_instance_profile = "${aws_iam_instance_profile.nfs_server.id}"
}

locals {
  device_names = ["/dev/xvdf", "/dev/xvdg", "/dev/xvdh"]
}

resource "aws_ebs_volume" "gitlab_nfs" {
  count             = "${length(local.device_names)}"
  availability_zone = "us-east-1a"
  size              = 128
}

resource "null_resource" "nfs_server_bootstrap" {
  triggers {
    nfs_server_id = "${aws_instance.nfs_server.id}"
  }

  provisioner "remote-exec" {
    inline = [
      <<EOF
        while [ ! -f /var/lib/cloud/instance/boot-finished ]; do
          echo -e "\033[1;36mWaiting for cloud-init..."
          sleep 1
        done
      EOF
      ,
    ]

    connection {
      user         = "centos"
      host         = "${aws_instance.nfs_server.private_ip}"
      private_key  = "${file(pathexpand(var.ssh_private_key))}"
      bastion_host = "${module.bastion.public_ip}"
      bastion_user = "centos"
    }
  }

  provisioner "local-exec" {
    command = <<EOF
      ansible-playbook ../ansible/nfs-servers.yml -i "${aws_instance.nfs_server.private_ip}," \
      -e nfs_server_hosts="${aws_instance.nfs_server.private_ip}" \
      -e bastion_user=centos \
      -e bastion_host=${module.bastion.public_ip} \
      -e instance_id=${aws_instance.nfs_server.id} \
      -e '{ "volumes": ${jsonencode(aws_ebs_volume.gitlab_nfs.*.id)} }' \
      -e '{ "devices": ${jsonencode(local.device_names)} }' \
      -e region=us-east-1 \
      -e cidr=${module.vpc.cidr_block}
    EOF
  }
}

output "nfs_server_private_ip" {
  value = "${aws_instance.nfs_server.private_ip}"
}

variable "gitlab_application_ami" {
  default = "ami-3a9c3f45"
}

data "template_file" "gitlab_application_user_data" {
  template = "${file("${path.module}/templates/gitlab_application_user_data.tpl")}"

  vars {
    nfs_server_private_ip = "${aws_instance.nfs_server.private_ip}"
    postgres_database     = "${aws_db_instance.gitlab_postgres.name}"
    postgres_username     = "${aws_db_instance.gitlab_postgres.username}"
    postgres_password     = "${var.gitlab_postgres_password}"
    postgres_endpoint     = "${aws_db_instance.gitlab_postgres.address}"
    redis_endpoint        = "${aws_elasticache_replication_group.gitlab_redis.primary_endpoint_address}"
    cidr                  = "${module.vpc.cidr_block}"
  }
}

resource "aws_launch_configuration" "gitlab_application" {
  name_prefix     = "${var.name}-gitlab-application-"
  image_id        = "${var.gitlab_application_ami}"
  instance_type   = "t2.large"
  security_groups = ["${aws_security_group.gitlab_application.id}", "${module.security_groups.internal_ssh}"]
  key_name        = "${var.key_name}"

  user_data = "${data.template_file.gitlab_application_user_data.rendered}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "gitlab_application" {
  launch_configuration = "${aws_launch_configuration.gitlab_application.name}"
  min_size             = 1
  max_size             = 1
  vpc_zone_identifier  = ["${module.vpc.private_subnets}"]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elb" "gitlab_application" {
  subnets         = ["${module.vpc.public_subnets}"]
  security_groups = ["${module.security_groups.external_elb}"]

  listener {
    instance_port     = 80
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 5
    timeout             = 3
    target              = "HTTP:80/-/readiness"
    interval            = 30
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_attachment" "asg_attachment_gitlab" {
  autoscaling_group_name = "${aws_autoscaling_group.gitlab_application.id}"
  elb                    = "${aws_elb.gitlab_application.id}"
}

resource "aws_security_group" "gitlab_application" {
  vpc_id      = "${module.vpc.id}"
  name_prefix = "${var.name}-gitlab-application-"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = ["${module.security_groups.external_elb}"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

output "gitlab_dns_name" {
  value = "${aws_elb.gitlab_application.dns_name}"
}
