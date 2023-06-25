terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0"
    }
    kubectl = {
      source  = "hashicorp/kubectl"
      version = ">= 1.0.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

resource "aws_eks_cluster" "app_cluster" {
  name     = "my-cluster"
  role_arn = aws_iam_role.my_cluster_role.arn
  version  = "1.21"

  vpc_config {
    subnet_ids = ["subnet-12345678", "subnet-87654321"]
  }
}

resource "aws_eks_node_group" "my_node_group" {
  cluster_name    = aws_eks_cluster.my_cluster.name
  node_group_name = "my-node-group"
  node_role_arn   = aws_iam_role.my_node_role.arn

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }
}

resource "aws_iam_role" "eks_role" {
  name = "eks-role"

  assume_role_policy = <<EOF
{
  "Version": "2023-06-25",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role" "node_role" {
  name = "eks-role"

  assume_role_policy = <<EOF
{
  "Version": "2023-06-25",
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