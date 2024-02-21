

# Configure the AWS Provider
provider "aws" {
  region = var.aws_region
}

#Create VPC 

resource "aws_vpc" "two-tier-vpc" {
  cidr_block       = var.base_cidr_block
  instance_tenancy = "default"

  tags = {
    Name = "two-tier-vpc"
  }
}


#Create subnets in the VPC for Web Server Tier

resource "aws_subnet" "subnet-public-1" {
  vpc_id                  = aws_vpc.two-tier-vpc.id
  cidr_block              = var.public_subnet_1
  map_public_ip_on_launch = true # it makes this a public subnet
  availability_zone       = "us-east-1a"
  tags = {
    Name = "subnet-public-1"
  }
}

resource "aws_subnet" "subnet-public-2" {
  vpc_id                  = aws_vpc.two-tier-vpc.id
  cidr_block              = var.public_subnet_2
  map_public_ip_on_launch = true # it makes this a public subnet
  availability_zone       = "us-east-1b"
  tags = {
    Name = "subnet-public-2"
  }
}

#Create subnets in the VPC for Database Tier

resource "aws_subnet" "subnet-private-1" {
  vpc_id            = aws_vpc.two-tier-vpc.id
  cidr_block        = var.private_subnet_1
  availability_zone = "us-east-1a"
  tags = {
    Name = "subnet-private-1"
  }
}

resource "aws_subnet" "subnet-private-2" {
  vpc_id            = aws_vpc.two-tier-vpc.id
  cidr_block        = var.private_subnet_2
  availability_zone = "us-east-1b"
  tags = {
    Name = "subnet-private-2"
  }
}


#Create Internet Gateway
resource "aws_internet_gateway" "internet_gw" {
  vpc_id = aws_vpc.two-tier-vpc.id

  tags = {
    Name = "main_igw"
  }
}

/*#Internet Gateway Attachment 
resource "aws_internet_gateway_attachment" "internet_gw" {
  internet_gateway_id = aws_internet_gateway.internet_gw.id
  vpc_id              = aws_vpc.two-tier-vpc.id
}
*/

# Create Public Route Table
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.two-tier-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gw.id
  }

  tags = {
    Name = "public_route_table"
  }
}

#Route Table Association for Public Subnet 1

resource "aws_route_table_association" "public_subnet1_association" {
  subnet_id      = aws_subnet.subnet-public-1.id
  route_table_id = aws_route_table.public_route_table.id
}

#Route Table Association for Public Subnet 2

resource "aws_route_table_association" "public_subnet2_association" {
  subnet_id      = aws_subnet.subnet-public-2.id
  route_table_id = aws_route_table.public_route_table.id
}

#Create Elastic IP
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  tags = {
    Name = "nat_eip"
  }
}

#Create NAT Gateway
resource "aws_nat_gateway" "NAT" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.subnet-public-1.id
  depends_on    = [aws_internet_gateway.internet_gw]
  tags = {
    Name = "NAT_GW"
  }
}

#Create Private Route Table

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.two-tier-vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.NAT.id
  }

  tags = {
    Name = "private_route_table"
  }
}

#Route Table Association for Private Route Table Subnet 1

resource "aws_route_table_association" "private_subnet1_association" {
  subnet_id      = aws_subnet.subnet-private-1.id
  route_table_id = aws_route_table.private_route_table.id
  depends_on     = [aws_route_table.private_route_table]
}

#Route Table Association for Private Route Table Subnet 2

resource "aws_route_table_association" "private_subnet2_association" {
  subnet_id      = aws_subnet.subnet-private-2.id
  route_table_id = aws_route_table.private_route_table.id
  depends_on     = [aws_route_table.private_route_table]
}


#Launch an EC2 Instance with your choice of webserver in each public web tier subnet (apache, NGINX, etc).

# Create Launch Template
resource "aws_launch_template" "launch_template_asg" {
  name                   = "launch_template_asg"
  image_id               = var.linux_ami
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  user_data = base64encode(<<EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl start httpd
    systemctl enable httpd
EOF
  )
}

# Create Auto Scaling Group
resource "aws_autoscaling_group" "web_asg" {
  desired_capacity    = var.min_instances
  max_size            = var.max_instances
  min_size            = var.min_instances
  vpc_zone_identifier = [aws_subnet.subnet-public-1.id, aws_subnet.subnet-public-2.id]

  # Attach Launch Template to Auto Scaling Group
  launch_template {
    id      = aws_launch_template.launch_template_asg.id
    version = "$Latest" # or specify the version you want
  }
}

#Security Groups properly configured for needed resources ( web servers, RDS)

# Create Web Server Security Group
resource "aws_security_group" "web_sg" {
  name        = "web_sg"
  description = " web sever security group "
  vpc_id      = aws_vpc.two-tier-vpc.id

  # Inbound Http, Https, and SSH
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

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound Internet Access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create Database Security Group
resource "aws_security_group" "db_sg" {
  name        = "db_sg"
  description = "database security group"
  vpc_id      = aws_vpc.two-tier-vpc.id

  # Inbound MySQL and SSH
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound Internet Access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#One RDS MySQL Instance (micro) in the private RDS subnets 

resource "aws_db_subnet_group" "mysql_subnet" {
  name       = "my-rds-subnet-group"
  subnet_ids = [aws_subnet.subnet-private-1.id, aws_subnet.subnet-private-2.id]
}

resource "aws_db_instance" "mysql_rds_instance" {
  allocated_storage    = 10
  db_name              = "mydb"
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t3.micro"
  username             = "username"
  password             = "password"
  parameter_group_name = "default.mysql5.7"
  skip_final_snapshot  = true
  db_subnet_group_name = aws_db_subnet_group.mysql_subnet.name
  depends_on           = [aws_db_subnet_group.mysql_subnet]
}