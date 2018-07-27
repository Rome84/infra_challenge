#----provider----

provider "aws" {
  region  = "us-east-1"
}


#---Key----

resource "aws_key_pair" "mykey" {
  key_name = "mykey"
  public_key = "${file("${var.PATH_TO_PUBLIC_KEY}")}"
}

#----VPC----

resource "aws_vpc" "wp_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags {
    Name = "wp_vpc"
  }
}

#intergateway

resource "aws_internet_gateway" "wp_internet_gateway" {
  vpc_id = "${aws_vpc.wp_vpc.id}"

  tags {
    Name = "wp_igw"
  }
        }

resource "aws_eip" "nat" {
  vpc = true
  tags {
    Name = "wp_nateip"
  }

}

#Nat gateway

resource "aws_nat_gateway" "wp_private_ngw" {
  allocation_id = "${aws_eip.nat.id}"
  subnet_id     = "${aws_subnet.wp_private1_subnet.id}"

  tags {
    Name = "wp_natgw"
  }
}


#Route tables

resource "aws_route_table" "wp_public_rt" {
  vpc_id = "${aws_vpc.wp_vpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.wp_internet_gateway.id}"
  }

  tags {
    Name = "wp_public"
  }
}

resource "aws_route_table" "wp_private_rt" {
  vpc_id = "${aws_vpc.wp_vpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_nat_gateway.wp_private_ngw.id}"
  }

  tags {
    Name = "wp_private"
  }
}


#subnets

resource "aws_subnet" "wp_public1_subnet" {
  vpc_id                  = "${aws_vpc.wp_vpc.id}"
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${data.aws_availability_zones.available.names[0]}"

  tags {
    Name = "wp_public1"
  }
}

resource "aws_subnet" "wp_private1_subnet" {
  vpc_id                  = "${aws_vpc.wp_vpc.id}"
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false
  availability_zone       = "${data.aws_availability_zones.available.names[0]}"

  tags {
    Name = "wp_private1"
  }
}

#public subnet group

# subnet associations

resource "aws_route_table_association" "wp_public1_assoc" {
  subnet_id      = "${aws_subnet.wp_public1_subnet.id}"
  route_table_id = "${aws_route_table.wp_public_rt.id}"
}


#---Security groups----

resource "aws_security_group" "wp_sg" {
  name        = "wp_sg"
  description = "used for elastic load balancer for public"
  vpc_id      = "${aws_vpc.wp_vpc.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

   ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
   }

   ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24"]
   }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#ELB

resource "aws_elb" "wp_elb" {
  name = "newbalancer-elb"

  subnets = ["${aws_subnet.wp_public1_subnet.id}"
  ]

  security_groups = ["${aws_security_group.wp_sg.id}"]

  listener {
    instance_port     = 5000
    instance_protocol = "tcp"
    lb_port           = 80
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "TCP:5000"
    interval            = 30
  }

 cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags {
    Name = "wp_elb_new"
  }
}



resource "aws_elb" "wp_elb_es" {
  name = "wp_elb_es"

  subnets = ["${aws_subnet.wp_private1_subnet.id}"
  ]

  security_groups = ["${aws_security_group.wp_sg.id}"]

  listener {
    instance_port     = 5000
    instance_protocol = "tcp"
    lb_port           = 80
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "TCP:5000"
    interval            = 30
  }

 cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags {
    Name = "wp_elb_es"
  }
}


#launch configuration

resource "aws_launch_configuration" "wp_lc" {
  name_prefix   = "wp_lc-"
  image_id      = "${aws_ami_from_instance.wp_golden.id}"
  instance_type = "t2.micro"

  security_groups = ["${aws_security_group.wp_sg.id}"]

  key_name                    = "${aws_key_pair.mykey.key_name}"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_configuration" "wp_lc_es" {
  name_prefix   = "wp_lc_es-"
  image_id      = "${aws_ami_from_instance.wp_golden_es.id}"
  instance_type = "t2.micro"

  security_groups = ["${aws_security_group.wp_sg.id}"]

  key_name                    = "${aws_key_pair.mykey.key_name}"

  lifecycle {
    create_before_destroy = true
  }
}



#autoscaling

