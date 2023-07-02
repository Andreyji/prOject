terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 5.0.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "= 1.14.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.6.1"
    }
  }
  required_version = ">= 0.15"
}

provider "aws" {
  region = "us-west-2"
  access_key = var.aws_key
  secret_key = var.aws_sec_key
}

provider "kubectl" {
  config_context_cluster = aws_eks_cluster.app_cluster.name
}

# Network

resource "aws_vpc" "main" {
 cidr_block = "10.0.0.0/16"
 enable_dns_hostnames = "true"
 
 tags = {
   Name = "EKS VPC"
 }
} 

resource "aws_internet_gateway" "gw" {
  vpc_id = "${aws_vpc.main.id}"

  tags = {
    Name = "main"
  }
}

resource "aws_eip" "elastic_ip" {
  domain   = "vpc"
  count = "${length(var.subnet_cidrs_public)}"
}

resource "aws_nat_gateway" "nat_gateway" {
  count = "${length(var.subnet_cidrs_public)}"
  allocation_id = "${element(aws_eip.elastic_ip.*.id, count.index)}"
  subnet_id = "${element(aws_subnet.public.*.id, count.index)}"
  depends_on = [ aws_subnet.public ]
}

output "nat_gateway_ids" {
  value = [for nat in aws_nat_gateway.nat_gateway : nat.id]
}

resource "aws_route_table" "nat_gateway_route" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id  = "${aws_internet_gateway.gw.id}"
  }
  tags = {
    Name = "nat_gateway_route"
  }
}


resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  count = "${length(var.subnet_cidrs_public)}"
  availability_zone = "${var.azs[count.index]}"
  cidr_block = "${var.subnet_cidrs_public[count.index]}"
  map_public_ip_on_launch = true
  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_route_table_association" "my_route_table_association" {
  count = "${length(var.subnet_cidrs_public)}"
  subnet_id = "${element(aws_subnet.public.*.id, count.index)}"
  route_table_id = aws_route_table.nat_gateway_route.id
}

resource "aws_security_group" "node_sg" {
  name        = "sec-grp"
  description = "Allow TLS and Cluster inbound traffic"
  vpc_id      = "${aws_vpc.main.id}"

  ingress = [
    {
      description = "TLS from VPC"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["${aws_vpc.main.cidr_block}"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = true
    },
    {
      description     = "kubelet API from node group instances"
      from_port       = 10250
      to_port         = 10250
      protocol        = "tcp"
      cidr_blocks     = [aws_vpc.main.cidr_block]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    },
    {
      description = "kube_api from VPC"
      from_port   = 2379
      to_port     = 2379
      protocol    = "tcp"
      cidr_blocks = ["${aws_vpc.main.cidr_block}"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    },
    {
      description = "kube_api from VPC"
      from_port   = 2380
      to_port     = 2380
      protocol    = "tcp"
      cidr_blocks = ["${aws_vpc.main.cidr_block}"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    },
    {
      description = "kube_api from VPC"
      from_port   = 6443
      to_port     = 6443
      protocol    = "TCP"
      cidr_blocks = ["${aws_vpc.main.cidr_block}"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    }
  ]

  egress = [
    {
      description     = "Outbound traffic"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    },
    {
      description     = "Outbound traffic to EKS cluster control plane"
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      cidr_blocks     = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    }
  ]

  tags = {
    Name = "allow_tls_eks"
  }
}

# Permissions

resource "aws_iam_role" "node_role" {
  name = "node-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role" "eks_role" {
  name = "eks-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": ["eks.amazonaws.com", "ec2.amazonaws.com"]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_policy_attachment" "eks-attach" {
  name       = "eks-attachment"
  count      = "${length(var.eks_policy_arn)}"
  roles      = [aws_iam_role.eks_role.name]
  policy_arn = "${var.eks_policy_arn[count.index]}"
  depends_on = [aws_iam_role.eks_role]
}

resource "aws_iam_policy_attachment" "node-attach" {
  name       = "node-attachment"
  count      = "${length(var.node_policy_arn)}"
  roles      = [aws_iam_role.node_role.name]
  policy_arn = "${var.node_policy_arn[count.index]}"
}

# Cluster

resource "aws_eks_cluster" "app_cluster" {
  depends_on = [aws_iam_policy_attachment.eks-attach, aws_iam_policy_attachment.node-attach]
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_role.arn 
  vpc_config {
    subnet_ids = aws_subnet.public[*].id
    security_group_ids  = ["${aws_security_group.node_sg.id}"]
    endpoint_private_access  = true
  }
}

resource "aws_eks_node_group" "my_node_group" {
  cluster_name    = aws_eks_cluster.app_cluster.name
  node_group_name = "node-group"
  node_role_arn   = aws_iam_role.node_role.arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = ["t2.small"]
  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}


#resource "kubectl_manifest" "application" {
#  depends_on = [aws_eks_cluster.app_cluster]
#  provider = kubectl
#  yaml_body = <<EOF
#   apiVersion: apps/v1
#   kind: Deployment
#   metadata:
#     name: the-app
#     replicas: 2
#     selector:
#       matchLabels:
#         app: the-app
#     template:
#       metadata:
#         labels:
#           app: the-app
#       spec:
#         containers:
#           - name: app-con
#             image: nginx:latest
#             ports:
#               - containerPort: 80
#EOF
#}

output "route_table" {
  value = [aws_route_table.nat_gateway_route.id]
}