resource "aws_autoscaling_group" "wp_asg" {
  launch_configuration = "${aws_launch_configuration.wp_lc.name}"

  vpc_zone_identifier = ["${aws_subnet.wp_private1_subnet.id}",
    "${aws_subnet.wp_public1_subnet.id}",
  ]

  min_size          = 2
  max_size          = 4
  load_balancers    = ["${aws_elb.wp_elb.id}"]
  health_check_type = "EC2"

  tags {
    key                 = "Name"
    value               = "prod1"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "CpuPolicy"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = "${aws_autoscaling_group.wp_asg.name}"
}

resource "aws_cloudwatch_metric_alarm" "monitor_cpu" {
  namespace           = "CPUwatch"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "3"
  metric_name         = "CPUUtilization"
  namespace           = "AWSec2"
  period              = "120"
  statistic           = "Average"
  threshold           = "50"

  dimensions = {
    "AutoScalingGroupName" = "${aws_autoscaling_group.wp_asg.name}"
  }

  alarm_name    = "cpuwatch-asg"
  alarm_actions = ["${aws_autoscaling_policy.cpu_policy.arn}"]
}

resource "aws_autoscaling_policy" "policy_down" {
  name                   = "downPolicy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = "${aws_autoscaling_group.wp_asg.name}"
}


resource "aws_cloudwatch_metric_alarm" "monitor_down" {
  namespace           = "downwatch"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWSec2"
  period              = "120"
  statistic           = "Average"
  threshold           = "10"

  dimensions = {
    "AutoScalingGroupName" = "${aws_autoscaling_group.wp_asg.name}"
  }

  alarm_name    = "downwatch-asg"
  alarm_actions = ["${aws_autoscaling_policy.cpu_policy.arn}"]
}

resource "aws_autoscaling_group" "wp_asg_es" {
  launch_configuration = "${aws_launch_configuration.wp_lc_es.name}"

  vpc_zone_identifier = ["${aws_subnet.wp_private1_subnet.id}",
    "${aws_subnet.wp_public1_subnet.id}",
  ]

  min_size          = 2
  max_size          = 4
  load_balancers    = ["${aws_elb.wp_elb_es.id}"]
  health_check_type = "EC2"

  tags {
    key                 = "Name"
    value               = "prod_es"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu_policy_es" {
  name                   = "CpuPolicy_es"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = "${aws_autoscaling_group.wp_asg_es.name}"
}

resource "aws_cloudwatch_metric_alarm" "monitor_cpu_es" {
  namespace           = "CPUwatch_es"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "3"
  metric_name         = "CPUUtilization"
  namespace           = "AWSec2"
  period              = "120"
  statistic           = "Average"
  threshold           = "50"

  dimensions = {
    "AutoScalingGroupName" = "${aws_autoscaling_group.wp_asg_es.name}"
  }

  alarm_name    = "cpuwatch-asg_es"
  alarm_actions = ["${aws_autoscaling_policy.cpu_policy_es.arn}"]
}


resource "aws_autoscaling_policy" "policy_down_es" {
  name                   = "downPolicy_es"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = "${aws_autoscaling_group.wp_asg_es.name}"
}


resource "aws_cloudwatch_metric_alarm" "monitor_down_es" {
  namespace           = "downwatch_es"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWSec2"
  period              = "120"
  statistic           = "Average"
  threshold           = "10"

  dimensions = {
    "AutoScalingGroupName" = "${aws_autoscaling_group.wp_asg_es.name}"
  }

  alarm_name    = "downwatch-asg_es"
  alarm_actions = ["${aws_autoscaling_policy.cpu_policy_es.arn}"]
}



#---AMI--

resource "aws_ami_from_instance" "wp_golden" {
  name               = "wp_ami_app"
  source_instance_id = "${aws_instance.appserver.id}"
}

resource "aws_ami_from_instance" "wp_golden_es" {
  name               = "wp_ami_es"
  source_instance_id = "${aws_instance.esserver.id}"
}


#instances

# Building nginx template

resource "aws_instance" "appserver" {
  ami             =  "${lookup(var.AMIS, var.AWS_REGION)}"
  instance_type   = "t2.micro"
  key_name        = "${aws_key_pair.mykey.key_name}"
  vpc_security_group_ids = ["${aws_security_group.wp_sg.id}"]
  subnet_id       = "${aws_subnet.wp_public1_subnet.id}"


provisioner "local-exec" {
     command = "sleep 30 && echo \"[app-servers]\n${aws_instance.appserver.public_ip} ansible_connection=ssh ansible_ssh_user=ubuntu ansible_ssh_private_key_file=mykey host_key_checking=False\" > appserver-inventory &&  ansible-playbook -i appserver-inventory ansible-playbook/app-site.yml "
  }
 connection {
    user = "${var.INSTANCE_USERNAME}"
    private_key = "${file("${var.PATH_TO_PRIVATE_KEY}")}"
  }  

 tags {
     Name = "Prod"
   }
}

# Building elasticsearch template

resource "aws_instance" "esserver" {
  ami             =  "${lookup(var.AMIS, var.AWS_REGION)}"
  instance_type   = "t2.micro"
  key_name        = "${aws_key_pair.mykey.key_name}"
  vpc_security_group_ids = ["${aws_security_group.wp_sg.id}"]
  subnet_id       = "${aws_subnet.wp_public1_subnet.id}"


provisioner "local-exec" {
     command = "sleep 30 && echo \"[app-servers]\n${aws_instance.appserver.public_ip} ansible_connection=ssh ansible_ssh_user=ubuntu ansible_ssh_private_key_file=mykey host_key_checking=False\" > appserver-inventory &&  ansible-playbook -i appserver-inventory ansible-playbook/app-site.yml "
  }
 connection {
    user = "${var.INSTANCE_USERNAME}"
    private_key = "${file("${var.PATH_TO_PRIVATE_KEY}")}"
  }

 tags {
     Name = "Prod_es"
   }
}

# Building Database servers

resource "aws_instance" "dbserver" {
  ami             =  "${lookup(var.AMIS, var.AWS_REGION)}"
  instance_type   = "t2.micro"
  key_name        = "${aws_key_pair.mykey.key_name}"
  vpc_security_group_ids = ["${aws_security_group.wp_sg.id}"]
  subnet_id       = "${aws_subnet.wp_private1_subnet.id}"


provisioner "local-exec" {
     command = "sleep 30 && echo \"[app-servers]\n${aws_instance.appserver.public_ip} ansible_connection=ssh ansible_ssh_user=ubuntu ansible_ssh_private_key_file=mykey host_key_checking=False\" > appserver-inventory &&  ansible-playbook -i appserver-inventory ansible-playbook/app-site.yml "
  }
 connection {
    user = "${var.INSTANCE_USERNAME}"
    private_key = "${file("${var.PATH_TO_PRIVATE_KEY}")}"
  }

 tags {
     Name = "Prod_es"
   }
}



